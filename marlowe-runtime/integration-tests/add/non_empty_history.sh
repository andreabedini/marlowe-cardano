#!/usr/bin/env bash

echo "Marlowe Runtime Tests: marlowe add with non empty history"

echo "Test Scneario set up steps:"

echo "Confirm marlowe run executable is installed"
marlowe --help

echo "set env variables"
export CARDANO_NODE_SOCKET_PATH=/tmp/preview.socket
export CARDANO_TESTNET_MAGIC=2
MAGIC=(--testnet-magic 2)
echo "${MAGIC[@]}"

EXISTING_CONTRACT_ID=06b5a9fe7e9868648671333ee1a5ece61af9019b12251b68f1e9fc01cd7a12b2#1
NEW_CONTRACT_ID=02811e36c6cdac4721b53f718c4a1406e09ef0d985f9ad6b7fd676769e2f866c#1
INVALID_CONTRACT_ID=06b5a9fe7e9868648671333ee1a5ece61af9019b12251b68f1e9fc01cd7a12b2
MISSING_CONTRACT_ID=

marlowe rm $EXISTING_CONTRACT_ID
marlowe rm $NEW_CONTRACT_ID
marlowe add $EXISTING_CONTRACT_ID

marlowe ls
echo "Test Scnario set up done"

echo "Scenario: Adding a new contract id when an existing contract is managed in history"
marlowe add $NEW_CONTRACT_ID

echo "Expect to see $EXISTING_CONTRACT_ID and $NEW_CONTRACT_ID in history"
marlowe ls

echo "Scenario: Adding an already managed contract id to history should raise an error"

echo "Expect to see an error: 'Contract already managed in history"
marlowe add $EXISTING_CONTRACT_ID

echo "Expect to see $EXISTING_CONTRACT_ID and $NEW_CONTRACT_ID in history"
marlowe ls

echo "Expect to see an error: 'Contract already managed in history"
marlowe add $NEW_CONTRACT_ID

echo "Expect to see $EXISTING_CONTRACT_ID and $NEW_CONTRACT_ID in history"
marlowe ls