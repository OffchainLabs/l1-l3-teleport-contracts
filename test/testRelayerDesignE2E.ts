import * as dotenv from "dotenv";
dotenv.config();

import { AbiCoder, JsonRpcProvider, ethers } from "ethers";
import { IInbox__factory, L1GatewayRouter__factory, L2ForwarderFactoryWithRelayer__factory, MockToken__factory } from "../typechain-types";
import { getEnv } from "../scripts/helpers/utils";
import { getL1ToL2Messages } from "../scripts/helpers/sdkHelpers";
import { L1ToL2MessageStatus } from "@arbitrum/sdk";

// todo: put this in utils or something
function getTestConfig() {
  return {
    l1l2RouterAddress: getEnv("ARB_GOERLI_ROUTER"),
    l2l3RouterAddress: getEnv("L3_ROUTER"),
    l3RpcUrl: getEnv("L3_URL"),
  }
}

async function main() {
  const testConfig = getTestConfig();

  // deploy factory on L2
  const l1Signer = new ethers.Wallet(getEnv("PRIVATE_KEY"), new JsonRpcProvider(getEnv("GOERLI_URL")));
  const l2Signer = new ethers.Wallet(getEnv("PRIVATE_KEY"), new JsonRpcProvider(getEnv("ARB_GOERLI_URL")));

  // get l1l2Router
  const l1l2Router = L1GatewayRouter__factory.connect(testConfig.l1l2RouterAddress, l1Signer);

  // deploy factory on L2
  console.log("Deploying L2ForwarderFactoryWithRelayer...");
  const l2Factory = await new L2ForwarderFactoryWithRelayer__factory(l2Signer).deploy();
  await l2Factory.deploymentTransaction()!.wait();

  // deploy mock token on L1
  console.log("Deploying mock token...");
  const mockToken = await new MockToken__factory(l1Signer).deploy("MOCK", "MOCK", ethers.parseEther("100"), l1Signer.address);
  await mockToken.deploymentTransaction()!.wait();

  // get l2 token addr
  console.log("Getting L2 token address...");
  const l2TokenAddr = await l1l2Router.calculateL2TokenAddress(await mockToken.getAddress());

  // create params
  const params = {
    salt: ethers.randomBytes(32),
    owner: l2Signer.address,
    token: l2TokenAddr,
    l2l3Router: testConfig.l2l3RouterAddress,
    to: l1Signer.address,
    amount: ethers.parseEther("100"),
    gasLimit: 1_000_000,
    gasPrice: ethers.parseUnits("0.1", "gwei"),
    relayerPayment: 0n // not going to pay the relayer in this test
  };

  // calculate L2Forwarder address
  console.log("Calculating L2Forwarder address...");
  const l2ForwarderAddress = await l2Factory.l2ForwarderAddress(
    params.salt,
    params.owner,
    params.token,
    params.l2l3Router,
    params.to,
    params.amount,
    params.gasLimit,
    params.gasPrice,
    params.relayerPayment
  );

  // approve gateway
  console.log("Approving gateway...");
  const l1l2Gateway = await l1l2Router.defaultGateway();
  await (await mockToken.approve(l1l2Gateway, ethers.parseEther("100"))).wait();

  // send tokens through the bridge to L2Forwarder, with extra ETH
  console.log("Sending tokens through the bridge...");
  const bridgeSubmissionCost = await IInbox__factory.connect(await l1l2Router.inbox(), l1Signer).calculateRetryableSubmissionFee(1000n, 0n) * 3n / 2n;
  const bridgeParams = [
    await mockToken.getAddress(),
    l2ForwarderAddress,
    l2ForwarderAddress,
    ethers.parseEther("100"),
    1_000_000n,
    // ethers.parseUnits("0.1", "gwei"),
    (await l2Signer.provider!.getFeeData()).gasPrice! * 2n,
    new AbiCoder().encode(["uint256", "bytes"], [bridgeSubmissionCost, "0x"]),
    {
      value: ethers.parseEther("0.01") // placeholder, too lazy to calculate the exact amount right now
    }
  ] as const;
  console.log(bridgeParams);
  const l1l2BridgeTx = await l1l2Router.outboundTransferCustomRefund(...bridgeParams);

  const l1l2BridgeTxReceipt = (await l1l2BridgeTx.wait())!;

  console.log(`L1->L2 bridge tx: ${l1l2BridgeTx.hash}`);
  console.log(`Gas used: ${l1l2BridgeTxReceipt.gasUsed}, price: ${ethers.formatUnits(l1l2BridgeTxReceipt.gasPrice, "gwei")} gwei, total: ${ethers.formatEther(l1l2BridgeTxReceipt.fee)} ETH`);

  // wait for the retryable to redeem
  console.log("Waiting for retryable to redeem...");
  const message = (await getL1ToL2Messages(l1l2BridgeTx.hash, getEnv("GOERLI_URL"), getEnv("ARB_GOERLI_URL")))[0];

  const status = await message.waitForStatus();

  if (status.status !== L1ToL2MessageStatus.REDEEMED) {
    throw new Error(`Message not redeemed: ${status.status}`);
  }

  // now we relay
  console.log("Relaying...");
  const relayTx = await l2Factory.deployAndBridge(
    params.salt,
    params.owner,
    params.token,
    params.l2l3Router,
    params.to,
    params.amount,
    params.gasLimit,
    params.gasPrice,
    params.relayerPayment
  );

  const relayTxReceipt = (await relayTx.wait())!;
  
  console.log(`Relay tx: ${relayTx.hash}`);
  console.log(`Gas used: ${relayTxReceipt.gasUsed}, price: ${ethers.formatUnits(relayTxReceipt.gasPrice, "gwei")} gwei, total: ${ethers.formatEther(relayTxReceipt.fee)} ETH`);
}

main().catch(console.error);