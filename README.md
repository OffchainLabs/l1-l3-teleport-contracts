# L1 -> L3 ERC20 Teleportation

### Summary

In short, there are 3 legs of an L1 -> L3 teleportation:
1. Send tokens from L1 to the `L2Forwarder`
2. Create an `L2Forwarder` if it doesn't already exist and start the third leg
3. Send tokens and ETH from the `L2Forwarder` to the recipient on L3

### Deployment Procedure
1. Predict the address of `Teleporter` on L1, it will be deployed via CREATE1
2. Using the predicted teleporter address, deploy the following with the CREATE2 Factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`
    1. The `L2Forwarder` implementation
    2. The `Beacon` (transfer ownership after deployment)
    3. The `L2ForwarderFactory`
3. Deploy the `Teleporter` on L1

### Detailed Teleportation Flow

1. User approves `Teleporter` to spend their tokens
2. User calls `Teleporter.teleport`
    1. Computes the user's `L2Forwarder` address
    2. Sends tokens (and excess fees/value) over the bridge to their `L2Forwarder`
    3. Sends a retryable to call `L2ForwarderFactory.callForwarder` with all excess `msg.value` sent as `l2CallValue`
3. Retryable 1 is redeemed: tokens and a little bit of ETH land in the `L2Forwarder` address (which may or may not be a contract yet)
4. Retryable 2 is redeemed: `L2ForwarderFactory.callForwarder`
    1. Create and initialize the user's `L2Forwarder` via `ClonableBeaconProxy` if it does not already exist.
    2. Call `L2Forwarder.bridgeToL3{value: msg.value}`
5. `L2Forwarder.bridgeToL3`
    1. Send the specified amount of tokens through the bridge to L3. The contract's entire balance minus execution fee is sent as submission fee in order to forward all the extra ETH to L3.

### Retryable Failures and Race Conditions

It is assumed that the first leg will always succeed, either through auto-redemption or through manual redemption. Similarly, if the second leg succeeds, the third must also succeed.

If multiple teleportations are in flight, it does not matter if retryables are redeemed out of order as long as there are no calls to `L2Forwarder.rescue`.

If a call to `rescue` is made, any pending second leg retryables should be cancelled in the same call to avoid race conditions and recover any ETH. 

## TODO

* Custom fee token L3's
* Unit tests
