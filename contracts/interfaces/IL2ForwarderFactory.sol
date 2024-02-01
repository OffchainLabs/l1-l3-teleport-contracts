// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {IL2ForwarderPredictor} from "./IL2ForwarderPredictor.sol";
import {IL2Forwarder} from "./IL2Forwarder.sol";

/// @title  L2ForwarderFactory
/// @notice Creates L2Forwarders and calls them to bridge tokens to L3.
///         L2Forwarders are created via CREATE2 / clones.
interface IL2ForwarderFactory is IL2ForwarderPredictor {
    /// @notice Emitted when a new L2Forwarder is created
    event CreatedL2Forwarder(address indexed l2Forwarder, address indexed owner, IL2Forwarder.L2ForwarderParams params);

    /// @notice Emitted when an L2Forwarder is called to bridge tokens to L3
    event CalledL2Forwarder(address indexed l2Forwarder, IL2Forwarder.L2ForwarderParams params);

    /// @notice Thrown when any address other than the aliased L1Teleporter calls callForwarder
    error OnlyL1Teleporter();

    /// @notice Calls an L2Forwarder to bridge tokens to L3. Will create the L2Forwarder first if it doesn't exist.
    /// @param  params Parameters for the L2Forwarder
    function callForwarder(IL2Forwarder.L2ForwarderParams memory params) external payable;

    /// @notice Creates an L2Forwarder for the given parameters.
    /// @param  params Parameters for the L2Forwarder
    function createL2Forwarder(IL2Forwarder.L2ForwarderParams memory params) external returns (IL2Forwarder);

    /// @notice Aliased address of the L1Teleporter contract
    function aliasedL1Teleporter() external view returns (address);
}
