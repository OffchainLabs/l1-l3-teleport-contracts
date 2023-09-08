import * as dotenv from "dotenv";
dotenv.config();

import { Wallet, ethers } from "ethers";
import { Beacon__factory, L2ForwarderFactory__factory, L2Forwarder__factory, Teleporter__factory } from "../../typechain-types";
import { create2 } from "./utils";
import { Config } from "../../config/config";

export type TeleporterDeployment = {
  teleporterAddress: string;
  forwarderFactoryAddress: string;
  forwarderImplAddress: string;
  beaconAddress: string;

  l2ChainIds: number[];
  l2Create2Salt: string;
}

async function deployL2Contracts(l1TeleporterAddress: string, beaconOwner: string, create2Salt: Uint8Array, l2Signer: Wallet) {
  const chainId = Number((await l2Signer.provider!.getNetwork()).chainId);
  
  const l2ForwarderImplAddress = await create2(
    new L2Forwarder__factory(),
    [],
    create2Salt,
    l2Signer
  );

  console.log(`L2Forwarder implementation @ ${l2ForwarderImplAddress} on chain ${chainId}`);

  const beaconAddress = await create2(
    new Beacon__factory(),
    [
      l2ForwarderImplAddress
    ],
    create2Salt,
    l2Signer
  );

  // transfer ownership of beacon
  const beacon = Beacon__factory.connect(beaconAddress, l2Signer);
  await (await beacon.transferOwnership(beaconOwner)).wait();

  console.log(`Beacon @ ${beaconAddress} on chain ${chainId}`);

  const l2ForwarderFactoryAddress = await create2(
    new L2ForwarderFactory__factory(),
    [
      beaconAddress,
      l1TeleporterAddress
    ],
    create2Salt,
    l2Signer
  );

  console.log(`L2ForwarderFactory @ ${l2ForwarderFactoryAddress} on chain ${chainId}`);
  
  return {
    chainId,
    l2ForwarderFactoryAddress,
    l2ForwarderImplAddress,
    beaconAddress,
  };
}

export async function deployTeleportContracts(config: Config): Promise<TeleporterDeployment> {
  const l1Signer = new ethers.Wallet(
    config.privateKey, 
    new ethers.JsonRpcProvider(config.l1RpcUrl)
  );

  // predict Teleporter address
  const predictedTeleporterAddress = ethers.getCreateAddress({
    from: l1Signer.address,
    nonce: await l1Signer.getNonce()
  });

  console.log('Deploying L2 contracts...');

  const create2Salt = ethers.randomBytes(32);

  const l2Deployments = await Promise.all(config.l2s.map((l2) => {
    const l2Signer = new ethers.Wallet(
      config.privateKey,
      new ethers.JsonRpcProvider(l2.rpcUrl)
    );
    return deployL2Contracts(predictedTeleporterAddress, l2.beaconOwner, create2Salt, l2Signer);
  }));

  // make sure all L2 deployments have the same addresses
  for (const l2Deployment of l2Deployments) {
    if (l2Deployment.l2ForwarderFactoryAddress !== l2Deployments[0].l2ForwarderFactoryAddress
      || l2Deployment.l2ForwarderImplAddress !== l2Deployments[0].l2ForwarderImplAddress
      || l2Deployment.beaconAddress !== l2Deployments[0].beaconAddress
    ) {
      throw new Error("L2 deployments have different addresses");
    }
  }

  // deploy the teleporter
  console.log('Deploying teleporter...');
  const teleporter = await new Teleporter__factory(l1Signer).deploy(
    l2Deployments[0].l2ForwarderFactoryAddress
  );
  await teleporter.waitForDeployment();
  const teleporterAddress = await teleporter.getAddress();
  if (teleporterAddress !== predictedTeleporterAddress) {
    throw new Error(`Teleporter address mismatch: predicted ${predictedTeleporterAddress}, got ${teleporterAddress}`);
  }
  console.log(`Teleporter deployed to ${teleporterAddress}`)

  return {
    teleporterAddress,
    forwarderFactoryAddress: l2Deployments[0].l2ForwarderFactoryAddress,
    forwarderImplAddress: l2Deployments[0].l2ForwarderImplAddress,
    beaconAddress: l2Deployments[0].beaconAddress,
    l2ChainIds: l2Deployments.map((l2) => l2.chainId),
    l2Create2Salt: ethers.hexlify(create2Salt),
  }
}
