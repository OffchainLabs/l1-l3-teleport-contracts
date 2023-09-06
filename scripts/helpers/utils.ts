import { ContractFactory, Wallet, ethers } from "ethers";

const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

export function assertDefined<T>(x: T | undefined, msg = "value is undefined"): T {
  if (x === undefined) {
    throw new Error(msg);
  }
  return x;
}

export async function create2<T extends ContractFactory>(
  factory: T,
  constructorArgs: Parameters<T["getDeployTransaction"]>,
  salt: Uint8Array,
  signer: Wallet
): Promise<string> {
  const initCode = (await factory.getDeployTransaction(...constructorArgs)).data;

  const payload = ethers.concat([salt, initCode]);

  const txRequest = {
    to: CREATE2_FACTORY,
    data: payload,
    value: 0n,
  };

  const deployTx = await signer.sendTransaction(txRequest);
  await deployTx.wait();

  const address = ethers.getCreate2Address(CREATE2_FACTORY, salt, ethers.keccak256(initCode));

  return address;
}

export async function stopwatch<T>(promise: Promise<T>, msg = ""): Promise<T> {
  let elapsedSeconds = 0;
  const intervalId = setInterval(() => {
    elapsedSeconds++;
    const minutes = Math.floor(elapsedSeconds / 60);
    const seconds = elapsedSeconds % 60;
    const formattedTime = `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
    process.stdout.write(`\r${msg === "" ? "" : msg.trim() + " "}${formattedTime}...`);
  }, 1000);

  try {
    const result = await promise;
    clearInterval(intervalId);
    return result;
  } catch (err) {
    clearInterval(intervalId);
    throw err;
  }
}