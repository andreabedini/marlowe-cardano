#!/usr/bin/env bash

echo "Set CARDANO_NODE_SOCKET_PATH and MAGIC to point to the network to be tested."
echo "Set TREASURY to the folder for key files."
echo

if [[ -z "$CARDANO_NODE_SOCKET_PATH" ]]
then
  CARDANO_NODE_SOCKET_PATH=node.socket
fi

# Select network.
if [[ -z "$MAGIC" ]]
then
  MAGIC=1567
fi
echo "MAGIC=$MAGIC"

# Wallet and PAB services.
WALLET_API=http://localhost:8090
PAB_API=http://localhost:9080

# The PAB passphrase must match the `--passphrase` argument of `marlowe-pab`.
PAB_PASSPHRASE=fixme-allow-pass-per-wallet

# The burn address is arbitrary.
BURN_ADDRESS=addr_test1vqxdw4rlu6krp9fwgwcnld6y84wdahg585vrdy67n5urp9qyts0y7

# Keys to the faucet for PAB testing.
FAUCET_SKEY=../../../keys/payment1.skey
FAUCET_VKEY=../../../keys/payment1.vkey

# Create the payment signing and verification keys if they do not already exist.
if [[ ! -e "$FAUCET_SKEY" ]]
then
  cardano-cli address key-gen --signing-key-file "$FAUCET_SKEY"      \
                              --verification-key-file "$FAUCET_VKEY"
fi
FAUCET_ADDRESS=$(cardano-cli address build --testnet-magic "$MAGIC" --payment-verification-key-file "$FAUCET_VKEY")

# Create the payment signing and verification keys if they do not already exist.
# sed 
# sed -n -e '/CreateWallet/{s/^.*Created wallet identified as \(.*\) for role "\(.*\)"\.$/\1/ ; p}' setup-wallets.log > wallet.ids

test_run=0
error_count=0
pids=()
function run() {
  for wid in $(cat wallet.ids)
  do
    test_run=$((test_run + 1))
    test_file="test-$wid-$test_run.yaml"
    log_file="test-$wid-$test_run.log"
    # NOTE: The line below is replacing any instances of WALLET_ID with $wid
    sed -e "s/WALLET_ID/$wid/" template.yaml > "$test_file"
    # NOTE: below is a way to replace more than 1 variable
    # sed -e "s/WALLET_ID/$wid/;s/PAYOR_ID/$payorid/" template.yaml > "$test_file"
    # NOTE: below is a way to apply commands stored in a file to the template.yaml
    # sed -f "file_with_commands" template.yaml > "$test_file"

    marlowe-cli test contracts --testnet-magic "$MAGIC"                  \
                              --socket-path "$CARDANO_NODE_SOCKET_PATH" \
                              --wallet-url "$WALLET_API"                \
                              --pab-url "$PAB_API"                      \
                              --faucet-key "$FAUCET_SKEY"               \
                              --faucet-address "$FAUCET_ADDRESS"        \
                              --burn-address "$BURN_ADDRESS"            \
                              --passphrase "$PAB_PASSPHRASE"            \
                              "$test_file"                              \
                              >& "$log_file"                             
    if [ $? -ne 0 ]; then
      error_count=$((error_count + 1))
      echo "ERROR COUNTS: $error_count"
    else
      pids+=($!)
      echo "TEST RUN: $test_run"
    fi
  done
}

for ((n=1; n <= 10; n++))
do
  run
done

echo "There were $(grep FAIL *.log | wc -l) failures in the log files."