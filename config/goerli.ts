import { assertDefined } from "../scripts/helpers/utils";
import { Config } from "./config";

const config: Config = {
  l1RpcUrl: assertDefined(process.env.GOERLI_URL, "GOERLI_URL is undefined"),
  l2s: [
    {
      rpcUrl: assertDefined(process.env.ARB_GOERLI_URL, "ARB_GOERLI_URL is undefined"),
      inbox: assertDefined(process.env.ARB_GOERLI_INBOX, "ARB_GOERLI_INBOX is undefined"),
      router: assertDefined(process.env.ARB_GOERLI_ROUTER, "ARB_GOERLI_ROUTER is undefined"),
      upExec: "0x0000000000000000000000000000000000000000" // todo
    }
  ],
  privateKey: assertDefined(process.env.PRIVATE_KEY, "PRIVATE_KEY is undefined"),
};

export default config;