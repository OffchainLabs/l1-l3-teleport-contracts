import { Wallet } from "ethers";
import { MockToken__factory } from "../../typechain-types";

export async function deployMockToken(name: string, symbol: string, initialSupply: bigint, signer: Wallet) {
  const mockToken = await new MockToken__factory(signer).deploy(
    name,
    symbol,
    initialSupply,
    signer.address
  );
  await mockToken.waitForDeployment();

  return mockToken;
}