// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

abstract contract AccessControlPausable is Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    constructor(address defaultAdmin, address pauser) {
        _setupRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _setupRole(PAUSER_ROLE, pauser);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
