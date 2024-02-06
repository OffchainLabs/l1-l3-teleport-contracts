# L1 -> L3 ERC20 Teleportation

Contracts enabling direct ERC20 bridging from L1 to L3.

### Summary

In short, there are 3 steps to an L1 -> L3 teleportation:
1. Send funds from L1 to a personal `L2Forwarder` whose address depends on its parameters
2. Create the `L2Forwarder` if it doesn't already exist and start the third step
3. Send tokens and ETH from the `L2Forwarder` to the recipient on L3

### Deployment Procedure
1. Deploy `L2ForwarderContractsDeployer` using a generic CREATE2 factory such as `0x4e59b44847b379578588920cA78FbF26c0B4956C` on each L2. This will deploy the `L2ForwarderFactory` and `L2Forwarder` implementation. Use the same salt on each L2.
2. Deploy `L1Teleporter` to L1, passing the L2 factory and implementation addresses to the constructor.

### Teleportation Flow

1. User approves `L1Teleporter` to spend TOKEN (if the L3 uses a custom fee token, approve the fee token too)
2. User calls `L1Teleporter.teleport`:
    1. Computes the `L2Forwarder` address
    2. Sends tokens over the bridge to the `L2Forwarder`. (if using a custom fee token, send those to the forwarder as well)
    3. Creates a retryable to call `L2ForwarderFactory.callForwarder`
3. Token bridge retryable(s) redeemed: tokens land in the `L2Forwarder` address (which may or may not have code yet)
4. Factory retryable redeemed: `L2ForwarderFactory.callForwarder`
    1. Create and initialize the user's `L2Forwarder` via `Clone` if it does not already exist.
    2. Call `L2Forwarder.bridgeToL3(...)`
5. `L2Forwarder.bridgeToL3`
    1. Send the forwarder's entire token balance through the bridge to L3. The contract's entire ETH (or fee token) balance minus execution fee is sent as submission fee in order to forward all the extra ETH (or fee token) to L3.

### Retryable Failures and Race Conditions

The token bridge retryables to L2 and L3 should always succeed (if auto redeem fails, manual redeem should succeed).

The second step can fail for a number of reasons, mostly due to bad parameters:
* Not enough ETH is sent to cover L2 -> L3 retryable submission cost + relayer payment
* Incorrect `l2l3Router`, `token`, etc

If for some reason the second step cannot succeed, TOKEN and ETH or FEETOKEN will be stuck at the `L2Forwarder`. As long as the `owner` parameter of the forwarder is correct, the `owner` can call `rescue` on the forwarder to recover funds.

It is possible that two L1 -> L3 transfers use the same `L2Forwarder` if they have the same `L2ForwarderParams`. Because of this, it is also possible that the second and third step of one of the transfers are not executed. It's okay if there are two simultaneous transfers A and B, where steps A1-B1-A2-A3 are executed since TOKEN and ETH from both A1 and B1 are transferred during A2.

### Testing and Deploying

To test: 
```
forge test --fork-url $ETH_URL -vvv
```

To deploy:
```
./deploy.sh $L1_URL $L2_URL $OTHER_L2_URL ...
```
