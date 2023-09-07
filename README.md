# L1 -> L3 ERC20 Bridging

__Setup__
* `Teleporter` is deployed to L1
* `L2ReceiverFactory` is deployed to each L2 that has L3's

__Bridging__
1. User approves `Teleporter` to spend their tokens
2. User calls `Teleporter.teleport`
    1. Computes the user's `L2Receiver` address
    2. Sends tokens (and excess fees/value) over the bridge to their `L2Receiver`
    3. Sends a retryable to call `L2ReceiverFactory.bridgeToL3` with all excess `msg.value` forwarded as `l2CallValue`
3. Retryable 1 is redeemed: tokens and a little bit of ETH land in the `L2Receiver` address (which may or may not be a contract yet)
4. Retryable 2 is redeemed: `L2ReceiverFactory.bridgeToL3`
    1. Create and initialize the user's `L2Receiver` via `ClonableBeaconProxy` if it does not already exist.
    2. Call `L2Receiver.bridgeToL3{value: msg.value}`
5. `L2Receiver.bridgeToL3`
    1. Send the specified amount of tokens through the bridge to L3. The contract's entire balance minus execution fee is sent as submission fee in order to forward all the extra ETH to L3.

__Deployment Procedure__
1. Predict the address of `Teleporter` on L1, it will be deployed via CREATE1
2. Using the predicted teleporter address, deploy the following with the CREATE2 Factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`
    1. The `L2Receiver` implementation
    2. The `Beacon` (transfer ownership after deployment)
    3. The `L2ReceiverFactory`
3. Deploy the `Teleporter` on L1

## TODO

* Custom fee token L3's
* Unit tests
* Better deployment and E2E tests
* Should `L2ReceiverFactory` and `Teleport` be upgradeable?