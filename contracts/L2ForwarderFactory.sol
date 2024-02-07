// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";
import {IL2ForwarderFactory} from "./interfaces/IL2ForwarderFactory.sol";
import {IL2Forwarder} from "./interfaces/IL2Forwarder.sol";

contract L2ForwarderFactory is L2ForwarderPredictor, IL2ForwarderFactory {
    /// @inheritdoc IL2ForwarderFactory
    address public immutable aliasedL1Teleporter;

    constructor(address _impl, address _aliasedL1Teleporter) L2ForwarderPredictor(address(this), _impl) {
        aliasedL1Teleporter = _aliasedL1Teleporter;
    }

    /// @inheritdoc IL2ForwarderFactory
    function callForwarder(IL2Forwarder.L2ForwarderParams memory params) external payable {
        if (msg.sender != aliasedL1Teleporter) revert OnlyL1Teleporter();

        IL2Forwarder l2Forwarder = _tryCreateL2Forwarder(params.owner, params.routerOrInbox, params.to);

        l2Forwarder.bridgeToL3{value: msg.value}(params);

        emit CalledL2Forwarder(address(l2Forwarder), params);
    }

    /// @inheritdoc IL2ForwarderFactory
    function createL2Forwarder(address owner, address routerOrInbox, address to) public returns (IL2Forwarder) {
        IL2Forwarder l2Forwarder =
            IL2Forwarder(payable(Clones.cloneDeterministic(l2ForwarderImplementation, _salt(owner, routerOrInbox, to))));

        l2Forwarder.initialize(owner);

        emit CreatedL2Forwarder(address(l2Forwarder), owner, routerOrInbox, to);

        return l2Forwarder;
    }

    /// @dev Create an L2Forwarder if it doesn't exist, otherwise return the existing one.
    function _tryCreateL2Forwarder(address owner, address routerOrInbox, address to) internal returns (IL2Forwarder) {
        address calculatedAddress = l2ForwarderAddress(owner, routerOrInbox, to);

        if (calculatedAddress.code.length > 0) {
            // contract already exists
            return IL2Forwarder(payable(calculatedAddress));
        }

        // contract doesn't exist, create it
        return createL2Forwarder(owner, routerOrInbox, to);
    }
}
