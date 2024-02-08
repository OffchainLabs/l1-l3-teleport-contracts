// we have a hardhat config so that the sdk can build and deploy our contracts

module.exports = {
  paths: {
    artifacts: 'build/contracts',
  },
  solidity: {
    version: "0.8.23",
    settings: {
      optimizer: {
        enabled: true,
        runs: 20000
      }
    }
  }
};
