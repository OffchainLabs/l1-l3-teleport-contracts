// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import {L1Teleporter} from "../contracts/L1Teleporter.sol";

contract DeployL1Teleporter is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.envAddress("TELEPORTER_ADMIN");
        address pauser = vm.envAddress("TELEPORTER_PAUSER");
        string memory deploymentJson = vm.readFile("./script-deploy-data/deployment.json");

        address teleporterAddress = deploymentJson.readAddress(".L1Teleporter");
        address l2ForwarderFactory = deploymentJson.readAddress(".L2ForwarderFactory");
        address l2ForwarderImplementation = deploymentJson.readAddress(".L2ForwarderImplementation");

        vm.startBroadcast(deployerPrivateKey);

        L1Teleporter teleporter = new L1Teleporter({
            _l2ForwarderFactory: l2ForwarderFactory,
            _l2ForwarderImplementation: l2ForwarderImplementation,
            _admin: admin,
            _pauser: pauser
        });

        require(address(teleporter) == teleporterAddress, "L1Teleporter address mismatch");
    }
}
