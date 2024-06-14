// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {IL2ForwarderPredictor} from "./IL2ForwarderPredictor.sol";

/// @title  IL2Forwarder
/// @notice L2 contract that receives ERC20 tokens to forward to L3.
///         May receive either token and ETH, token and the L3 feeToken, or just feeToken if token == feeToken.
///         In case funds cannot be bridged to L3, the owner can call rescue to get their funds back.
interface IL2Forwarder {
    /// @notice Parameters for an L2Forwarder
    /// @param  owner               Address of the L2Forwarder owner. Setting this incorrectly could result in loss of funds.
    /// @param  l2Token             Address of the L2 token to bridge to L3
    /// @param  l3FeeTokenL2Addr    Address of the L3's fee token, or 0x00 for ETH
    /// @param  routerOrInbox       Address of the L2 -> L3 GatewayRouter or Inbox if depositing only custom fee token
    /// @param  to                  Address of the recipient on L3
    /// @param  gasLimit            Gas limit for the L2 -> L3 retryable
    /// @param  gasPriceBid         Gas price for the L2 -> L3 retryable
    /// @param  maxSubmissionCost   Max submission fee for the L2 -> L3 retryable. Is ignored for Standard and OnlyCustomFee teleportation types.
    /// @param  l3Calldata          Calldata for the L2ForwarderFactory call on L2 to L3 retryable
    struct L2ForwarderParams {
        address owner;
        address l2Token;
        address l3FeeTokenL2Addr;
        address routerOrInbox;
        address to;
        uint256 gasLimit;
        uint256 gasPriceBid;
        uint256 maxSubmissionCost;
        bytes l3Calldata;
    }

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    /// @notice Emitted after a successful call to bridgeToL3
    event BridgedToL3(uint256 tokenAmount, uint256 feeAmount);

    /// @notice Thrown when initialize is called more than once
    error AlreadyInitialized();
    /// @notice Thrown when a non-owner calls rescue
    error OnlyOwner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);
    /// @notice Thrown when bridgeToL3 is called by an address other than the L2ForwarderFactory
    error OnlyL2ForwarderFactory();
    /// @notice Thrown when the L2Forwarder has no balance of the token to bridge
    error ZeroTokenBalance(address token);

    /// @notice Initialize the L2Forwarder with the owner
    function initialize(address _owner) external;

    /// @notice Send tokens + (fee tokens or ETH) through the bridge to a recipient on L3.
    /// @param  params Parameters of the bridge transaction.
    /// @dev    Can only be called by the L2ForwarderFactory.
    function bridgeToL3(L2ForwarderParams calldata params) external payable;

    /// @notice Allows the owner of this L2Forwarder to make arbitrary calls.
    ///         If bridgeToL3 cannot succeed, the owner can call this to rescue their tokens and ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external payable;

    /// @notice The owner of this L2Forwarder. Authorized to call rescue.
    function owner() external view returns (address);

    /// @notice The address of the L2ForwarderFactory
    function l2ForwarderFactory() external view returns (address);
}
