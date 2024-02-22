# L1 -> L3 ERC20 Teleportation

Contracts enabling direct L1 to L3 ERC20 bridging. Teleportations are ERC20 deposits from L1 through any Arbitrum L2 to any Arbitrum L3 on the L2.

## Summary

There are 3 steps to an L1 -> L3 teleportation:
1. Send funds from L1 to a personal `L2Forwarder` whose address depends on its parameters
2. Create the `L2Forwarder` if it doesn't already exist and start the third step
3. Send tokens and ETH from the `L2Forwarder` to the recipient on L3

For more information see [info.md](./docs/info.md)

## Testing and Deploying

To test: 
```
forge test
```

To deploy:
```
./deploy.sh $L1_URL $L2_URL $OTHER_L2_URL ...
```
