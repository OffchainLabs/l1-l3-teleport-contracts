// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L2Forwarder} from "./L2Forwarder.sol";
import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";

/// @title  L2ForwarderContractsDeployer
/// @notice Deploys the L2Forwarder implementation and factory contracts.
///         This contract should be deployed with a generic CREATE2 factory to the same address on each L2.
contract L2ForwarderContractsDeployer {
    event Deployed(address implementation, address factory);

    address public immutable implementation;
    address public immutable factory;

    constructor() {
        implementation = _contractAddressFrom(1);
        factory = _contractAddressFrom(2);

        address realImpl = address(new L2Forwarder(factory));
        address realFactory = address(new L2ForwarderFactory(implementation));

        require(implementation == realImpl, "impl mismatch");
        require(factory == realFactory, "factory mismatch");

        emit Deployed(implementation, factory);
    }

    /// @notice Computes the address of a contract deployed from this address with a given nonce.
    ///         Adapted from https://ethereum.stackexchange.com/a/139230
    function _contractAddressFrom(uint256 nonce) internal view returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(uint8(nonce)))))
            )
        );
    }
}
