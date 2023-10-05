// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

abstract contract L2ForwarderPredictor {
    struct L2ForwarderParams {
        address owner;
        address token;
        address router;
        address to;
        uint256 amount;
        uint256 gasLimit;
        uint256 gasPrice;
        uint256 relayerPayment;
        uint256 randomNonce;
    }

    address public immutable l2ForwarderFactory;
    address public immutable l2ForwarderImplementation;

    constructor(address _factory, address _implementation) {
        l2ForwarderFactory = _factory;
        l2ForwarderImplementation = _implementation;
    }

    function l2ForwarderAddress(L2ForwarderParams memory params) public view returns (address) {
        return Clones.predictDeterministicAddress(l2ForwarderImplementation, _salt(params), l2ForwarderFactory);
    }

    function _salt(L2ForwarderParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
