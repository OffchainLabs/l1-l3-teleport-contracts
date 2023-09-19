import * as dotenv from "dotenv";
dotenv.config();

import { deployTeleportContracts } from "../scripts/helpers/deployTeleportContracts";
import config from "../config/goerli";
import { deployMockToken } from "../scripts/helpers/deployMockToken";
import { ethers } from "ethers";
import { ERC20__factory, IERC20__factory, L1GatewayRouter__factory, Teleporter__factory } from "../typechain-types";
import { getDeployment, getEnv } from "../scripts/helpers/utils";
import { teleport } from "../scripts/helpers/teleport";

function getTestConfig() {
  return {
    l1l2Router: getEnv("ARB_GOERLI_ROUTER"),
    l2l3Router: getEnv("L3_ROUTER"),
    l3RpcUrl: getEnv("L3_URL"),
  }
}

async function main() {
  const testConfig = getTestConfig();

  // const deployment = await deployTeleportContracts(config);
  const deployment = await getDeployment('goerli');
  const l1Signer = new ethers.Wallet(
    config.privateKey,
    new ethers.JsonRpcProvider(config.l1RpcUrl)
  );
  const l2Provider = new ethers.JsonRpcProvider(config.l2s[0].rpcUrl);
  const l3Provider = new ethers.JsonRpcProvider(testConfig.l3RpcUrl);

  const teleporter = Teleporter__factory.connect(deployment.teleporterAddress, l1Signer);

  console.log("Deploying mock token...");
  const mockToken = await deployMockToken("MOCK", "MOCK", ethers.parseEther("1000"), l1Signer);
  console.log(`Mock token deployed at ${await mockToken.getAddress()}`);
  
  // approve teleporter to spend mockToken
  await (await mockToken.approve(deployment.teleporterAddress, ethers.parseEther("1000"))).wait();

  const teleportTx = await teleport(
    teleporter,
    mockToken,
    testConfig.l1l2Router,
    testConfig.l2l3Router,
    ethers.parseEther("1000"),
    l1Signer
  );

  const teleportTxReceipt = (await teleportTx.wait())!;

  console.log(`Teleport tx: ${teleportTx.hash}`);
  console.log(`Teleport tx gas used: ${teleportTxReceipt.gasUsed}`);

  // get L3 token address
  const l2TokenAddr = await L1GatewayRouter__factory.connect(testConfig.l1l2Router, l1Signer).calculateL2TokenAddress(await mockToken.getAddress());
  const l3TokenAddr = await L1GatewayRouter__factory.connect(testConfig.l2l3Router, l2Provider).calculateL2TokenAddress(l2TokenAddr);

  // create a promise that polls the L3 token balance
  console.log("Waiting for tokens on L3...");
  const l3Token = ERC20__factory.connect(l3TokenAddr, l3Provider);
  await new Promise((resolve) => {
    const interval = setInterval(async () => {
      try {
        const balance = await l3Token.balanceOf(await l1Signer.getAddress());
        if (balance > 0n) {
          clearInterval(interval);
          resolve(balance);
        }
      }
      catch (e) {
        // fetching balance failed, ignore
      }
    }, 15000);
  });
  console.log("Tokens found on L3!");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
