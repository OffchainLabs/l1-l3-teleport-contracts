// // SPDX-License-Identifier: Apache-2.0
// pragma solidity ^0.8.13;

// import "forge-std/Script.sol";

// import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";

// contract DeployL2Contracts is Script {
//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//         bytes32 salt = vm.envBytes32("CREATE2_SALT");
//         vm.startBroadcast(deployerPrivateKey);

//         L2ForwarderContractsDeployer deployer = new L2ForwarderContractsDeployer{salt: salt}();

//         vm.serializeBytes32("deployment", "salt", bytes32(salt));
//         vm.serializeAddress("deployment", "L2ForwarderFactory", address(deployer.factory()));
//         string memory finalJson =
//             vm.serializeAddress("deployment", "L2ForwarderImplementation", address(deployer.implementation()));

//         vm.writeJson(finalJson, "./script-deploy-data/l2.json");
//     }
// }
