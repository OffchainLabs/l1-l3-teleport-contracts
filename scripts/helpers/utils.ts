import { ContractFactory, Wallet, ethers } from "ethers";
import { promises as fs } from "fs";
import { TeleporterDeployment } from "./deployTeleportContracts";

// https://github.com/Arachnid/deterministic-deployment-proxy
const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

export function assertDefined<T>(x: T | undefined, msg = "value is undefined"): T {
  if (x === undefined) {
    throw new Error(msg);
  }
  return x;
}

export function getEnv(name: string, msg = `${name} is undefined`): string {
  return assertDefined(process.env[name], msg);
}

export async function create2<T extends ContractFactory>(
  factory: T,
  constructorArgs: Parameters<T["getDeployTransaction"]>,
  salt: Uint8Array,
  signer: Wallet
) {
  const initCode = factory.getDeployTransaction(...constructorArgs).data!;

  const payload = ethers.utils.concat([salt, initCode]);

  const txRequest = {
    to: CREATE2_FACTORY,
    data: payload,
    value: 0n,
  };

  const deployTx = await signer.sendTransaction(txRequest);
  await deployTx.wait();

  const address = ethers.utils.getCreate2Address(CREATE2_FACTORY, salt, ethers.utils.keccak256(initCode));

  return {
    address,
    deployTx
  };
}

export async function getDeployment(network: 'goerli'): Promise<TeleporterDeployment> {
  return fs.readFile(`./deployments/${network}.json`, "utf8").then(JSON.parse);
}