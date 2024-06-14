// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";
import {IL2ForwarderFactory} from "./interfaces/IL2ForwarderFactory.sol";
import {IL1Teleporter} from "./interfaces/IL1Teleporter.sol";
import {IL2Forwarder} from "./interfaces/IL2Forwarder.sol";
import {TeleportationType, toTeleportationType} from "./lib/TeleportationType.sol";

contract L1Teleporter is Pausable, AccessControl, L2ForwarderPredictor, IL1Teleporter {
    using SafeERC20 for IERC20;

    /// @notice Accounts with this role can pause and unpause the contract
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address public constant SKIP_FEE_TOKEN_MAGIC_ADDRESS = address(bytes20(keccak256("SKIP_FEE_TOKEN")));

    constructor(address _l2ForwarderFactory, address _l2ForwarderImplementation, address _admin, address _pauser)
        L2ForwarderPredictor(_l2ForwarderFactory, _l2ForwarderImplementation)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _pauser);
    }

    /// @notice Pause the contract
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @inheritdoc IL1Teleporter
    function teleport(TeleportParams calldata params) external payable whenNotPaused {
        (
            uint256 requiredEth,
            uint256 requiredFeeToken,
            TeleportationType teleportationType,
            RetryableGasCosts memory retryableCosts
        ) = determineTypeAndFees(params);

        // ensure we have correct msg.value
        if (msg.value != requiredEth) revert IncorrectValue(requiredEth, msg.value);

        // calculate forwarder address from params
        address l2Forwarder = l2ForwarderAddress(_aliasIfContract(msg.sender), params.l2l3RouterOrInbox, params.to);

        if (teleportationType == TeleportationType.OnlyCustomFee) {
            // teleporting an L3's custom fee token to a custom (non-eth) fee L3
            // we have to make sure that the amount specified is enough to cover the retryable costs from L2 -> L3
            if (params.amount < requiredFeeToken) revert InsufficientFeeToken(requiredFeeToken, params.amount);
        } else if (teleportationType == TeleportationType.NonFeeTokenToCustomFee) {
            // teleporting a non-fee token to a custom (non-eth) fee L3
            // pull in and send fee tokens through the bridge to predicted forwarder
            if (requiredFeeToken > 0) {
                _pullAndBridgeToken({
                    router: params.l1l2Router,
                    token: params.l3FeeTokenL1Addr,
                    to: l2Forwarder,
                    amount: requiredFeeToken,
                    gasLimit: params.gasParams.l1l2FeeTokenBridgeGasLimit,
                    gasPriceBid: params.gasParams.l2GasPriceBid,
                    maxSubmissionCost: params.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost
                });
            }
        }

        _teleportCommon(params, retryableCosts, l2Forwarder);

        emit Teleported({
            sender: msg.sender,
            l1Token: params.l1Token,
            l3FeeTokenL1Addr: params.l3FeeTokenL1Addr,
            l1l2Router: params.l1l2Router,
            l2l3RouterOrInbox: params.l2l3RouterOrInbox,
            to: params.to,
            amount: params.amount
        });
    }

    /// @inheritdoc IL1Teleporter
    function buildL2ForwarderParams(TeleportParams calldata params, address caller)
        public
        view
        returns (IL2Forwarder.L2ForwarderParams memory)
    {
        address l2Token = L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l1Token);
        address l3FeeTokenL2Addr;
        uint256 maxSubmissionCost;

        TeleportationType teleportationType =
            toTeleportationType({token: params.l1Token, feeToken: params.l3FeeTokenL1Addr});

        if (teleportationType == TeleportationType.Standard) {
            l3FeeTokenL2Addr = address(0);
        } else if (teleportationType == TeleportationType.OnlyCustomFee) {
            l3FeeTokenL2Addr = l2Token;
        } else {
            l3FeeTokenL2Addr = L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l3FeeTokenL1Addr);
            maxSubmissionCost = params.gasParams.l2l3TokenBridgeMaxSubmissionCost;
        }

        return IL2Forwarder.L2ForwarderParams({
            owner: _aliasIfContract(caller),
            l2Token: l2Token,
            l3FeeTokenL2Addr: l3FeeTokenL2Addr,
            routerOrInbox: params.l2l3RouterOrInbox,
            to: params.to,
            gasLimit: params.gasParams.l2l3TokenBridgeGasLimit,
            gasPriceBid: params.gasParams.l3GasPriceBid,
            maxSubmissionCost: maxSubmissionCost,
            l3Calldata: params.l3Calldata
        });
    }

    /// @inheritdoc IL1Teleporter
    function determineTypeAndFees(TeleportParams calldata params)
        public
        pure
        returns (
            uint256 ethAmount,
            uint256 feeTokenAmount,
            TeleportationType teleportationType,
            RetryableGasCosts memory costs
        )
    {
        _requireZeroFeeTokenIfSkipping(params);

        costs = _calculateRetryableGasCosts(params.gasParams);

        teleportationType = toTeleportationType({token: params.l1Token, feeToken: params.l3FeeTokenL1Addr});

        // all teleportation types require at least these 2 retryables to L2
        ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost;

        // OnlyCustomFee is the only type that supports L3 calldata
        if (teleportationType != TeleportationType.OnlyCustomFee && params.l3Calldata.length > 0) {
            revert L3CalldataNotAllowedForType(teleportationType);
        }

        // in addition to the above ETH amount, more fee token and/or ETH is required depending on the teleportation type
        if (teleportationType == TeleportationType.Standard) {
            // standard type requires 1 retryable to L3 paid for in ETH
            ethAmount += costs.l2l3TokenBridgeCost;
        } else if (teleportationType == TeleportationType.OnlyCustomFee) {
            // only custom fee type requires 1 retryable to L3 paid for in fee token
            feeTokenAmount = costs.l2l3TokenBridgeCost;
        } else if (costs.l2l3TokenBridgeCost > 0) {
            // non-fee token to custom fee type requires:
            // 1 retryable to L2 paid for in ETH
            // 1 retryable to L3 paid for in fee token
            ethAmount += costs.l1l2FeeTokenBridgeCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
        }
    }

    /// @notice Common logic for teleport()
    /// @dev    Pulls in `params.l1Token` and creates 2 retryables: one to bridge tokens to the L2Forwarder, and one to call the L2ForwarderFactory.
    function _teleportCommon(
        TeleportParams calldata params,
        RetryableGasCosts memory retryableCosts,
        address l2Forwarder
    ) internal {
        // send tokens through the bridge to predicted forwarder
        _pullAndBridgeToken({
            router: params.l1l2Router,
            token: params.l1Token,
            to: l2Forwarder,
            amount: params.amount,
            gasLimit: params.gasParams.l1l2TokenBridgeGasLimit,
            gasPriceBid: params.gasParams.l2GasPriceBid,
            maxSubmissionCost: params.gasParams.l1l2TokenBridgeMaxSubmissionCost
        });

        // get inbox
        address inbox = L1GatewayRouter(params.l1l2Router).inbox();

        // call the L2ForwarderFactory
        IInbox(inbox).createRetryableTicket{value: address(this).balance}({
            to: l2ForwarderFactory,
            l2CallValue: address(this).balance - retryableCosts.l2ForwarderFactoryCost,
            maxSubmissionCost: params.gasParams.l2ForwarderFactoryMaxSubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPriceBid,
            data: abi.encodeCall(IL2ForwarderFactory.callForwarder, buildL2ForwarderParams(params, msg.sender))
        });
    }

    /// @notice Pull tokens from msg.sender, approve the token's gateway and bridge them to L2.
    function _pullAndBridgeToken(
        address router,
        address token,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPriceBid,
        uint256 maxSubmissionCost
    ) internal {
        // pull in tokens from caller
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // gateway is user supplied, an attacker can hence approve arbitrary address to spend fund from L1Teleporter
        // this is fine since L1Teleporter is not expected to hold fund between transactions
        address gateway = L1GatewayRouter(router).getGateway(token);
        if (IERC20(token).allowance(address(this), gateway) == 0) {
            IERC20(token).safeApprove(gateway, type(uint256).max);
        }

        // fee on transfer tokens are not supported as the amount would not match
        L1GatewayRouter(router).outboundTransferCustomRefund{value: gasLimit * gasPriceBid + maxSubmissionCost}({
            _token: address(token),
            _refundTo: to,
            _to: to,
            _amount: amount,
            _maxGas: gasLimit,
            _gasPriceBid: gasPriceBid,
            _data: abi.encode(maxSubmissionCost, bytes(""))
        });
    }

    /// @notice Given some gas parameters, calculate costs for each retryable ticket.
    /// @param  gasParams   Gas parameters for each retryable ticket
    function _calculateRetryableGasCosts(RetryableGasParams calldata gasParams)
        internal
        pure
        returns (RetryableGasCosts memory results)
    {
        results.l1l2FeeTokenBridgeCost = gasParams.l1l2FeeTokenBridgeMaxSubmissionCost
            + (gasParams.l1l2FeeTokenBridgeGasLimit * gasParams.l2GasPriceBid);
        results.l1l2TokenBridgeCost =
            gasParams.l1l2TokenBridgeMaxSubmissionCost + (gasParams.l1l2TokenBridgeGasLimit * gasParams.l2GasPriceBid);
        results.l2ForwarderFactoryCost = gasParams.l2ForwarderFactoryMaxSubmissionCost
            + (gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPriceBid);
        results.l2l3TokenBridgeCost =
            gasParams.l2l3TokenBridgeMaxSubmissionCost + (gasParams.l2l3TokenBridgeGasLimit * gasParams.l3GasPriceBid);
    }

    /// @dev If the fee token is being skipped, ensure that all fee-related gas parameters are zero
    function _requireZeroFeeTokenIfSkipping(TeleportParams calldata params) internal pure {
        if (
            params.l3FeeTokenL1Addr == SKIP_FEE_TOKEN_MAGIC_ADDRESS
                && (
                    params.gasParams.l2l3TokenBridgeMaxSubmissionCost > 0 || params.gasParams.l2l3TokenBridgeGasLimit > 0
                        || params.gasParams.l1l2FeeTokenBridgeGasLimit > 0
                        || params.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost > 0 || params.gasParams.l3GasPriceBid > 0
                )
        ) {
            revert NonZeroFeeTokenAmount();
        }
    }

    /// @dev Alias the address if it has code, otherwise return the address as is
    function _aliasIfContract(address addr) internal view returns (address) {
        return addr.code.length > 0 ? AddressAliasHelper.applyL1ToL2Alias(addr) : addr;
    }
}
