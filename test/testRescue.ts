import * as dotenv from "dotenv";
dotenv.config();

import { deployTeleportContracts } from "../scripts/helpers/deployTeleportContracts";
import config from "../config/goerli";
import { deployMockToken } from "../scripts/helpers/deployMockToken";
import { FunctionFragment, ethers } from "ethers";
import { IERC20__factory, IInbox__factory, L1GatewayRouter__factory, L2ForwarderFactory__factory, L2Forwarder__factory, Teleporter__factory } from "../typechain-types";
import { getEnv } from "../scripts/helpers/utils";
import { teleport } from "../scripts/helpers/teleport";

import { L1ToL2MessageStatus } from "@arbitrum/sdk";
import { getL1ToL2Messages } from "../scripts/helpers/sdkHelpers";

function getTestConfig() {
  return {
    l1l2Router: getEnv("ARB_GOERLI_ROUTER"),
    l2l3Router: getEnv("L3_ROUTER"),
    l3RpcUrl: getEnv("L3_URL"),
  }
}

// start a teleportation that will fail on the second leg due to an incorrect l2l3Router
// wait for the retryable to fail auto redeem
// create an L2Forwarder
// call L2Forwarder.rescue from L1 passing 3 calls:
// 1. cancel the retryable
// 2. transfer the tokens to a random address
// 3. transfer the value to a random address
async function main() {
  const testConfig = getTestConfig();

  const deployment = await deployTeleportContracts(config);
  const l1Signer = new ethers.Wallet(
    config.privateKey,
    new ethers.JsonRpcProvider(config.l1RpcUrl)
  );
  const l2Signer = new ethers.Wallet(
    config.privateKey,
    new ethers.JsonRpcProvider(config.l2s[0].rpcUrl)
  );

  const teleporter = Teleporter__factory.connect(deployment.teleporterAddress, l1Signer);

  console.log("deploying mock token...");
  const mockToken = await deployMockToken("MOCK", "MOCK", ethers.parseEther("100"), l1Signer);

  // approve teleporter to spend mockToken
  console.log("approving teleporter to spend mock token...");
  await (await mockToken.approve(deployment.teleporterAddress, ethers.parseEther("100"))).wait();

  // teleport
  console.log("teleporting...");
  const teleportTx = await teleport(
    teleporter,
    mockToken,
    testConfig.l1l2Router,
    "0x000000000000000000000000000000000000dead", // bad l2l3Router, second leg retryable will fail
    l1Signer
  );

  const teleportReceipt = (await teleportTx.wait())!;

  const messages = await getL1ToL2Messages(teleportReceipt.hash, config.l1RpcUrl, config.l2s[0].rpcUrl);

  // find the message going to the factory
  const factoryMessage = messages.find((m) => m.messageData.destAddress.toLowerCase() === deployment.forwarderFactoryAddress.toLowerCase());

  if (!factoryMessage) {
    throw new Error("factory message not found");
  }

  // wait for the retryable to attempt auto redeem
  console.log("waiting for second leg retryable to fail auto redeem...");
  const messageRec = await factoryMessage.waitForStatus()
  const status = messageRec.status;

  if (status !== L1ToL2MessageStatus.FUNDS_DEPOSITED_ON_L2) {
    throw new Error('retryable auto redeem did not fail as expected');
  }

  // create L2Forwarder
  console.log("creating L2Forwarder...");
  const l2ForwarderFactory = L2ForwarderFactory__factory.connect(deployment.forwarderFactoryAddress, l2Signer);
  await (await l2ForwarderFactory.createL2Forwarder(l2Signer.address)).wait();
  const l2ForwarderAddress = await l2ForwarderFactory.l2ForwarderAddress(l2Signer.address);

  console.log(`L2Forwarder deployed at ${l2ForwarderAddress}`);

  // create retryable to rescue funds
  const tokenReceiver = ethers.hexlify(ethers.randomBytes(20));
  const valueReceiver = ethers.hexlify(ethers.randomBytes(20));

  const l2TokenAddress = await L1GatewayRouter__factory.connect(testConfig.l1l2Router, l1Signer).calculateL2TokenAddress(mockToken.getAddress());

  const totalRescueETH = 
    await l2Signer.provider!.getBalance(l2ForwarderAddress) 
    + ethers.toBigInt(factoryMessage.messageData.l2CallValue.toHexString());

  const calls = [
    {
      address: "0x000000000000000000000000000000000000006E",
      calldata: ethers.concat([FunctionFragment.from("cancel(bytes32)").selector, factoryMessage.retryableCreationId]),
      value: 0n
    },
    {
      address: l2TokenAddress,
      calldata: IERC20__factory.createInterface().encodeFunctionData("transfer", [tokenReceiver, ethers.parseEther("100")]),
      value: 0n
    },
    {
      address: valueReceiver,
      calldata: "0x",
      value: totalRescueETH
    }
  ];

  const calldata = L2Forwarder__factory.createInterface().encodeFunctionData("rescue", [
    calls.map((c) => c.address),
    calls.map((c) => c.value),
    calls.map((c) => c.calldata),
  ]);

  const inbox = IInbox__factory.connect(await L1GatewayRouter__factory.connect(testConfig.l1l2Router, l1Signer).inbox(), l1Signer);

  const gasPrice = ethers.parseUnits("0.1", "gwei");
  const gasLimit = 5_000_000n;
  const submissionFee = await inbox.calculateRetryableSubmissionFee(calldata.length, 0n) * 3n / 2n;

  console.log("sending rescue retryable...");
  const rescueTx = await inbox.createRetryableTicket(
    l2ForwarderAddress,
    0n,
    submissionFee,
    l1Signer.address,
    l1Signer.address,
    gasLimit,
    gasPrice,
    calldata,
    {
      value: gasLimit * gasPrice + submissionFee
    }
  );
  await rescueTx.wait();

  // monitor the ticket
  const rescueMessage = await getL1ToL2Messages(rescueTx.hash, config.l1RpcUrl, config.l2s[0].rpcUrl);

  const rescueStatus = (await rescueMessage[0].waitForStatus()).status;

  if (rescueStatus !== L1ToL2MessageStatus.REDEEMED) {
    throw new Error("rescue retryable failed");
  }

  console.log("rescue retryable succeeded");

  // make sure the retryable was cancelled
  if (await factoryMessage.status() !== L1ToL2MessageStatus.EXPIRED) {
    throw new Error("retryable was not cancelled");
  }

  // make sure the tokens were transferred
  const l2Token = IERC20__factory.connect(l2TokenAddress, l2Signer);
  if (await l2Token.balanceOf(tokenReceiver) !== ethers.parseEther("100")) {
    throw new Error("tokens were not transferred");
  }

  // make sure all the value was transferred
  if (await l2Signer.provider!.getBalance(valueReceiver) !== totalRescueETH) {
    throw new Error("value was not transferred");
  }
  if (await l2Signer.provider!.getBalance(l2ForwarderAddress) !== 0n) {
    throw new Error("forwarder has some ETH left over");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
