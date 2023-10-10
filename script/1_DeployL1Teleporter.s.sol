// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import {Teleporter} from "../contracts/Teleporter.sol";

contract DeployL1Teleporter is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory l2DeploymentJson = vm.readFile("./script-deploy-data/l2.json");

        address l2ForwarderFactory = l2DeploymentJson.readAddress(".L2ForwarderFactory");
        address l2ForwarderImplementation = l2DeploymentJson.readAddress(".L2ForwarderImplementation");

        vm.startBroadcast(deployerPrivateKey);

        Teleporter teleporter = new Teleporter(l2ForwarderFactory, l2ForwarderImplementation);

        string memory finalJson = vm.serializeAddress("deployment", "Teleporter", address(teleporter));

        vm.writeJson(finalJson, "./script-deploy-data/l1.json");
    }
}
