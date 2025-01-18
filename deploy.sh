if [ $# != 1 ]
then
    echo "USAGE: $0 CHAIN_CODE[TBSC_BNB|ARBITRUM_ETH|BSC_BNB|ETH]"
    exit 1
fi

CHAIN_CODE=$1

mkdir -p ~/.foundry/keystores
account_num=`cast wallet list | wc -l`
if [ $account_num -eq 0 ]
then
    echo "creating local wallet..."
    cast wallet new ~/.foundry/keystores
    if [ $? -ne 0 ]
    then
        echo "failed to create wallet"
        exit 1
    fi
fi

account="ssi-deployer"
address=`cast wallet address --account ${account}`
echo "deploy using wallet ${address}"
source .deploy.env
RPC_URL=$(eval echo '$'${CHAIN_CODE}_RPC_URL)
ETHERSCAN_URL=$(eval echo '$'${CHAIN_CODE}_ETHERSCAN_URL)
ETHERSCAN_APIKEY=$(eval echo '$'${CHAIN_CODE}_ETHERSCAN_APIKEY)
export OWNER=$(eval echo '$'${CHAIN_CODE}_OWNER)
export VAULT=$(eval echo '$'${CHAIN_CODE}_VAULT)
export ORDER_SIGNER=$(eval echo '$'${CHAIN_CODE}_ORDER_SIGNER)
export REDEEM_TOKEN=$(eval echo '$'${CHAIN_CODE}_REDEEM_TOKEN)
export CHAIN_CODE=${CHAIN_CODE}
forge script script/Deployer.s.sol --legacy --via-ir --account ${account} --rpc-url $RPC_URL \
    --verifier-url $ETHERSCAN_URL --etherscan-api-key $ETHERSCAN_APIKEY --broadcast --verify -vvv