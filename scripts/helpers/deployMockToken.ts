import { Wallet } from "ethers";
import { MockToken__factory } from "../../typechain";

export async function deployMockToken(name: string, symbol: string, initialSupply: bigint, signer: Wallet) {
  const mockToken = await new MockToken__factory(signer).deploy(
    name,
    symbol,
    initialSupply,
    signer.address
  );
  await mockToken.deployed();

  return mockToken;
}