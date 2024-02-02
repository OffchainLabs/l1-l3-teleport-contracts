// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

enum TeleportationType {
    Standard,
    OnlyCustomFee,
    NonFeeTokenToCustomFee
}

function _teleportationType(address token, address feeToken) pure returns (TeleportationType) {
    if (feeToken == address(0)) {
        // we are teleporting a token to an ETH fee L3
        return TeleportationType.Standard;
    } else if (token == feeToken) {
        // we are teleporting an L3's fee token
        return TeleportationType.OnlyCustomFee;
    } else {
        // we are teleporting a non-fee token to a custom fee L3
        return TeleportationType.NonFeeTokenToCustomFee;
    }
}
