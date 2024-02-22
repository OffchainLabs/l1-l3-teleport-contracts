#!/bin/bash

# check that at least 2 rpc arguments are provided
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 L1_URL L2_URL L2_URL ..."
    exit 1
fi

# read environment variables from .env file
source .env

# make sure PRIVATE_KEY, ETHERSCAN_API_KEY, and ARBISCAN_API_KEY are set
if [[ -z "$PRIVATE_KEY" || -z "$ETHERSCAN_API_KEY" || -z "$ARBISCAN_API_KEY" ]]; then
    echo "Please set PRIVATE_KEY, ETHERSCAN_API_KEY, and ARBISCAN_API_KEY environment variables"
    exit 1
fi

L1_URL=$1

mkdir -p script-deploy-data

echo "Predicting L1Teleporter address..."
DEPLOYER_ADDR=$(cast w address $PRIVATE_KEY)
export L1_TELEPORTER=$(cast compute-address $DEPLOYER_ADDR --rpc-url $L1_URL | awk '{print $3}')
export L1_CHAIN_ID=$(cast chain-id --rpc-url $L1_URL)

echo "L1 Teleporter address: $L1_TELEPORTER"

# run L2 script without broadcasting once to predict L1 and L2 contract addresses
echo "Predicting L2 contract addresses..."
forge script script/0_DeployL2Contracts.s.sol --rpc-url $2

# for L1
echo "Deploying L1Teleporter..."
forge script script/1_DeployL1Teleporter.s.sol --rpc-url $L1_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY

# exit if deployment failed
if [ $? -ne 0 ]; then
    echo "L1Teleporter deployment failed"
    exit 1
fi

# for each L2
for (( i=2; i<=$#; i++ )); do
    CHAIN_ID=`cast chain-id --rpc-url ${!i}`
    echo "Deploying L2 Contracts to $CHAIN_ID..."
    forge script script/0_DeployL2Contracts.s.sol --rpc-url ${!i} --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY
done