import * as dotenv from "dotenv";
dotenv.config();

import { ethers } from "ethers";
import { promises as fs } from "fs";
import { Beacon__factory, L2ReceiverFactory__factory, L2Receiver__factory, Teleporter__factory } from "../typechain-types";

function assertDefined<T>(x: T | undefined): T {
  if (x === undefined) {
    throw new Error("value is undefined");
  }
  return x;
}

export type TeleporterDeploy = {
  teleporter: string;
  receiverFactory: string;
  receiverImpl: string;
  beacon: string;
};

async function main() {
  const ETH_URL = assertDefined(process.env.ETH_URL);
  const ARB_URL = assertDefined(process.env.ARB_URL);
  const ETH_INBOX = assertDefined(process.env.ETH_INBOX);
  const ETH_ROUTER = assertDefined(process.env.ETH_ROUTER);
  const PRIVATE_KEY = assertDefined(process.env.PRIVATE_KEY);

  const ethSigner = new ethers.Wallet(
    PRIVATE_KEY, 
    new ethers.JsonRpcProvider(ETH_URL)
  );
  const arbSigner = new ethers.Wallet(
    PRIVATE_KEY,
    new ethers.JsonRpcProvider(ARB_URL)
  );

  console.log("starting...");
  
  const teleporter = await new Teleporter__factory(ethSigner).deploy();
  await teleporter.deploymentTransaction()!.wait();
  const teleporterAddress = await teleporter.getAddress();

  console.log(`Teleporter deployed to ${teleporterAddress}`);

  const l2ReceiverFactory = await new L2ReceiverFactory__factory(arbSigner).deploy();
  await l2ReceiverFactory.deploymentTransaction()!.wait();
  const l2ReceiverFactoryAddress = await l2ReceiverFactory.getAddress();

  console.log(`L2ReceiverFactory deployed to ${l2ReceiverFactoryAddress}`);

  const l2ReceiverImpl = await new L2Receiver__factory(arbSigner).deploy();
  await l2ReceiverImpl.deploymentTransaction()!.wait();
  const l2ReceiverImplAddress = await l2ReceiverImpl.getAddress();

  console.log(`L2ReceiverImpl deployed to ${l2ReceiverImplAddress}`);

  const beacon = await new Beacon__factory(arbSigner).deploy(l2ReceiverImplAddress);
  await beacon.deploymentTransaction()!.wait();
  const beaconAddress = await beacon.getAddress();

  console.log(`Beacon deployed to ${beaconAddress}`);

  const teleporterInitTx = await teleporter.initialize(
    l2ReceiverFactoryAddress,
    ETH_ROUTER,
    ETH_INBOX
  );
  await teleporterInitTx.wait();

  console.log("Teleporter initialized");

  const l2ReceiverFactoryInitTx = await l2ReceiverFactory.initialize(
    teleporterAddress,
    beaconAddress
  )
  await l2ReceiverFactoryInitTx.wait();
  console.log("L2ReceiverFactory initialized");
  
  await fs.writeFile(
    './deployments/goerli.json',
    JSON.stringify({
      teleporter: teleporterAddress,
      receiverFactory: l2ReceiverFactoryAddress,
      receiverImpl: l2ReceiverImplAddress,
      beacon: beaconAddress
    } satisfies TeleporterDeploy, null, 2),
  )
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
