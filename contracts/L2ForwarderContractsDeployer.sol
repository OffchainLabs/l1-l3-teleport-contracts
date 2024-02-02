// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L2Forwarder} from "./L2Forwarder.sol";
import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";

/// @title  L2ForwarderContractsDeployer
/// @notice Deploys the L2Forwarder implementation and factory contracts.
///         This contract should be deployed with a generic CREATE2 factory to the same address on each L2.
contract L2ForwarderContractsDeployer {
    event Deployed(address implementation, address factory);

    /// @dev Prevent the L2 contracts being deployed on L1.
    /// If a predicted L2Forwarder exists on L1, it can lead to incorrect retryable refunds via unintentional address aliasing
    uint256 constant FORBIDDEN_CHAIN_ID = 1;

    address public immutable implementation;
    address public immutable factory;

    constructor(address _aliasedL1Teleporter) {
        require(block.chainid != FORBIDDEN_CHAIN_ID, "deployer cannot be used on L1");

        implementation = _contractAddressFrom(1);
        factory = _contractAddressFrom(2);

        address realImpl = address(new L2Forwarder(factory));
        address realFactory = address(new L2ForwarderFactory(implementation, _aliasedL1Teleporter));

        require(implementation == realImpl, "impl mismatch");
        require(factory == realFactory, "factory mismatch");

        emit Deployed(implementation, factory);
    }

    /// @notice Computes the address of a contract deployed from this address with a given nonce.
    ///         Adapted from https://ethereum.stackexchange.com/a/139230
    function _contractAddressFrom(uint256 nonce) internal view returns (address) {
        require(nonce > 0x00 && nonce <= 0x7f, "unsupported nonce");
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(uint8(nonce)))))
            )
        );
    }
}
