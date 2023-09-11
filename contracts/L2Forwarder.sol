// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Forwarder contract for bridging tokens from L1 to L3.
///         Tokens and a small amount of ETH are sent to this contract during the first leg of a teleportation,
///         in the second leg the L2ForwarderFactory calls bridgeToL3 on this contract to send the tokens to L3.
///         Each address on L1 that wants to bridge tokens to L3 has one of these.
///         L2Forwarder addresses will be the same on each L2 for a given L1 address.
///         To get the address of the L2Forwarder for an L1 address, call Teleporter.l2ForwarderAddress.
contract L2Forwarder {
    using SafeERC20 for IERC20;

    /// @notice L1 address that owns this L2Forwarder
    address public l1Owner;

    /// @notice L2ForwarderFactory that created this L2Forwarder
    address public factory;

    /// @notice Emitted when tokens are forwarded to an L3
    /// @param  token           Token being forwarded
    /// @param  router          Token bridge router to L3
    /// @param  to              Address on L3 that will receive the tokens and extra ETH
    /// @param  amount          Amount of tokens being forwarded
    /// @param  gasLimit        Gas limit for the retryable to L3
    /// @param  gasPrice        Gas price for the retryable to L3
    /// @param  submissionCost  Submission cost for the retryable to L3
    event BridgedToL3(
        address indexed token,
        address indexed router,
        address indexed to,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 submissionCost
    );

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    /// @notice Thrown when initialize is called after initialization
    error AlreadyInitialized();
    /// @notice Thrown when a non-factory calls bridgeToL3
    error OnlyFactory();
    /// @notice Thrown when a non-owner calls rescue
    error OnlyL1Owner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);

    /// @notice Initialize this L2Forwarder
    /// @param  _l1Owner The L1 address that owns this L2Forwarder
    /// @dev    Can only be called once. It will also set the factory to the caller.
    function initialize(address _l1Owner) external {
        if (l1Owner != address(0)) revert AlreadyInitialized();
        l1Owner = _l1Owner;
        factory = msg.sender;
    }

    /// @notice Forward tokens to L3. Can only be called by the factory (L2ForwarderFactory).
    ///         Will forward entire ETH balance to L3.
    /// @param  token       Token being forwarded
    /// @param  router      Token bridge router to L3
    /// @param  to          Address on L3 that will receive the tokens and extra ETH
    /// @param  amount      Amount of tokens being forwarded
    /// @param  gasLimit    Gas limit for the retryable to L3
    /// @param  gasPrice    Gas price for the retryable to L3
    function bridgeToL3(address token, address router, address to, uint256 amount, uint256 gasLimit, uint256 gasPrice)
        external
        payable
    {
        if (msg.sender != factory) revert OnlyFactory();

        // get gateway
        address l2l3Gateway = L1GatewayRouter(router).getGateway(token);

        // approve gateway
        IERC20(token).safeApprove(l2l3Gateway, amount);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 submissionCost = address(this).balance - gasLimit * gasPrice;
        L1GatewayRouter(router).outboundTransferCustomRefund{value: address(this).balance}(
            token, to, to, amount, gasLimit, gasPrice, abi.encode(submissionCost, bytes(""))
        );

        emit BridgedToL3(token, router, to, amount, gasLimit, gasPrice, submissionCost);
    }

    /// @notice Allows the L1 owner of this L2Forwarder to make arbitrary calls.
    ///         If the second leg of a teleportation fails, the L1 owner can call this to rescue their tokens.
    ///         When transferring tokens, failing second leg retryables should be cancelled to avoid race conditions and retreive any ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Owner)) revert OnlyL1Owner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }
}
