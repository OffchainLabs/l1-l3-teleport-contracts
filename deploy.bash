#!/bin/bash

# check that at least 2 rpc arguments are provided
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 L1_URL L2_URL L2_URL ..."
    exit 1
fi

# read environment variables from .env file
source .env

# make sure PRIVATE_KEY is set
if [[ -z "$PRIVATE_KEY" ]]; then
    echo "Please set PRIVATE_KEY environment variable"
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
L1_ETHERSCAN_API_KEY_VAR="ETHERSCAN_API_KEY_$L1_CHAIN_ID"
L1_ETHERSCAN_API_KEY="${!L1_ETHERSCAN_API_KEY_VAR}"
if [[ -z "$L1_ETHERSCAN_API_KEY" ]]; then
    echo "Please set ETHERSCAN_API_KEY_$L1_CHAIN_ID environment variable."
    exit 1
fi
# if DRY_RUN_DEPLOY is not "1", then broadcast and verify the deployment
BROADCAST_ARGS=""
if [[ "$DRY_RUN_DEPLOY" != "1" ]]; then
    BROADCAST_ARGS="--broadcast --verify --etherscan-api-key $L1_ETHERSCAN_API_KEY"
fi
forge script script/1_DeployL1Teleporter.s.sol --rpc-url $L1_URL $BROADCAST_ARGS

# exit if deployment failed
if [ $? -ne 0 ]; then
    echo "L1Teleporter deployment failed"
    exit 1
fi

# for each L2
for (( i=2; i<=$#; i++ )); do
    CHAIN_ID=`cast chain-id --rpc-url ${!i}`
    echo "Deploying L2 Contracts to $CHAIN_ID..."
    API_KEY_VAR="ETHERSCAN_API_KEY_$CHAIN_ID"
    API_KEY="${!API_KEY_VAR}"
    if [[ -z "$API_KEY" ]]; then
        echo "Please set $API_KEY_VAR environment variable."
        exit 1
    fi
    # if DRY_RUN_DEPLOY is not "1", then broadcast and verify the deployment
    BROADCAST_ARGS=""
    if [[ "$DRY_RUN_DEPLOY" != "1" ]]; then
        BROADCAST_ARGS="--broadcast --verify --etherscan-api-key $API_KEY"
    fi
    forge script script/0_DeployL2Contracts.s.sol --rpc-url ${!i} $BROADCAST_ARGS
done