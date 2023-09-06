import * as dotenv from "dotenv";
dotenv.config();

import { deployTeleportContracts } from "../scripts/helpers/deployTeleportContracts";
import config from "../config/goerli";
import { deployMockToken } from "../scripts/helpers/deployMockToken";
import { BytesLike, ethers } from "ethers";
import { Teleporter__factory } from "../typechain-types";
import { assertDefined } from "../scripts/helpers/utils";
import { teleport } from "../scripts/helpers/teleport";

import { addDefaultLocalNetwork, L1TransactionReceipt, L1ToL2MessageStatus } from '@arbitrum/sdk';

function getTestConfig() {
  return {
    l2l3Router: assertDefined(process.env.L3_ROUTER, "L3_ROUTER is undefined"),
  }
}

async function main() {
  const testConfig = getTestConfig();

  const deployment = await deployTeleportContracts(config, true);
  const l1Signer = new ethers.Wallet(
    config.privateKey,
    new ethers.JsonRpcProvider(config.l1RpcUrl)
  );

  const teleporter = Teleporter__factory.connect(deployment.teleporterAddress, l1Signer);

  const mockToken = await deployMockToken("MOCK", "MOCK", ethers.parseEther("100"), l1Signer);

  // initiate teleport

  // approve teleporter to spend mockToken
  await (await mockToken.approve(deployment.teleporterAddress, ethers.parseEther("100"))).wait();

  const teleportTx = await teleport(
    teleporter,
    mockToken,
    config.l2s[0],
    testConfig.l2l3Router,
    l1Signer
  );

  console.log(`Teleport tx: ${teleportTx.hash}`);

  console.log(`Waiting for retryables...`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
