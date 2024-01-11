// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {IERC20Inbox} from "@arbitrum/nitro-contracts/src/bridge/IERC20Inbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

/// @title  L2Forwarder
/// @notice L2 contract that receives ERC20 tokens to forward to L3.
///         May receive either token and ETH, token and the L3 feeToken, or just feeToken if token == feeToken.
///         In case funds cannot be bridged to L3, the owner can call rescue to get their funds back.
contract L2Forwarder is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice Address that owns this L2Forwarder and can make arbitrary calls via rescue
    address public owner;

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    /// @notice Emitted after a successful call to bridgeToL3
    event BridgedToL3(uint256 tokenAmount, uint256 feeAmount);

    /// @notice Thrown when initialize is called after initialization
    error AlreadyInitialized();
    /// @notice Thrown when a non-owner calls rescue
    error OnlyOwner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);
    /// @notice Thrown when the relayer payment fails
    error RelayerPaymentFailed();
    /// @notice Thrown when bridgeToL3 is called by an address other than the L2ForwarderFactory
    error OnlyL2ForwarderFactory();

    constructor(address _factory) L2ForwarderPredictor(_factory, address(this)) {}

    /// @notice Initialize this L2Forwarder
    /// @param  _owner Address that owns this L2Forwarder
    /// @dev    Can only be called once. Failing to set owner properly could result in loss of funds.
    function initialize(address _owner) external {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = _owner;
    }

    /// @notice Send tokens + (fee tokens or ETH) through the bridge to a recipient on L3.
    /// @param  params Parameters of the bridge transaction.
    /// @dev    Can only be called by the L2ForwarderFactory.
    function bridgeToL3(L2ForwarderParams memory params) external payable {
        if (msg.sender != l2ForwarderFactory) revert OnlyL2ForwarderFactory();

        if (params.l2FeeToken == address(0)) {
            _bridgeToEthFeeL3(params);
        } else if (params.l2FeeToken == params.l2Token) {
            _bridgeFeeTokenToCustomFeeL3(params);
        } else {
            _bridgeNonFeeTokenToCustomFeeL3(params);
        }
    }

    /// @notice Allows the owner of this L2Forwarder to make arbitrary calls.
    ///         If bridgeToL3 cannot succeed, the owner can call this to rescue their tokens and ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
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
    function _bridgeToEthFeeL3(L2ForwarderParams memory params) internal {
        // get balance and approve gateway
        uint256 tokenBalance = _approveGatewayForBalance(params.routerOrInbox, params.l2Token);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 ethBalance = address(this).balance;
        uint256 submissionCost = address(this).balance - params.gasLimit * params.gasPrice;
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund{value: address(this).balance}(
            params.l2Token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPrice,
            abi.encode(submissionCost, bytes(""))
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

        // get inbox balance of fee token (l2Token is fee token)
        uint256 inboxBalance = IERC20(params.l2Token).balanceOf(params.routerOrInbox);

        // create retryable ticket
        uint256 submissionCost = IERC20Inbox(params.routerOrInbox).calculateRetryableSubmissionFee(0, 0);
        uint256 callValue = inboxBalance - submissionCost - params.gasLimit * params.gasPrice;
        IERC20Inbox(params.routerOrInbox).createRetryableTicket({
            to: params.to,
            l2CallValue: callValue,
            maxSubmissionCost: submissionCost,
            excessFeeRefundAddress: params.to,
            callValueRefundAddress: params.to,
            gasLimit: params.gasLimit,
            maxFeePerGas: params.gasPrice,
            tokenTotalFeeAmount: tokenBalance,
            data: ""
        });

        emit BridgedToL3(callValue, submissionCost + params.gasLimit * params.gasPrice);
    }

    /// @dev Bridge non-fee tokens to an L3 that uses a custom fee token.
    ///      Send entire fee token balance to the inbox and call the L3's L1GatewayRouter to bridge entire non-fee token balance.
    ///      Overestimate the submission cost to ensure all fee tokens are sent through.
    function _bridgeNonFeeTokenToCustomFeeL3(L2ForwarderParams memory params) internal {
        // get balance and approve gateway
        uint256 tokenBalance = _approveGatewayForBalance(params.routerOrInbox, params.l2Token);

        // get feeToken balance
        uint256 feeTokenBalance = IERC20(params.l2FeeToken).balanceOf(address(this));

        // get inbox
        address inbox = L1GatewayRouter(params.routerOrInbox).inbox();

        // send feeToken to the inbox if we have any
        if (feeTokenBalance > 0) {
            IERC20(params.l2FeeToken).safeTransfer(inbox, feeTokenBalance);
        }

        // get inbox balance of fee token
        uint256 inboxBalance = IERC20(params.l2FeeToken).balanceOf(inbox);

        // send tokens through the bridge to intended recipient
        // overestimate submission cost to ensure all feeToken is sent through
        uint256 submissionCost = inboxBalance - params.gasLimit * params.gasPrice;
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund(
            params.l2Token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPrice,
            abi.encode(submissionCost, bytes(""), feeTokenBalance)
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
