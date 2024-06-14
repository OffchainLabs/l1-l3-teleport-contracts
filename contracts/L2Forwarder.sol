// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {IERC20Inbox} from "@arbitrum/nitro-contracts/src/bridge/IERC20Inbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IL2Forwarder} from "./interfaces/IL2Forwarder.sol";
import {TeleportationType, toTeleportationType} from "./lib/TeleportationType.sol";

contract L2Forwarder is IL2Forwarder {
    using SafeERC20 for IERC20;

    /// @inheritdoc IL2Forwarder
    address public immutable l2ForwarderFactory;

    /// @inheritdoc IL2Forwarder
    address public owner;

    constructor(address _factory) {
        l2ForwarderFactory = _factory;
        owner = _factory;
    }

    /// @inheritdoc IL2Forwarder
    function initialize(address _owner) external {
        if (msg.sender != l2ForwarderFactory) revert OnlyL2ForwarderFactory();
        if (owner != address(0)) revert AlreadyInitialized();
        owner = _owner;
    }

    /// @inheritdoc IL2Forwarder
    function bridgeToL3(L2ForwarderParams calldata params) external payable {
        if (msg.sender != l2ForwarderFactory) revert OnlyL2ForwarderFactory();

        TeleportationType teleportationType =
            toTeleportationType({token: params.l2Token, feeToken: params.l3FeeTokenL2Addr});

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
        if (msg.sender != owner) revert OnlyOwner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }

    /// @dev Bridge tokens to an L3 that uses ETH for fees. Entire ETH and token balance is sent.
    ///      params.maxSubmissionCost is ignored.
    function _bridgeToEthFeeL3(L2ForwarderParams calldata params) internal {
        // get balance and approve gateway
        uint256 tokenBalance = _approveGatewayForBalance(params.routerOrInbox, params.l2Token);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
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
    ///      params.maxSubmissionCost is ignored.
    function _bridgeFeeTokenToCustomFeeL3(L2ForwarderParams calldata params) internal {
        uint256 tokenBalance = IERC20(params.l2Token).balanceOf(address(this));

        if (tokenBalance == 0) revert ZeroTokenBalance(params.l2Token);

        // transfer tokens to the inbox
        IERC20(params.l2Token).safeTransfer(params.routerOrInbox, tokenBalance);

        // create retryable ticket
        uint256 maxSubmissionCost = IERC20Inbox(params.routerOrInbox).calculateRetryableSubmissionFee(0, 0);
        uint256 totalFeeAmount = maxSubmissionCost + (params.gasLimit * params.gasPriceBid);
        uint256 callValue = tokenBalance - totalFeeAmount;
        IERC20Inbox(params.routerOrInbox).createRetryableTicket({
            to: params.to,
            l2CallValue: callValue,
            maxSubmissionCost: maxSubmissionCost,
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: params.to,
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPriceBid,
            tokenTotalFeeAmount: tokenBalance,
            data: params.l3Calldata
        });

        emit BridgedToL3(callValue, totalFeeAmount);
    }

    /// @dev Bridge non-fee tokens to an L3 that uses a custom fee token.
    function _bridgeNonFeeTokenToCustomFeeL3(L2ForwarderParams calldata params) internal {
        // get balance and approve gateway
        uint256 tokenBalance = _approveGatewayForBalance(params.routerOrInbox, params.l2Token);

        // calculate total fee amount
        uint256 totalFeeAmount = params.gasLimit * params.gasPriceBid + params.maxSubmissionCost;

        // send feeToken to the inbox
        if (totalFeeAmount > 0) {
            address inbox = L1GatewayRouter(params.routerOrInbox).inbox();
            IERC20(params.l3FeeTokenL2Addr).safeTransfer(inbox, totalFeeAmount);
        }

        // send tokens through the bridge to intended recipient
        // use user supplied max submission fee instead of sending all the fee token balance
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund(
            params.l2Token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPriceBid,
            abi.encode(params.maxSubmissionCost, bytes(""), totalFeeAmount)
        );

        emit BridgedToL3(tokenBalance, totalFeeAmount);
    }

    function _approveGatewayForBalance(address router, address token) internal returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));

        if (balance == 0) revert ZeroTokenBalance(token);

        address l2l3Gateway = L1GatewayRouter(router).getGateway(token);
        IERC20(token).forceApprove(l2l3Gateway, balance);
        return balance;
    }

    receive() external payable {}
}
