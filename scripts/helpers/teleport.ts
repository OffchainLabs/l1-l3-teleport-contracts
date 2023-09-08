import { AddressLike, Wallet, ethers } from "ethers";
import { ERC20, L1GatewayRouter__factory, Teleporter } from "../../typechain-types";

export async function teleport(teleporter: Teleporter, token: ERC20, l1l2Router: AddressLike, l2l3Router: AddressLike, l1Signer: Wallet) {
  const inbox = await L1GatewayRouter__factory.connect(l1l2Router.toString(), l1Signer).inbox();

  const gasParams = {
    l2GasPrice: ethers.parseUnits("0.1", "gwei"),
    l3GasPrice: ethers.parseUnits("0.1", "gwei"),
    l2ForwarderFactoryGasLimit: 1_000_000,
    l1l2TokenBridgeGasLimit: 1_000_000,
    l2l3TokenBridgeGasLimit: 1_000_000,
    l1l2TokenBridgeRetryableSize: 1000, // bytes
    l2l3TokenBridgeRetryableSize: 1000, // bytes
  };

  const gasResults = await teleporter.calculateRetryableGasCosts(inbox, (await l1Signer.provider!.getFeeData()).gasPrice!, gasParams);

  const teleportTx = await teleporter.teleport(
    await token.getAddress(),
    l1l2Router,
    l2l3Router,
    l1Signer.address,
    ethers.parseEther("100"),
    gasParams,
    {
      value: gasResults.total
    }
  );

  await teleportTx.wait();

  return teleportTx;
}