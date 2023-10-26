# L1 -> L3 ERC20 Teleportation

Contracts enabling direct ERC20 bridging from L1 to L3.

### Summary

In short, there are 3 steps to an L1 -> L3 teleportation:
1. Send tokens from L1 to a personal `L2Forwarder` whose address depends on its parameters
2. Create the `L2Forwarder` if it doesn't already exist and start the third step
3. Send tokens and ETH from the `L2Forwarder` to the recipient on L3

### Deployment Procedure
1. Deploy `L2ForwarderContractsDeployer` using a generic CREATE2 factory such as `0x4e59b44847b379578588920cA78FbF26c0B4956C` on each L2. This will deploy the `L2ForwarderFactory` and `L2Forwarder` implementation. Use the same salt on each L2.
2. Deploy `L1Teleporter` to L1, passing the L2 factory and implementation addresses to the constructor.

### Teleportation Flow

There are two ways to bridge ERC20 tokens from L1 to L3. Through the L1 `L1Teleporter` contract, or using a relayer on L2.
Both routes work similarly, sending tokens to a precomputed personal `L2Forwarder` and creating/calling the `L2Forwarder` to send the tokens up to L3.

When using the `L1Teleporter`, 2 L1 -> L2 retryables will be created: one bridging tokens and one calling the forwarder.

When using an L2 relayer, the user calls the `L1GatewayRouter` directly to send tokens and ETH to the precomputed forwarder. The relayer then calls the forwarder and receives some ETH.

#### Example Using the `L1Teleporter`

1. User approves `L1Teleporter` to spend TOKEN
2. User calls `L1Teleporter.teleport`:
    1. Computes the personal `L2Forwarder` address
    2. Sends tokens over the bridge to the `L2Forwarder`. Send extra `msg.value` by overestimating submission cost.
    3. Creates a retryable to call `L2ForwarderFactory.callForwarder`
3. Retryable 1 is redeemed: tokens and ETH land in the `L2Forwarder` address (which may or may not be a contract yet)
4. Retryable 2 is redeemed: `L2ForwarderFactory.callForwarder`
    1. Create and initialize the user's `L2Forwarder` via `Clone` if it does not already exist.
    2. Call `L2Forwarder.bridgeToL3(...)`
5. `L2Forwarder.bridgeToL3`
    1. Send the forwarder's entire token balance through the bridge to L3. The contract's entire ETH balance minus execution fee is sent as submission fee in order to forward all the extra ETH to L3.

#### Example Using an L2 Relayer

1. User approves TOKEN's L1 Gateway
2. User computes `L2Forwarder` address off-chain
3. User calls the `L1GatewayRouter` to send tokens to the `L2Forwarder`. Extra ETH required to pay the relayer and submit/execute L2 -> L3 retryable are sent through an overestimated submission fee.
4. Once tokens and ETH land at the forwarder, a relayer calls `L2ForwarderFactory.callForwarder`, sending tokens up to L3 and receiving payment.

### Retryable Failures and Race Conditions

The first and third step retryables should always succeed (if auto redeem fails, manual redeem should succeed).

The second step can fail for a number of reasons, mostly due to bad parameters:
* Not enough ETH is sent to cover L2 -> L3 retryable submission cost + relayer payment
* Incorrect `l2l3Router`, `token`, etc

If for some reason the second step cannot succeed, TOKEN and ETH will be stuck at the `L2Forwarder`. As long as the `owner` parameter of the forwarder is correct, the `owner` can call `rescue` on the forwarder to recover TOKEN and ETH.

It is possible that two L1 -> L3 transfers use the same `L2Forwarder` if they have the same `L2ForwarderParams`. Because of this, it is also possible that the second and third step of one of the transfers are not executed. It's okay if there are two simultaneous transfers A and B, where steps A1-B1-A2-A3 are executed since TOKEN and ETH from both A1 and B1 are transferred during A2.

### Testing and Deploying

To test: 
```
forge test --fork-url $ETH_URL -vvv
```

To deploy:
```
mkdir script-deploy-data

# for all L2's
forge script script/0_DeployL2Contracts.s.sol --rpc-url $L2_URL --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY

# for L1
forge script script/1_DeployL1Teleporter.s.sol --rpc-url $ETH_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```
