// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";

contract DeployL2Contracts is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envBytes32("CREATE2_SALT");
        address l1Teleporter = vm.envAddress("L1_TELEPORTER");
        uint256 l1ChainId = vm.envUint("L1_CHAIN_ID");

        vm.startBroadcast(deployerPrivateKey);

        // Deployed via 0x4e59b44847b379578588920cA78FbF26c0B4956C generic CREATE2 factory
        L2ForwarderContractsDeployer deployer =
            new L2ForwarderContractsDeployer{salt: salt}(AddressAliasHelper.applyL1ToL2Alias(l1Teleporter), l1ChainId);

        vm.serializeAddress("deployment", "L1Teleporter", l1Teleporter);
        vm.serializeBytes32("deployment", "salt", bytes32(salt));
        vm.serializeAddress("deployment", "L2ForwarderFactory", address(deployer.factory()));
        string memory finalJson =
            vm.serializeAddress("deployment", "L2ForwarderImplementation", address(deployer.implementation()));

        vm.writeJson(finalJson, "./script-deploy-data/deployment.json");
    }
}
