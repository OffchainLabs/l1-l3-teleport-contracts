export type Config = {
  l1RpcUrl: string;
  l2s: {
    rpcUrl: string;
    beaconOwner: string;
  }[];
  privateKey: string;
}