import { L1TransactionReceipt } from "@arbitrum/sdk";
// have to import ethers from the node_modules of the sdk because the ethers version is different
import { ethers } from "@arbitrum/sdk/node_modules/ethers";

export async function getL1ToL2Messages(txHash: string, l1RpcUrl: string, l2RpcUrl: string) {
  const l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);
  const l2Provider = new ethers.providers.JsonRpcProvider(l2RpcUrl);

  const receipt = await l1Provider.getTransactionReceipt(txHash);
  const l1Receipt = new L1TransactionReceipt(receipt);

  return l1Receipt.getL1ToL2Messages(l2Provider);
}