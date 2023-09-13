// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {Beacon} from "../contracts/Beacon.sol";


contract TeleporterTest is Test {
    L2ForwarderFactory factory;
    Beacon beacon;
    address l1Teleporter = address(0x1100);

    function setUp() public {
        beacon = new Beacon(address(new L2Forwarder()));
        factory = new L2ForwarderFactory(address(beacon), l1Teleporter);
    }

    /// forge-config: default.fuzz.runs = 20
    function testPredictionAndActualForwarderAddresses(address l1Owner) public {
        address predicted = factory.l2ForwarderAddress(l1Owner);
        address actual = address(factory.createL2Forwarder(l1Owner));

        assertEq(predicted, actual);
    }

    function testCallForwarderAccessControl() public {
        vm.expectRevert(L2ForwarderFactory.OnlyL1Teleporter.selector);
        factory.callForwarder(address(0x1100), address(0x2200), address(0x3300), address(0x4400), 0, 0, 0);

        // todo: make a successful call
    }

    function testCreateL2ForwarderNoAccessControl() public {
        vm.prank(vm.addr(1));
        factory.createL2Forwarder(vm.addr(2));
    }
}
