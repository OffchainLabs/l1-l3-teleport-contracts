// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title  L2ForwarderPredictor
/// @notice Predicts the address of an L2Forwarder based on its parameters
abstract contract L2ForwarderPredictor {
    /// @notice Parameters for an L2Forwarder
    /// @dev    When changing this struct, be sure to change L1Teleporter.l2ForwarderFactoryCalldataSize
    /// @param  owner           Address of the L2Forwarder owner. Setting this incorrectly could result in loss of funds.
    /// @param  token           Address of the L2 token to bridge to L3
    /// @param  router          Address of the L2 -> L3 GatewayRouter
    /// @param  to              Address of the recipient on L3
    /// @param  gasLimit        Gas limit for the L2 -> L3 retryable
    /// @param  gasPrice        Gas price for the L2 -> L3 retryable
    /// @param  relayerPayment  Amount of ETH to pay the relayer
    struct L2ForwarderParams {
        address owner;
        address token;

        address l2FeeToken; // 0x00 for ETH, addr of l3 fee token on L2
        address routerOrInbox;
        
        address to;
        uint256 gasLimit;
        uint256 gasPrice;
        uint256 relayerPayment;
    }

    /// @notice Address of the L2ForwarderFactory
    address public immutable l2ForwarderFactory;
    /// @notice Address of the L2Forwarder implementation
    address public immutable l2ForwarderImplementation;

    constructor(address _factory, address _implementation) {
        l2ForwarderFactory = _factory;
        l2ForwarderImplementation = _implementation;
    }

    /// @notice Predicts the address of an L2Forwarder based on its parameters
    function l2ForwarderAddress(L2ForwarderParams memory params) public view returns (address) {
        return Clones.predictDeterministicAddress(l2ForwarderImplementation, _salt(params), l2ForwarderFactory);
    }

    /// @notice Computes the salt for an L2Forwarder based on its parameters
    /// @dev    It is just the keccak256 hash of the abi encoded params
    function _salt(L2ForwarderParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
