// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ContractsDeployer} from "../contracts/L2ContractsDeployer.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {ForkTest} from "./Fork.t.sol";

contract L2ForwarderTest is ForkTest {
    L2ForwarderFactory factory;
    L2Forwarder implementation;

    function setUp() public {
        L2ContractsDeployer deployer = new L2ContractsDeployer();
        factory = L2ForwarderFactory(deployer.factory());
        implementation = L2Forwarder(deployer.implementation());
    }
    
    // make sure the implementation has correct implementation and factory addresses set
    // this is needed to predict the address of the L2Forwarder based on parameters
    function testProperConstruction() public {
        assertEq(implementation.l2ForwarderFactory(), address(factory));
        assertEq(implementation.l2ForwarderImplementation(), address(implementation));
    }

    /// forge-config: default.fuzz.runs = 5
    function testCannotPassBadParams(L2Forwarder.L2ForwarderParams memory params) public {
        L2Forwarder forwarder = factory.createL2Forwarder(params);

        // change a param
        unchecked {
            params.gasLimit++;
        }

        // try to call the forwarder with the bad params
        vm.expectRevert(L2Forwarder.IncorrectParams.selector);
        forwarder.bridgeToL3(params);
    }

    // check that the L2Forwarder creates the correct bridge tx
    
}
