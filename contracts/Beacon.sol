// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/// @notice Beacon contract for ClonableBeaconProxy contracts
contract Beacon is Ownable, IBeacon {
    /// @notice Implementation to be used by beacon proxies
    address public implementation;

    /// @notice Creates the beacon with the specified implementation
    /// @dev    Will also set the owner of this beacon to tx.origin since this contract is meant to be deployed via CREATE2 factory
    constructor(address _implementation) {
        implementation = _implementation;
        _transferOwnership(tx.origin);
    }

    /// @notice Set the implementation for the beacon proxies.
    ///         Can only be called by the owner.
    function upgradeTo(address newImplementation) external onlyOwner {
        implementation = newImplementation;
    }
}
