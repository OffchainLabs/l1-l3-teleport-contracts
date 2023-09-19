// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ClonableBeaconProxy} from "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";

abstract contract L2ForwarderPredictor {
    struct L2ForwarderParams {
        address l1Owner;
        address token;
        address router;
        address to;
        uint256 amount;
        uint256 gasLimit;
        uint256 gasPrice;
        uint256 relayerPayment;
    }

    bytes32 constant clonableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function l2ForwarderAddress(L2ForwarderParams memory params) public view returns (address) {
        return Create2.computeAddress(_salt(params), clonableProxyHash, factory);
    }

    function _salt(L2ForwarderParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
