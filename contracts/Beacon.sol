// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Beacon is Ownable {
    address public implementation;

    constructor(address _implementation) {
        implementation = _implementation;
        // Beacon is meant to be deployed with a deterministic CREATE2 factory, so set the owner to the deployer
        _transferOwnership(tx.origin);
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        implementation = newImplementation;
    }
}
