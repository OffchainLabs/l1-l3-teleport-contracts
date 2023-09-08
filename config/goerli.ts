import { getEnv } from "../scripts/helpers/utils";
import { Config } from "./config";

const config: Config = {
  l1RpcUrl: getEnv("GOERLI_URL"),
  l2s: [
    {
      rpcUrl: getEnv("ARB_GOERLI_URL"),
      beaconOwner: getEnv("ARB_GOERLI_BEACON_OWNER")
    }
  ],
  privateKey: getEnv("PRIVATE_KEY"),
};

export default config;