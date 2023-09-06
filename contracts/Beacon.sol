// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Beacon is Ownable {
    address public implementation;

    constructor(address _implementation, address _owner) {
        implementation = _implementation;
        _transferOwnership(_owner);
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        implementation = newImplementation;
    }
}
