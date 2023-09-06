export type Config = {
  l1RpcUrl: string;
  l2s: {
    rpcUrl: string;
    inbox: string;
    router: string;
    upExec: string;
  }[];
  privateKey: string;
}