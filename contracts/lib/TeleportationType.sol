// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

enum TeleportationType {
    Standard, // Teleporting a token to an ETH fee L3
    OnlyCustomFee, // Teleporting a L3's custom fee token to a custom (non-eth) fee L3
    NonFeeTokenToCustomFee // Teleporting a non-fee token to a custom (non-eth) fee L3

}

error InvalidTeleportation();

function toTeleportationType(address token, address feeToken) pure returns (TeleportationType) {
    if (token == address(0)) {
        revert InvalidTeleportation();
    } else if (feeToken == address(0)) {
        return TeleportationType.Standard;
    } else if (token == feeToken) {
        return TeleportationType.OnlyCustomFee;
    } else {
        return TeleportationType.NonFeeTokenToCustomFee;
    }
}
