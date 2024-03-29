// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {L2Forwarder} from "../contracts/L2Forwarder.sol";
import {L2ForwarderFactory} from "../contracts/L2ForwarderFactory.sol";

contract L2ForwarderContractsDeployerTest is Test {
    function testDeployer(uint64 l1chain) public {
        address aliasedL1Teleporter = address(0x123);
        L2ForwarderContractsDeployer deployer = new L2ForwarderContractsDeployer(aliasedL1Teleporter, l1chain);
        L2Forwarder impl = L2Forwarder(payable(deployer.implementation()));
        L2ForwarderFactory factory = L2ForwarderFactory(deployer.factory());

        assertEq(address(impl), address(factory.l2ForwarderImplementation()), "impl mismatch");
        assertEq(address(factory), address(impl.l2ForwarderFactory()), "factory mismatch");
        assertEq(factory.aliasedL1Teleporter(), aliasedL1Teleporter, "l1Teleporter mismatch");

        // ensure FORBIDDEN_CHAIN_ID is respected
        vm.chainId(l1chain);
        vm.expectRevert(L2ForwarderContractsDeployer.CannotDeployOnL1.selector);
        new L2ForwarderContractsDeployer(aliasedL1Teleporter, l1chain);
    }
}
