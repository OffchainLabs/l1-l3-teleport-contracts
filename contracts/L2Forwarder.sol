// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {IERC20Inbox} from "@arbitrum/nitro-contracts/src/bridge/IERC20Inbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";
import {IL2Forwarder} from "./interfaces/IL2Forwarder.sol";
import {TeleportationType, toTeleportationType} from "./lib/TeleportationType.sol";

contract L2Forwarder is L2ForwarderPredictor, IL2Forwarder {
    using SafeERC20 for IERC20;

    constructor(address _factory) L2ForwarderPredictor(_factory, address(this)) {}

    /// @inheritdoc IL2Forwarder
    function bridgeToL3(L2ForwarderParams memory params) external payable {
        if (msg.sender != l2ForwarderFactory) revert OnlyL2ForwarderFactory();

        TeleportationType teleportationType = toTeleportationType({token: params.l2Token, feeToken: params.l2FeeToken});

        if (teleportationType == TeleportationType.Standard) {
            _bridgeToEthFeeL3(params);
        } else if (teleportationType == TeleportationType.OnlyCustomFee) {
            _bridgeFeeTokenToCustomFeeL3(params);
        } else {
            _bridgeNonFeeTokenToCustomFeeL3(params);
        }
    }

    /// @inheritdoc IL2Forwarder
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external payable {
        if (l2ForwarderAddress(msg.sender) != address(this)) revert OnlyOwner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }

    /// @dev Bridge tokens to an L3 that uses ETH for fees. Entire ETH and token balance is sent.
    function _bridgeToEthFeeL3(L2ForwarderParams memory params) internal {
        // get balance and approve gateway
        // @review - routerOrInbox is user input, whoever initiated the teleport can set it to anything and get approval
        //         - currently teleport must use L2Forwarder that is owned by alias(msg.sender), so not a problem now
        uint256 tokenBalance = _approveGatewayForBalance(params.routerOrInbox, params.l2Token);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        // @review - this might create some issue when multiple teleporter are simutanously initiated and some are failed
        uint256 ethBalance = address(this).balance;
        uint256 maxSubmissionCost = address(this).balance - params.gasLimit * params.gasPriceBid;
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund{value: address(this).balance}(
            params.l2Token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPriceBid,
            abi.encode(maxSubmissionCost, bytes(""))
        );

        emit BridgedToL3(tokenBalance, ethBalance);
    }

    /// @dev Bridge fee tokens to an L3 that uses a custom fee token.
    ///      Create a single retryable to call `params.to` with the fee token amount minus fees.
    ///      Entire fee token balance is sent.
    ///      ETH is not sent anywhere even if balance is nonzero.
    function _bridgeFeeTokenToCustomFeeL3(L2ForwarderParams memory params) internal {
        uint256 tokenBalance = IERC20(params.l2Token).balanceOf(address(this));

        // transfer tokens to the inbox
        IERC20(params.l2Token).safeTransfer(params.routerOrInbox, tokenBalance);

        // create retryable ticket
        uint256 maxSubmissionCost = IERC20Inbox(params.routerOrInbox).calculateRetryableSubmissionFee(0, 0);
        uint256 callValue = tokenBalance - maxSubmissionCost - params.gasLimit * params.gasPriceBid;
        IERC20Inbox(params.routerOrInbox).createRetryableTicket({
            to: params.to,
            l2CallValue: callValue,
            maxSubmissionCost: maxSubmissionCost,
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: params.to,
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPriceBid,
            tokenTotalFeeAmount: tokenBalance,
            data: ""
        });

        emit BridgedToL3(callValue, maxSubmissionCost + params.gasLimit * params.gasPriceBid);
    }

    /// @dev Bridge non-fee tokens to an L3 that uses a custom fee token.
    ///      Send entire fee token balance to the inbox and call the L3's L1GatewayRouter to bridge entire non-fee token balance.
    ///      Overestimate the submission cost to ensure all fee tokens are sent through.
    function _bridgeNonFeeTokenToCustomFeeL3(L2ForwarderParams memory params) internal {
        // get balance and approve gateway
        uint256 tokenBalance = _approveGatewayForBalance(params.routerOrInbox, params.l2Token);

        // get feeToken balance
        uint256 feeTokenBalance = IERC20(params.l2FeeToken).balanceOf(address(this));

        // send feeToken to the inbox
        address inbox = L1GatewayRouter(params.routerOrInbox).inbox();
        IERC20(params.l2FeeToken).safeTransfer(inbox, feeTokenBalance);

        // send tokens through the bridge to intended recipient
        // overestimate submission cost to ensure all feeToken is sent through
        uint256 maxSubmissionCost = feeTokenBalance - params.gasLimit * params.gasPriceBid;
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund(
            params.l2Token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPriceBid,
            abi.encode(maxSubmissionCost, bytes(""), feeTokenBalance)
        );

        emit BridgedToL3(tokenBalance, feeTokenBalance);
    }

    function _approveGatewayForBalance(address router, address token) internal returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        address l2l3Gateway = L1GatewayRouter(router).getGateway(token);
        IERC20(token).safeApprove(l2l3Gateway, balance);
        return balance;
    }

    receive() external payable {}
}
