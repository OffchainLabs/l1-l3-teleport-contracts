import { getEnv } from "../scripts/helpers/utils";
import { Config } from "./config";

const config: Config = {
  l1RpcUrl: getEnv("GOERLI_URL"),
  l2s: [
    {
      rpcUrl: getEnv("ARB_GOERLI_URL"),
      inbox: getEnv("ARB_GOERLI_INBOX"),
      router: getEnv("ARB_GOERLI_ROUTER"),
      upExec: getEnv("ARB_GOERLI_EXECUTOR")
    }
  ],
  privateKey: getEnv("PRIVATE_KEY"),
};

export default config;