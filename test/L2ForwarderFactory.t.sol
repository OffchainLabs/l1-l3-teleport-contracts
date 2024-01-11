// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";

contract L2ForwarderFactoryTest is Test {
    L2ForwarderFactory factory;

    address aliasedL1Teleporter = address(0x2211);

    function setUp() public {
        factory = L2ForwarderFactory((new L2ForwarderContractsDeployer(aliasedL1Teleporter)).factory());
    }

    /// forge-config: default.fuzz.runs = 20
    function testPredictionAndActualForwarderAddresses(L2ForwarderFactory.L2ForwarderParams memory params) public {
        address actual = address(factory.createL2Forwarder(params));
        address predicted = factory.l2ForwarderAddress(params);
        assertEq(predicted, actual);
    }

    function testProperForwarderInitialization() public {
        L2ForwarderFactory.L2ForwarderParams memory params;
        params.owner = address(0x2200);
        L2Forwarder forwarder = factory.createL2Forwarder(params);
        assertEq(forwarder.owner(), params.owner);
    }

    function testOnlyL1Teleporter() public {
        L2ForwarderFactory.L2ForwarderParams memory params;
        vm.expectRevert(L2ForwarderFactory.OnlyL1Teleporter.selector);
        factory.callForwarder(params);
        vm.prank(aliasedL1Teleporter);
        (bool success, bytes memory data) =
            address(factory).call(abi.encodeCall(L2ForwarderFactory.callForwarder, params));
        assertFalse(success);
        assertEq(data.length, 0);
    }
}
