#!/bin/bash
set -e

if [ $# != 1 ]; then
    echo "USAGE: $0 ACCOUNT_NAME"
    echo "  ACCOUNT_NAME: foundry keystore account name"
    exit 1
fi

account=$1

address=$(cast wallet address --account "${account}")
echo "deploy using wallet ${address}"

set -a
source .voting.env
set +a

forge script script/RewardedVotingDeployer.s.sol --legacy --via-ir --account "${account}" --rpc-url "${RPC_URL}" \
    --verifier blockscout --verifier-url "${BLOCKSCOUT_URL}" --broadcast --verify -vvv
