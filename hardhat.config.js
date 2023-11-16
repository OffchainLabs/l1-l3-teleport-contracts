// we have a hardhat config so that the sdk can build and deploy our contracts

module.exports = {
  paths: {
    artifacts: 'build/contracts',
  },
  solidity: {
    version: "0.8.13",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  }
};
