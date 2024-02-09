// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {IL2ForwarderPredictor} from "./IL2ForwarderPredictor.sol";
import {IL2Forwarder} from "./IL2Forwarder.sol";

/// @title  IL2ForwarderFactory
/// @notice Creates L2Forwarders and calls them to bridge tokens to L3.
///         L2Forwarders are created via CREATE2 / clones.
interface IL2ForwarderFactory is IL2ForwarderPredictor {
    /// @notice Emitted when a new L2Forwarder is created
    event CreatedL2Forwarder(address indexed l2Forwarder, address indexed owner, address routerOrInbox, address to);

    /// @notice Emitted when an L2Forwarder is called to bridge tokens to L3
    event CalledL2Forwarder(address indexed l2Forwarder, IL2Forwarder.L2ForwarderParams params);

    /// @notice Thrown when any address other than the aliased L1Teleporter calls callForwarder
    error OnlyL1Teleporter();

    /// @notice Calls an L2Forwarder to bridge tokens to L3. Will create the L2Forwarder first if it doesn't exist.
    /// @dev    Only callable by the aliased L1Teleporter.
    /// @param  params Parameters for the L2Forwarder
    function callForwarder(IL2Forwarder.L2ForwarderParams memory params) external payable;

    /// @notice Creates an L2Forwarder for the given parameters.
    /// @param  owner           Owner of the L2Forwarder
    /// @param  routerOrInbox   Address of the L1GatewayRouter or Inbox
    /// @param  to              Address to bridge tokens to
    /// @dev    This method is external to allow fund rescue when `callForwarder` reverts.
    function createL2Forwarder(address owner, address routerOrInbox, address to) external returns (IL2Forwarder);

    /// @notice Aliased address of the L1Teleporter contract
    function aliasedL1Teleporter() external view returns (address);
}
