import * as dotenv from "dotenv";
dotenv.config();

import { ethers } from "ethers";
import fs from "fs";
import { TeleporterDeploy } from "./deployTeleport";
import { ERC20__factory, Teleporter__factory } from "../typechain-types";

function assertDefined<T>(x: T | undefined): T {
  if (x === undefined) {
    throw new Error("value is undefined");
  }
  return x;
}

const deployment = JSON.parse(fs.readFileSync("./deployments/goerli.json", "utf8")) as TeleporterDeploy;
const l1TokenAddress = "0xdb7Bb8253d96803c089cb15f2df7226144c97B03";
const l2l3RouterAddress = "0xCb0Fe28c36a60Cf6254f4dd74c13B0fe98FFE5Db";

async function main() {
  const L1_URL = assertDefined(process.env.L1_URL);
  const PRIVATE_KEY = assertDefined(process.env.PRIVATE_KEY);

  const l1Signer = new ethers.Wallet(
    PRIVATE_KEY, 
    new ethers.JsonRpcProvider(L1_URL)
  );

  console.log("starting...");

  const teleporter = Teleporter__factory.connect(deployment.teleporter, l1Signer);

  const gasParams = {
    l2GasPrice: ethers.parseUnits("0.1", "gwei"),
    l3GasPrice: ethers.parseUnits("0.1", "gwei"),
    l2ReceiverFactoryGasLimit: 1_000_000,
    l1l2TokenBridgeGasLimit: 1_000_000,
    l2l3TokenBridgeGasLimit: 1_000_000,
    l1l2TokenBridgeRetryableSize: 1000, // bytes
    l2l3TokenBridgeRetryableSize: 1000, // bytes
  };
  const gasPrice = (await l1Signer.provider!.getFeeData()).gasPrice!;
  const gasResults = await teleporter.calculateRetryableGasResults(gasPrice, gasParams);

  const l1Token = ERC20__factory.connect(l1TokenAddress, l1Signer);
  const approveTx = await l1Token.approve(deployment.teleporter, ethers.MaxUint256);
  await approveTx.wait();

  console.log("approved teleporter to spend token");

  const teleportTx = await teleporter.teleport(
    l2l3RouterAddress,
    l1TokenAddress,
    l1Signer.address,
    ethers.parseEther("0.01"),
    gasParams,
    {
      value: gasResults.total,
    }
  );

  await teleportTx.wait();

  console.log('teleported');
  console.log(teleportTx.hash)

}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
