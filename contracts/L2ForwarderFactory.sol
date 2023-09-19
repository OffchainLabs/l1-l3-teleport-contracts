// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {
    ProxySetter,
    ClonableBeaconProxy
} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {L2Forwarder} from "./L2Forwarder.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

contract L2ForwarderFactory is L2ForwarderPredictor {
    /// @notice Emitted when a new L2Forwarder is created
    event CreatedL2Forwarder(address indexed l2Forwarder, L2ForwarderParams params);

    /// @notice Emitted when an L2Forwarder is called to bridge tokens to L3
    event CalledL2Forwarder(
        address indexed l2Forwarder, L2ForwarderParams params
    );

    constructor(address _impl) L2ForwarderPredictor(address(this), _impl) {}

    /// @notice Calls an L2Forwarder to bridge tokens to L3. Will create the L2Forwarder first if it doesn't exist.
    function callForwarder(L2ForwarderParams memory params) external {
        L2Forwarder l2Forwarder = _tryCreateL2Forwarder(params);

        l2Forwarder.bridgeToL3(params);

        emit CalledL2Forwarder(address(l2Forwarder), params);
    }

    /// @notice Creates an L2Forwarder for the given L1 owner. There is no access control.
    function createL2Forwarder(L2ForwarderParams memory params) public returns (L2Forwarder) {
        L2Forwarder l2Forwarder = L2Forwarder(Clones.cloneDeterministic(l2ForwarderImplementation, _salt(params)));
        l2Forwarder.initialize(params.l1Owner);

        emit CreatedL2Forwarder(address(l2Forwarder), params);

        return l2Forwarder;
    }

    /// @dev Create an L2Forwarder if it doesn't exist, otherwise return the existing one.
    function _tryCreateL2Forwarder(L2ForwarderParams memory params) internal returns (L2Forwarder) {
        address calculatedAddress = l2ForwarderAddress(params);

        uint256 size;
        assembly {
            size := extcodesize(calculatedAddress)
        }
        if (size > 0) {
            // contract already exists
            return L2Forwarder(calculatedAddress);
        }

        // contract doesn't exist, create it
        return createL2Forwarder(params);
    }
}