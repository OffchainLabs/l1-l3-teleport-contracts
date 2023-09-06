import * as dotenv from "dotenv";
dotenv.config();

import { Transaction, Wallet, ethers } from "ethers";
import { Beacon, Beacon__factory, L2Receiver, L2ReceiverFactory, L2ReceiverFactory__factory, L2Receiver__factory, Teleporter, Teleporter__factory } from "../../typechain-types";
import { assertDefined, create2 } from "./utils";
import { Config } from "../../config/config";

export type TeleporterDeployment = {
  teleporterAddress: string;
  receiverFactoryAddress: string;
  receiverImplAddress: string;
  beaconAddress: string;

  l2ChainIds: number[];
}

export async function deployTeleportContracts(config: Config, showLogs = false): Promise<TeleporterDeployment> {
  function log(...args: any) {
    if (showLogs) {
      console.log(...args);
    }
  }

  const l1Signer = new ethers.Wallet(
    config.privateKey, 
    new ethers.JsonRpcProvider(config.l1RpcUrl)
  );

  // predict Teleporter address
  const predictedTeleporterAddress = ethers.getCreateAddress({
    from: l1Signer.address,
    nonce: await l1Signer.getNonce()
  });

  log('Deploying L2 contracts...');

  const create2Salt = ethers.randomBytes(32);

  const l2Deployments = await Promise.all(config.l2s.map(async (l2) => {
    const l2Signer = new ethers.Wallet(
      config.privateKey,
      new ethers.JsonRpcProvider(l2.rpcUrl)
    );

    const chainId = Number((await l2Signer.provider!.getNetwork()).chainId);
    
    const l2ReceiverImplAddress = await create2(
      new L2Receiver__factory(),
      [],
      create2Salt,
      l2Signer
    );

    log(`L2Receiver implementation @ ${l2ReceiverImplAddress} on chain ${chainId}`);

    const beaconAddress = await create2(
      new Beacon__factory(),
      [
        l2ReceiverImplAddress,
        l2.upExec
      ],
      create2Salt,
      l2Signer
    );

    log(`Beacon @ ${beaconAddress} on chain ${chainId}`);

    const l2ReceiverFactoryAddress = await create2(
      new L2ReceiverFactory__factory(),
      [
        beaconAddress,
        predictedTeleporterAddress
      ],
      create2Salt,
      l2Signer
    );

    log(`L2ReceiverFactory @ ${l2ReceiverFactoryAddress} on chain ${chainId}`);
    
    return {
      chainId,
      l2ReceiverFactoryAddress,
      l2ReceiverImplAddress,
      beaconAddress,
    };
  }));

  // make sure all L2 deployments have the same addresses
  for (const l2Deployment of l2Deployments) {
    if (l2Deployment.l2ReceiverFactoryAddress !== l2Deployments[0].l2ReceiverFactoryAddress
      || l2Deployment.l2ReceiverImplAddress !== l2Deployments[0].l2ReceiverImplAddress
      || l2Deployment.beaconAddress !== l2Deployments[0].beaconAddress
    ) {
      throw new Error("L2 deployments have different addresses");
    }
  }

  // deploy the teleporter
  log('Deploying teleporter...');
  const teleporter = await new Teleporter__factory(l1Signer).deploy(
    l2Deployments[0].l2ReceiverFactoryAddress
  );
  await teleporter.waitForDeployment();
  const teleporterAddress = await teleporter.getAddress();
  log(`Teleporter deployed to ${teleporterAddress}`)

  return {
    teleporterAddress,
    receiverFactoryAddress: l2Deployments[0].l2ReceiverFactoryAddress,
    receiverImplAddress: l2Deployments[0].l2ReceiverImplAddress,
    beaconAddress: l2Deployments[0].beaconAddress,
    l2ChainIds: l2Deployments.map((l2) => l2.chainId)
  }
}
