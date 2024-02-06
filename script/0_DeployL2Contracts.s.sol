// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {L2ForwarderContractsDeployer} from "../contracts/L2ForwarderContractsDeployer.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";

contract DeployL2Contracts is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envBytes32("CREATE2_SALT");
        uint256 l1Nonce = vm.envUint("ETH_NONCE");
        uint256 l1ChainId = vm.envUint("ETH_CHAIN_ID");

        vm.startBroadcast(deployerPrivateKey);

        address predictedL1Teleporter = _contractAddressFrom(vm.addr(deployerPrivateKey), l1Nonce);

        L2ForwarderContractsDeployer deployer = new L2ForwarderContractsDeployer{salt: salt}(
            AddressAliasHelper.applyL1ToL2Alias(predictedL1Teleporter), l1ChainId
        );

        vm.serializeAddress("deployment", "predictedL1Teleporter", predictedL1Teleporter);
        vm.serializeBytes32("deployment", "salt", bytes32(salt));
        vm.serializeAddress("deployment", "L2ForwarderFactory", address(deployer.factory()));
        string memory finalJson =
            vm.serializeAddress("deployment", "L2ForwarderImplementation", address(deployer.implementation()));

        vm.writeJson(finalJson, "./script-deploy-data/l2.json");
    }

    // from https://ethereum.stackexchange.com/a/139230
    function _contractAddressFrom(address deployer, uint256 nonce) internal pure returns (address) {
        if (nonce == 0x00) {
            return address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80)))))
            );
        }
        if (nonce <= 0x7f) {
            return address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)))))
                )
            );
        }
        if (nonce <= 0xff) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce)))
                    )
                )
            );
        }
        if (nonce <= 0xffff) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce)))
                    )
                )
            );
        }
        if (nonce <= 0xffffff) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce)))
                    )
                )
            );
        }
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), uint32(nonce))))
            )
        );
    }
}
