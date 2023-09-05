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
    1. Create and initialize the user's `L2Receiver` if it does not already exist
    2. Call `L2Receiver.bridgeToL3{value: msg.value}`
5. `L2Receiver.bridgeToL3`
    1. Send the specified amount of tokens through the bridge to L3. The contract's entire balance minus execution fee is sent as submission fee in order to forward all the extra ETH to L3.

## TODO

* Custom fee token L3's
* Unit tests
* Better deployment and E2E tests