import * as dotenv from "dotenv";
dotenv.config();
import { promises as fs } from "fs";
import { deployTeleportContracts } from "./helpers/deployTeleportContracts";
import config from "../config/goerli";

async function main() {
  const deployment = await deployTeleportContracts(config, true);
  
  await fs.writeFile(
    './deployments/goerli.json',
    JSON.stringify(deployment, null, 2),
  )
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
