import { AddressLike, Wallet, ethers } from "ethers";
import { ERC20, Teleporter } from "../../typechain-types";
import { Config } from "../../config/config";

export async function teleport(teleporter: Teleporter, token: ERC20, l2: Config["l2s"][0], l2l3Router: AddressLike, l1Signer: Wallet) {
  const gasParams = {
    l2GasPrice: ethers.parseUnits("0.1", "gwei"),
    l3GasPrice: ethers.parseUnits("0.1", "gwei"),
    l2ForwarderFactoryGasLimit: 1_000_000,
    l1l2TokenBridgeGasLimit: 1_000_000,
    l2l3TokenBridgeGasLimit: 1_000_000,
    l1l2TokenBridgeRetryableSize: 1000, // bytes
    l2l3TokenBridgeRetryableSize: 1000, // bytes
  };
  const gasResults = await teleporter.calculateRetryableGasResults(l2.inbox, (await l1Signer.provider!.getFeeData()).gasPrice!, gasParams);

  const teleportTx = await teleporter.teleport(
    await token.getAddress(),
    l1Signer.address, // todo: change to a rando
    ethers.parseEther("100"),
    l2.router,
    l2l3Router,
    gasParams,
    {
      value: gasResults.total
    }
  );

  await teleportTx.wait();

  return teleportTx;
}