// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

/// @title  L1Teleporter
/// @notice Initiates L1 -> L3 transfers.
///         Creates 2 (or 3) retryables: one to bridge tokens (one to bridge the L3's fee token) to an L2Forwarder,
///         and one to call the L2ForwarderFactory.
contract L1Teleporter is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice Types of teleportations
    enum TeleportationType {
        Standard,
        NonFeeTokenToCustomFeeL3,
        OnlyCustomFee
    }

    /// @notice Parameters for teleport()
    /// @param  l1Token     L1 token being teleported
    /// @param  l1FeeToken  L1 address of the L3's fee token, or 0x00 for ETH
    /// @param  l1l2Router  L1 to L2 token bridge router
    /// @param  l2l3Router  L2 to L3 token bridge router
    /// @param  to          L3 address that will receive the tokens
    /// @param  amount      Amount of tokens being teleported
    /// @param  gasParams   Gas parameters for each retryable ticket
    struct TeleportParams {
        address l1Token;
        address l1FeeToken;
        address l1l2Router;
        address l2l3RouterOrInbox;
        address to;
        uint256 amount;
        RetryableGasParams gasParams;
    }

    /// @notice Gas parameters for each retryable ticket.
    struct RetryableGasParams {
        uint256 l2GasPrice;
        uint256 l3GasPrice;
        uint256 l2ForwarderFactoryGasLimit;
        uint256 l1l2FeeTokenBridgeGasLimit;
        uint256 l1l2TokenBridgeGasLimit;
        uint256 l2l3TokenBridgeGasLimit;
        uint256 l1l2FeeTokenBridgeSubmissionCost;
        uint256 l1l2TokenBridgeSubmissionCost;
        uint256 l2l3TokenBridgeSubmissionCost;
    }

    /// @notice Total cost for each retryable ticket.
    struct RetryableGasCosts {
        uint256 l1l2FeeTokenBridgeCost;
        uint256 l1l2TokenBridgeCost;
        uint256 l2ForwarderFactoryCost;
        uint256 l2l3TokenBridgeCost;
        uint256 l2ForwarderFactorySubmissionCost;
    }

    /// @dev Calldata size of L2ForwarderFactory.callForwarder
    uint256 immutable l2ForwarderFactoryCalldataSize;

    /// @notice Emitted when a teleportation is initiated.
    /// @param  sender              L1 address that initiated the teleportation
    /// @param  l1Token             L1 token being teleported
    /// @param  l1FeeToken          L1 address of the L3's fee token, or 0x00 for ETH
    /// @param  l1l2Router          L1 to L2 token bridge router
    /// @param  l2l3RouterOrInbox   L2 to L3 token bridge router or Inbox
    /// @param  to                  L3 address that will receive the tokens
    /// @param  amount              Amount of tokens being teleported
    event Teleported(
        address indexed sender,
        address l1Token,
        address l1FeeToken,
        address l1l2Router,
        address l2l3RouterOrInbox,
        address to,
        uint256 amount
    );

    /// @notice Thrown when the ETH value sent to teleport() is less than the total ETH cost of retryables
    error InsufficientValue(uint256 required, uint256 provided);
    /// @notice Thrown when TeleportationType is OnlyCustomFee and the amount of fee tokens to send is less than the cost of the retryable to L3
    error InsufficientFeeToken(uint256 required, uint256 provided);

    constructor(address _l2ForwarderFactory, address _l2ForwarderImplementation)
        L2ForwarderPredictor(_l2ForwarderFactory, _l2ForwarderImplementation)
    {
        L2ForwarderParams memory _x;
        l2ForwarderFactoryCalldataSize = abi.encodeCall(L2ForwarderFactory.callForwarder, (_x)).length;
    }

    /// @notice Start an L1 -> L3 transfer. msg.value sent must be >= the total cost of all retryables.
    ///         Call `determineTypeAndFees` to calculate the total cost of retryables in ETH and the L3's fee token.
    ///         Any extra ETH will be sent to the receiver on L3.
    /// @dev    2 retryables will be created: one to send tokens and ETH to the L2Forwarder, and one to call the L2ForwarderFactory.
    ///         If TeleportationType is NonFeeTokenToCustomFeeL3, a third retryable will be created to send the L3's fee token to the L2Forwarder.
    ///         Extra ETH is sent through the l2CallValue of the call to the L2ForwarderFactory.
    function teleport(TeleportParams memory params) external payable {
        (
            uint256 requiredEth,
            uint256 requiredFeeToken,
            TeleportationType teleportationType,
            RetryableGasCosts memory retryableCosts
        ) = determineTypeAndFees(params, block.basefee);

        // ensure we have enough msg.value
        if (msg.value < requiredEth) revert InsufficientValue(requiredEth, msg.value);

        // get inbox
        address inbox = L1GatewayRouter(params.l1l2Router).inbox();

        // calculate forwarder address
        address l2Forwarder = l2ForwarderAddress(AddressAliasHelper.applyL1ToL2Alias(msg.sender));

        if (teleportationType == TeleportationType.Standard) {
            // we are teleporting a token to an ETH fee L3
            _teleportCommon(params, retryableCosts, l2Forwarder, inbox);
        } else if (teleportationType == TeleportationType.OnlyCustomFee) {
            // we are teleporting an L3's fee token

            // we have to make sure that the amount specified is enough to cover the retryable costs from L2 -> L3
            if (params.amount < requiredFeeToken) revert InsufficientFeeToken(requiredFeeToken, params.amount);

            // teleportation flow is identical to standard
            _teleportCommon(params, retryableCosts, l2Forwarder, inbox);
        } else {
            // we are teleporting a non-fee token to a custom fee L3
            // the flow is identical to standard,
            // except we have to send the appropriate amount of fee token through the bridge as well

            {
                // pull in fee tokens from caller
                IERC20(params.l1FeeToken).safeTransferFrom(msg.sender, address(this), requiredFeeToken);

                // approve gateway
                // todo: internal function for this
                address gateway = L1GatewayRouter(params.l1l2Router).getGateway(params.l1FeeToken);
                if (IERC20(params.l1FeeToken).allowance(address(this), gateway) == 0) {
                    IERC20(params.l1FeeToken).safeApprove(gateway, type(uint256).max);
                }
            }

            // send fee tokens through the bridge to predicted forwarder
            _bridgeToken({
                router: params.l1l2Router,
                token: params.l1FeeToken,
                to: l2Forwarder,
                amount: requiredFeeToken,
                gasLimit: params.gasParams.l1l2FeeTokenBridgeGasLimit,
                gasPrice: params.gasParams.l2GasPrice,
                submissionCost: params.gasParams.l1l2FeeTokenBridgeSubmissionCost
            });

            // the rest of the flow is identical to standard
            _teleportCommon(params, retryableCosts, l2Forwarder, inbox);
        }

        emit Teleported({
            sender: msg.sender,
            l1Token: params.l1Token,
            l1FeeToken: params.l1FeeToken,
            l1l2Router: params.l1l2Router,
            l2l3RouterOrInbox: params.l2l3RouterOrInbox,
            to: params.to,
            amount: params.amount
        });
    }

    /// @notice Given some teleportation parameters, calculate the total cost of retryables in ETH and the L3's fee token.
    function determineTypeAndFees(TeleportParams memory params, uint256 l1BaseFee)
        public
        view
        returns (
            uint256 ethAmount,
            uint256 feeTokenAmount,
            TeleportationType teleportationType,
            RetryableGasCosts memory costs
        )
    {
        // todo: optimize out redundant call to inbox() via a new internal function
        costs = _calculateRetryableGasCosts(L1GatewayRouter(params.l1l2Router).inbox(), l1BaseFee, params.gasParams);

        if (params.l1FeeToken == address(0)) {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost + costs.l2l3TokenBridgeCost;
            feeTokenAmount = 0;
            teleportationType = TeleportationType.Standard;
        } else if (params.l1FeeToken == params.l1Token) {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
            teleportationType = TeleportationType.OnlyCustomFee;
        } else {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l1l2FeeTokenBridgeCost + costs.l2ForwarderFactoryCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
            teleportationType = TeleportationType.NonFeeTokenToCustomFeeL3;
        }
    }

    /// @notice Given some teleportation parameters, build the L2ForwarderParams for the L2ForwarderFactory.
    function buildL2ForwarderParams(TeleportParams memory params, address l2Owner)
        public
        view
        returns (L2ForwarderParams memory)
    {
        address l2Token = L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l1Token);
        address l2FeeToken;

        if (params.l1FeeToken == address(0)) {
            l2FeeToken = address(0);
        } else if (params.l1Token == params.l1FeeToken) {
            l2FeeToken = l2Token;
        } else {
            l2FeeToken = L1GatewayRouter(params.l1l2Router).calculateL2TokenAddress(params.l1FeeToken);
        }

        return L2ForwarderParams({
            owner: l2Owner,
            l2Token: l2Token,
            l2FeeToken: l2FeeToken,
            routerOrInbox: params.l2l3RouterOrInbox,
            to: params.to,
            gasLimit: params.gasParams.l2l3TokenBridgeGasLimit,
            gasPrice: params.gasParams.l3GasPrice
        });
    }

    /// @notice Common logic for teleport()
    /// @dev    Pulls in `params.l1Token` and creates 2 retryables: one to bridge tokens to the L2Forwarder, and one to call the L2ForwarderFactory.
    function _teleportCommon(
        TeleportParams memory params,
        RetryableGasCosts memory retryableCosts,
        address l2Forwarder,
        address inbox
    ) internal {
        // pull in tokens from caller
        IERC20(params.l1Token).safeTransferFrom(msg.sender, address(this), params.amount);

        // approve gateway
        address gateway = L1GatewayRouter(params.l1l2Router).getGateway(params.l1Token);
        if (IERC20(params.l1Token).allowance(address(this), gateway) == 0) {
            IERC20(params.l1Token).safeApprove(gateway, type(uint256).max);
        }

        {
            // send tokens through the bridge to predicted forwarder
            _bridgeToken({
                router: params.l1l2Router,
                token: params.l1Token,
                to: l2Forwarder,
                amount: params.amount,
                gasLimit: params.gasParams.l1l2TokenBridgeGasLimit,
                gasPrice: params.gasParams.l2GasPrice,
                submissionCost: params.gasParams.l1l2TokenBridgeSubmissionCost
            });
        }

        // call the L2ForwarderFactory
        IInbox(inbox).createRetryableTicket{value: address(this).balance}({
            to: l2ForwarderFactory,
            l2CallValue: address(this).balance - retryableCosts.l2ForwarderFactoryCost,
            maxSubmissionCost: retryableCosts.l2ForwarderFactorySubmissionCost,
            excessFeeRefundAddress: l2Forwarder,
            callValueRefundAddress: l2Forwarder,
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPrice,
            data: abi.encodeCall(
                L2ForwarderFactory.callForwarder,
                buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(msg.sender))
                )
        });
    }

    /// @notice Bridge a token to L2.
    function _bridgeToken(
        address router,
        address token,
        address to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 submissionCost
    ) internal {
        L1GatewayRouter(router).outboundTransferCustomRefund{value: gasLimit * gasPrice + submissionCost}({
            _token: address(token),
            _refundTo: to,
            _to: to,
            _amount: amount,
            _maxGas: gasLimit,
            _gasPriceBid: gasPrice,
            _data: abi.encode(submissionCost, bytes(""))
        });
    }

    /// @notice Given some gas parameters, calculate costs for each retryable ticket.
    /// @param  inbox       L2's Inbox
    /// @param  l1BaseFee   L1's base fee
    /// @param  gasParams   Gas parameters for each retryable ticket
    function _calculateRetryableGasCosts(address inbox, uint256 l1BaseFee, RetryableGasParams memory gasParams)
        internal
        view
        returns (RetryableGasCosts memory results)
    {
        results.l2ForwarderFactorySubmissionCost =
            IInbox(inbox).calculateRetryableSubmissionFee(l2ForwarderFactoryCalldataSize, l1BaseFee);

        results.l1l2FeeTokenBridgeCost =
            gasParams.l1l2FeeTokenBridgeSubmissionCost + gasParams.l1l2FeeTokenBridgeGasLimit * gasParams.l2GasPrice;
        results.l1l2TokenBridgeCost =
            gasParams.l1l2TokenBridgeSubmissionCost + gasParams.l1l2TokenBridgeGasLimit * gasParams.l2GasPrice;
        results.l2ForwarderFactoryCost =
            results.l2ForwarderFactorySubmissionCost + gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPrice;
        results.l2l3TokenBridgeCost =
            gasParams.l2l3TokenBridgeSubmissionCost + gasParams.l2l3TokenBridgeGasLimit * gasParams.l3GasPrice;
    }
}
