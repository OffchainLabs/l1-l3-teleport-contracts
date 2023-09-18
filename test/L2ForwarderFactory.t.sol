// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {Beacon} from "../contracts/Beacon.sol";
import {ClonableBeaconProxy} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {ForkTest} from "./Fork.t.sol";

contract TeleporterTest is ForkTest {
    L2ForwarderFactory factory;
    Beacon beacon;
    address l1Teleporter = address(0x1100);

    function setUp() public {
        beacon = new Beacon(address(new L2Forwarder()));
        factory = new L2ForwarderFactory(address(beacon), l1Teleporter);
    }

    /// forge-config: default.fuzz.runs = 20
    function testPredictionAndActualForwarderAddresses() public {
        address l1Owner = address(0x2200);
        address predicted = factory.l2ForwarderAddress(l1Owner);
        address actual = address(factory.createL2Forwarder(l1Owner));

        assertEq(predicted, actual);

        bytes memory code;

        assembly {
            let size := extcodesize(actual)
            // allocate code byte array with new size
            mstore(code, size)
            // update free memory pointer
            mstore(0x40, add(code, add(0x20, size)))
            // copy the code
            extcodecopy(actual, add(code, 0x20), 0, size)
        }

        assertEq(keccak256(code), keccak256(type(ClonableBeaconProxy).runtimeCode));
    }

    function testCallForwarderAccessControl() public {
        vm.expectRevert(L2ForwarderFactory.OnlyL1Teleporter.selector);
        factory.callForwarder(address(0x1100), address(0x2200), address(0x3300), address(0x4400), 0, 0, 0);
    }

    function testCreateL2ForwarderNoAccessControl() public {
        vm.prank(vm.addr(1));
        factory.createL2Forwarder(vm.addr(2));
    }


}
