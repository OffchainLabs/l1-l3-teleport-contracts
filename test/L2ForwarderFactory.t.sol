// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {Beacon} from "../contracts/Beacon.sol";
import {ClonableBeaconProxy} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {AddressAliasHelper} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/AddressAliasHelper.sol";
import {ForkTest} from "./Fork.t.sol";
import {MockToken} from "../contracts/mocks/MockToken.sol";

contract TeleporterTest is ForkTest {
    L2ForwarderFactory factory;
    Beacon beacon;
    MockToken l2Token;
    address predictedForwarder;
    address l1Teleporter = address(0x1100);
    address l1Owner = address(0x2200);

    function setUp() public {
        beacon = new Beacon(address(new L2Forwarder()));
        factory = new L2ForwarderFactory(address(beacon), l1Teleporter);
        l2Token = new MockToken("MOCK", "MOCK", 100 ether, address(this));
        predictedForwarder = factory.l2ForwarderAddress(l1Owner);
    }

    function testPredictionAndActualForwarderAddresses() public {
        address actual = address(factory.createL2Forwarder(l1Owner));

        assertEq(predictedForwarder, actual);

        assertTrue(_isForwarder(actual));
    }

    function testCallForwarderAccessControl() public {
        vm.expectRevert(L2ForwarderFactory.OnlyL1Teleporter.selector);
        factory.callForwarder(address(0x1100), address(0x2200), address(0x3300), address(0x4400), 0, 0, 0);
    }

    function testCreateL2ForwarderNoAccessControl() public {
        vm.prank(vm.addr(1));
        factory.createL2Forwarder(vm.addr(2));
    }

    function testCallForwarder() public {
        l2Token.transfer(predictedForwarder, 10 ether);
        vm.deal(predictedForwarder, 10 ether);
        vm.deal(AddressAliasHelper.applyL1ToL2Alias(l1Teleporter), 1 ether);

        address to = address(0x3300);

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1Teleporter));
        vm.expectCall(
            predictedForwarder,
            1 ether,
            abi.encodeCall(
                L2Forwarder.bridgeToL3,
                (
                    address(l2Token),
                    address(l1l2Router),
                    to,
                    10 ether,
                    1_000_000,
                    0.1 gwei
                )
            )
        );
        factory.callForwarder{value: 1 ether}({
            l1Owner: l1Owner,
            token: address(l2Token),
            router: address(l1l2Router),
            to: to,
            amount: 10 ether,
            gasLimit: 1_000_000,
            gasPrice: 0.1 gwei
        });
    }

    function _isForwarder(address addr) internal view returns (bool) {
        uint256 size;

        assembly {
            size := extcodesize(addr)
        }
        
        bytes memory code = new bytes(size);

        assembly {
            extcodecopy(addr, add(code, 0x20), 0, size)
        }

        return keccak256(code) == keccak256(type(ClonableBeaconProxy).runtimeCode);
    }
}
