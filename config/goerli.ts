import { getEnv } from "../scripts/helpers/utils";
import { Config } from "./config";

const config: Config = {
  l1RpcUrl: getEnv("GOERLI_URL"),
  l2RpcUrls: [
    getEnv("ARB_GOERLI_URL")
  ],
  privateKey: getEnv("PRIVATE_KEY"),
};

export default config;