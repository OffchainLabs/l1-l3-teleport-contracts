import * as dotenv from "dotenv";
dotenv.config();

import { AbiCoder, Wallet, ethers } from "ethers";
import { Beacon__factory, L2ContractsDeployer__factory, L2ForwarderFactory__factory, L2Forwarder__factory, Teleporter__factory } from "../../typechain-types";
import { create2 } from "./utils";
import { Config } from "../../config/config";

export type TeleporterDeployment = {
  teleporterAddress: string;
  forwarderFactoryAddress: string;
  forwarderImplAddress: string;

  l2ChainIds: number[];
  l2Create2Salt: string;
}

async function deployL2Contracts(create2Salt: Uint8Array, l2Signer: Wallet) {
  const deployment = await create2(
    new L2ContractsDeployer__factory(), [], create2Salt, l2Signer
  );


  // get the event
  const receipt = (await deployment.deployTx.wait())!;

  const logData = receipt.logs[receipt.logs.length - 1].data;

  console.log(receipt.logs)

  const [l2ForwarderImplAddress, l2ForwarderFactoryAddress]  = new AbiCoder().decode(
    ['address', 'address'],
    logData
  );

  const chainId = Number((await l2Signer.provider!.getNetwork()).chainId);

  console.log(`L2Forwarder implementation @ ${l2ForwarderImplAddress} on chain ${chainId}`);
  console.log(`L2ForwarderFactory @ ${l2ForwarderFactoryAddress} on chain ${chainId}`);

  return {
    chainId,
    l2ForwarderFactoryAddress,
    l2ForwarderImplAddress,
  };
}

export async function deployTeleportContracts(config: Config): Promise<TeleporterDeployment> {
  const l1Signer = new ethers.Wallet(
    config.privateKey, 
    new ethers.JsonRpcProvider(config.l1RpcUrl)
  );


  console.log('Deploying L2 contracts...');

  const create2Salt = ethers.randomBytes(32);

  const l2Deployments = await Promise.all(config.l2s.map((l2) => {
    const l2Signer = new ethers.Wallet(
      config.privateKey,
      new ethers.JsonRpcProvider(l2.rpcUrl)
    );
    return deployL2Contracts(create2Salt, l2Signer);
  }));

  // make sure all L2 deployments have the same addresses
  for (const l2Deployment of l2Deployments) {
    if (l2Deployment.l2ForwarderFactoryAddress !== l2Deployments[0].l2ForwarderFactoryAddress
      || l2Deployment.l2ForwarderImplAddress !== l2Deployments[0].l2ForwarderImplAddress
    ) {
      throw new Error("L2 deployments have different addresses");
    }
  }

  // deploy the teleporter
  console.log('Deploying teleporter...');
  const teleporter = await new Teleporter__factory(l1Signer).deploy(
    l2Deployments[0].l2ForwarderFactoryAddress,
    l2Deployments[0].l2ForwarderImplAddress
  );
  await teleporter.waitForDeployment();
  const teleporterAddress = await teleporter.getAddress();
  console.log(`Teleporter deployed to ${teleporterAddress}`)

  return {
    teleporterAddress,
    forwarderFactoryAddress: l2Deployments[0].l2ForwarderFactoryAddress,
    forwarderImplAddress: l2Deployments[0].l2ForwarderImplAddress,
    l2ChainIds: l2Deployments.map((l2) => l2.chainId),
    l2Create2Salt: ethers.hexlify(create2Salt),
  }
}
