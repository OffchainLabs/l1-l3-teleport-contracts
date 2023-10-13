// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import {L1Teleporter} from "../contracts/L1Teleporter.sol";

contract DeployL1Teleporter is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory l2DeploymentJson = vm.readFile("./script-deploy-data/l2.json");

        address l2ForwarderFactory = l2DeploymentJson.readAddress(".L2ForwarderFactory");
        address l2ForwarderImplementation = l2DeploymentJson.readAddress(".L2ForwarderImplementation");

        vm.startBroadcast(deployerPrivateKey);

        L1Teleporter teleporter = new L1Teleporter(l2ForwarderFactory, l2ForwarderImplementation);

        string memory finalJson = vm.serializeAddress("deployment", "L1Teleporter", address(teleporter));

        vm.writeJson(finalJson, "./script-deploy-data/l1.json");
    }
}
