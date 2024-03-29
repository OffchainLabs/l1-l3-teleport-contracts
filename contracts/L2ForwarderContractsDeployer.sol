// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L2Forwarder} from "./L2Forwarder.sol";
import {L2ForwarderFactory} from "./L2ForwarderFactory.sol";

/// @title  L2ForwarderContractsDeployer
/// @notice Deploys the L2Forwarder implementation and factory contracts.
///         This contract should be deployed with a generic CREATE2 factory to the same address on each L2.
contract L2ForwarderContractsDeployer {
    event Deployed(address implementation, address factory);

    /// @notice Thrown when the contract is deployed on L1.
    error CannotDeployOnL1();

    /// @notice Thrown when implementation address do not match the expected ones
    error ImplAddressMismatch(address expected, address actual);

    /// @notice Thrown when factory address do not match the expected ones
    error FactoryAddressMismatch(address expected, address actual);

    /// @notice Thrown when the nonce is not supported
    error UnsupportedNonce(uint256 nonce);

    /// @dev Prevent the L2 contracts being deployed on L1.
    /// If a predicted L2Forwarder exists on L1, it can lead to incorrect retryable refunds via unintentional address aliasing
    uint256 public immutable l1ChainId;

    address public immutable implementation;
    address public immutable factory;

    constructor(address _aliasedL1Teleporter, uint256 _l1ChainId) {
        if (block.chainid == _l1ChainId) revert CannotDeployOnL1();

        l1ChainId = _l1ChainId;

        implementation = _contractAddressFrom(1);
        factory = _contractAddressFrom(2);

        address realImpl = address(new L2Forwarder(factory));
        address realFactory = address(new L2ForwarderFactory(implementation, _aliasedL1Teleporter));

        if (implementation != realImpl) revert ImplAddressMismatch(implementation, realImpl);
        if (factory != realFactory) revert FactoryAddressMismatch(factory, realFactory);

        emit Deployed(implementation, factory);
    }

    /// @notice Computes the address of a contract deployed from this address with a given nonce.
    ///         Adapted from https://ethereum.stackexchange.com/a/139230
    function _contractAddressFrom(uint256 nonce) internal view returns (address) {
        if (nonce == 0x00 || nonce > 0x7f) revert UnsupportedNonce(nonce);
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(uint8(nonce)))))
            )
        );
    }
}
