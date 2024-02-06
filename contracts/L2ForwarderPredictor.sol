// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IL2ForwarderPredictor} from "./interfaces/IL2ForwarderPredictor.sol";
import {IL2Forwarder} from "./interfaces/IL2Forwarder.sol";

abstract contract L2ForwarderPredictor is IL2ForwarderPredictor {
    /// @inheritdoc IL2ForwarderPredictor
    address public immutable l2ForwarderFactory;
    /// @inheritdoc IL2ForwarderPredictor
    address public immutable l2ForwarderImplementation;

    constructor(address _factory, address _implementation) {
        l2ForwarderFactory = _factory;
        l2ForwarderImplementation = _implementation;
    }

    /// @inheritdoc IL2ForwarderPredictor
    function l2ForwarderAddress(address owner, address routerOrInbox, address to) public view returns (address) {
        return Clones.predictDeterministicAddress(
            l2ForwarderImplementation, _salt(owner, routerOrInbox, to), l2ForwarderFactory
        );
    }

    /// @notice Creates the salt for an L2Forwarder from its owner, routerOrInbox, and to address
    function _salt(address owner, address routerOrInbox, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, routerOrInbox, to));
    }
}
