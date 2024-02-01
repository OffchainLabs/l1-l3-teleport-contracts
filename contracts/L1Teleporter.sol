// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";
import {IL2ForwarderFactory} from "./interfaces/IL2ForwarderFactory.sol";
import {IL1Teleporter} from "./interfaces/IL1Teleporter.sol";
import {IL2Forwarder} from "./interfaces/IL2Forwarder.sol";

contract L1Teleporter is L2ForwarderPredictor, IL1Teleporter {
    // @review - make this contract pausable or deploy behind proxy for safety
    using SafeERC20 for IERC20;

    /// @dev Calldata size of L2ForwarderFactory.callForwarder
    uint256 immutable l2ForwarderFactoryCalldataSize;

    constructor(address _l2ForwarderFactory, address _l2ForwarderImplementation)
        L2ForwarderPredictor(_l2ForwarderFactory, _l2ForwarderImplementation)
    {
        IL2Forwarder.L2ForwarderParams memory _x;
        // @review - this would not work if L2ForwarderParams has dynamic size
        l2ForwarderFactoryCalldataSize = abi.encodeCall(IL2ForwarderFactory.callForwarder, (_x)).length;
    }

    /// @inheritdoc IL1Teleporter
    function teleport(TeleportParams memory params) external payable {
        (uint256 requiredEth, uint256 requiredFeeToken, RetryableGasCosts memory retryableCosts) =
            determineTypeAndFees(params);

        // ensure we have correct msg.value
        if (msg.value != requiredEth) revert IncorrectValue(requiredEth, msg.value);

        // calculate forwarder address
        address l2Forwarder = l2ForwarderAddress(AddressAliasHelper.applyL1ToL2Alias(msg.sender));

        // @review we do this check in a few places, consider a library function to return an enum for clarity
        //         also looks like _teleportCommon can be moved outside the if/else block here
        if (params.l1FeeToken == address(0)) {
            // we are teleporting a token to an ETH fee L3
            _teleportCommon(params, retryableCosts, l2Forwarder);
        } else if (params.l1Token == params.l1FeeToken) {
            // we are teleporting an L3's fee token

            // we have to make sure that the amount specified is enough to cover the retryable costs from L2 -> L3
            if (params.amount < requiredFeeToken) revert InsufficientFeeToken(requiredFeeToken, params.amount);

            // teleportation flow is identical to standard
            _teleportCommon(params, retryableCosts, l2Forwarder);
        } else {
            // we are teleporting a non-fee token to a custom fee L3
            // the flow is identical to standard,
            // except we have to send the appropriate amount of fee token through the bridge as well

            // pull in and send fee tokens through the bridge to predicted forwarder
            _pullAndBridgeToken({
                router: params.l1l2Router,
                token: params.l1FeeToken,
                to: l2Forwarder,
                amount: requiredFeeToken,
                gasLimit: params.gasParams.l1l2FeeTokenBridgeGasLimit,
                gasPriceBid: params.gasParams.l2GasPriceBid,
                maxSubmissionCost: params.gasParams.l1l2FeeTokenBridgeMaxSubmissionCost
            });

            // the rest of the flow is identical to standard
            _teleportCommon(params, retryableCosts, l2Forwarder);
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

    /// @inheritdoc IL1Teleporter
    function buildL2ForwarderParams(TeleportParams memory params, address l2Owner)
        public
        view
        returns (IL2Forwarder.L2ForwarderParams memory)
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

        return IL2Forwarder.L2ForwarderParams({
            owner: l2Owner,
            l2Token: l2Token,
            l2FeeToken: l2FeeToken,
            routerOrInbox: params.l2l3RouterOrInbox,
            to: params.to,
            gasLimit: params.gasParams.l2l3TokenBridgeGasLimit,
            gasPriceBid: params.gasParams.l3GasPriceBid
        });
    }

    /// @notice Common logic for teleport()
    /// @dev    Pulls in `params.l1Token` and creates 2 retryables: one to bridge tokens to the L2Forwarder, and one to call the L2ForwarderFactory.
    function _teleportCommon(
        TeleportParams memory params,
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
            excessFeeRefundAddress: l2Forwarder, // @review - notice these are subject to aliasing
            callValueRefundAddress: l2Forwarder, //           consider burn the nonce that deploy L2ForwarderFactory on L1
            gasLimit: params.gasParams.l2ForwarderFactoryGasLimit,
            maxFeePerGas: params.gasParams.l2GasPriceBid,
            data: abi.encodeCall(
                IL2ForwarderFactory.callForwarder,
                buildL2ForwarderParams(params, AddressAliasHelper.applyL1ToL2Alias(msg.sender))
                )
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

        // approve gateway
        // @review - gateway is user supplied, an attacker can hence approve arbitrary address to spend fund from L1Teleporter
        //           it should be fine since L1Teleporter is not expected to hold fund, let's keep an eye on this
        address gateway = L1GatewayRouter(router).getGateway(token);
        if (IERC20(token).allowance(address(this), gateway) == 0) {
            IERC20(token).safeApprove(gateway, type(uint256).max);
        }

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

    /// @inheritdoc IL1Teleporter
    function determineTypeAndFees(TeleportParams memory params)
        public
        pure
        returns (uint256 ethAmount, uint256 feeTokenAmount, RetryableGasCosts memory costs)
    {
        costs = _calculateRetryableGasCosts(params.gasParams);

        if (params.l1FeeToken == address(0)) {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost + costs.l2l3TokenBridgeCost;
            feeTokenAmount = 0;
        } else if (params.l1FeeToken == params.l1Token) {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l2ForwarderFactoryCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
        } else {
            ethAmount = costs.l1l2TokenBridgeCost + costs.l1l2FeeTokenBridgeCost + costs.l2ForwarderFactoryCost;
            feeTokenAmount = costs.l2l3TokenBridgeCost;
        }
    }

    /// @notice Given some gas parameters, calculate costs for each retryable ticket.
    /// @param  gasParams   Gas parameters for each retryable ticket
    function _calculateRetryableGasCosts(RetryableGasParams memory gasParams)
        internal
        pure
        returns (RetryableGasCosts memory results)
    {
        results.l1l2FeeTokenBridgeCost =
            gasParams.l1l2FeeTokenBridgeMaxSubmissionCost + gasParams.l1l2FeeTokenBridgeGasLimit * gasParams.l2GasPriceBid;
        results.l1l2TokenBridgeCost =
            gasParams.l1l2TokenBridgeMaxSubmissionCost + gasParams.l1l2TokenBridgeGasLimit * gasParams.l2GasPriceBid;
        results.l2ForwarderFactoryCost =
            gasParams.l2ForwarderFactoryMaxSubmissionCost + gasParams.l2ForwarderFactoryGasLimit * gasParams.l2GasPriceBid;
        results.l2l3TokenBridgeCost =
            gasParams.l2l3TokenBridgeMaxSubmissionCost + gasParams.l2l3TokenBridgeGasLimit * gasParams.l3GasPriceBid;
    }
}
