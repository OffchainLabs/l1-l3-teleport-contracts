// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {IL2Forwarder} from "./IL2Forwarder.sol";

/// @title  L2ForwarderPredictor
/// @notice Predicts the address of an L2Forwarder based on its parameters
interface IL2ForwarderPredictor {
    /// @notice Address of the L2ForwarderFactory
    function l2ForwarderFactory() external view returns (address);
    /// @notice Address of the L2Forwarder implementation
    function l2ForwarderImplementation() external view returns (address);
    /// @notice Predicts the address of an L2Forwarder based on its owner
    function l2ForwarderAddress(IL2Forwarder.L2ForwarderParams memory params) external view returns (address);
}
