// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L2Forwarder} from "./L2Forwarder.sol";
import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";

// from https://ethereum.stackexchange.com/a/139230
contract ComputeCREATE1 {
    function contractAddressFrom(uint256 nonce) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(uint8(nonce)))))));
    }
}

// deploy this with the CREATE2 factory
contract L2ContractsDeployer is ComputeCREATE1 {
    event Deployed(
        address implementation,
        address factory
    );

    address public immutable implementation;
    address public immutable factory;

    constructor() {
        implementation = contractAddressFrom(1);
        factory = contractAddressFrom(2);

        address realImpl = address(new L2Forwarder(factory));
        address realFactory = address(new L2ForwarderFactory(implementation));

        require(implementation == realImpl, "impl mismatch");
        require(factory == realFactory, "factory mismatch");

        emit Deployed(implementation, factory);
    }
}