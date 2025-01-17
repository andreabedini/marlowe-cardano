# Application for Scale Testing of Marlowe Runtime

To run multiple contracts for multiple wallets, set environment variables to the hosts and ports for the Marlowe Runtime instances (see [Help](#help)), and on the command line supply that along with the number of repetitions and the pairs of addresses and keys.

```bash
marlowe-scaling 2 \
  addr_test1qryrafsnj3wt3as5pgeng8ddh42gq0dk8gphkz3mx8utzn6h3execksjs6h7k77qflc3mydgdlk98snlj6ngqzltl8mqjuqmk9=alice.skey \
  addr_test1qzl43spe69knxgfl5eqxrr89lwkef3elskmapjvzmy6akmu68l4aw87t9a9304rgj2p67tlrzaszh32ej3nlwp5t8zsqdcz20w=bob.skey \
|& jq 'select(.Contract)'
```

The output will show which transactions are submitted for which contracts, punctuated by an success/failure (`Right`/`Left`) report after each contract closes.

```JSON
{
  "Contract": {
    "end": "2022-12-31T16:16:28.399591192Z",
    "event-id": "f293b084-9b8c-45f0-8c1b-eaf12e0c57f0",
    "fields": {
      "success": "7741671ad473c5c1a532f921da6e8b9c942cc445ba316c70f0cf0dc395502ef6#1",
      "threadId": "ThreadId 2"
    },
    "start": "2022-12-31T16:15:34.313226613Z"
  }
}
```
```JSON
{
  "Contract": {
    "end": "2022-12-31T16:16:28.400022128Z",
    "event-id": "f70754c7-39b0-4634-a210-1e109e1c1047",
    "fields": {
      "success": "bcab6da80765cc128be6611224895c495d43a4a40ccf46fa3dd73a9a71e44c17#1",
      "threadId": "ThreadId 5"
    },
    "start": "2022-12-31T16:15:34.313234766Z"
  }
}
```
```JSON
{
  "Contract": {
    "end": "2022-12-31T16:17:22.765717631Z",
    "event-id": "a187c5f9-a740-49cb-8817-7c237593480b",
    "fields": {
      "success": "dd64edd77fc7405112b147ab847f9fc81952d1ab90bc6808c7851f84f84597bb#1",
      "threadId": "ThreadId 5"
    },
    "start": "2022-12-31T16:16:28.40002814Z"
  }
}
```
```JSON
{
  "Contract": {
    "end": "2022-12-31T16:17:23.322001857Z",
    "event-id": "6b808865-a785-4831-b83a-83dc63f48805",
    "fields": {
      "success": "8e8c216bf4a91e45c6da4f3c75211145e5fde662e12e7a93536d557c2d6248af#1",
      "threadId": "ThreadId 2"
    },
    "start": "2022-12-31T16:16:28.399615255Z"
  }
}

```

## Help

```console
$ marlowe-scaling --help

marlowe-scaling : run multiple Marlowe test contracts in parallel

Usage: marlowe-scaling [--chain-seek-host HOST_NAME]
                       [--chain-seek-command-port PORT_NUMBER]
                       [--chain-seek-query-port PORT_NUMBER]
                       [--chain-seek-sync-port PORT_NUMBER]
                       [--history-host HOST_NAME]
                       [--history-command-port PORT_NUMBER]
                       [--history-query-port PORT_NUMBER]
                       [--history-sync-port PORT_NUMBER]
                       [--discovery-host HOST_NAME]
                       [--discovery-query-port PORT_NUMBER]
                       [--discovery-sync-port PORT_NUMBER] [--tx-host HOST_NAME]
                       [--tx-command-port PORT_NUMBER]
                       [--timeout-seconds INTEGER] NATURAL [ADDRESS=KEYFILE]

  This command-line tool is a scaling test client for Marlowe Runtime: it runs
  multiple contracts in parallel against a Marlowe Runtime backend, with a
  specified number of contracts run in sequence for each party and each party
  running contracts in parallel.

Available options:
  -h,--help                Show this help text
  --chain-seek-host HOST_NAME
                           The hostname of the Marlowe Runtime chain-seek
                           server. Can be set as the environment variable
                           MARLOWE_RT_CHAINSEEK_HOST (default: "127.0.0.1")
  --chain-seek-command-port PORT_NUMBER
                           The port number of the chain-seek server's job API.
                           Can be set as the environment variable
                           MARLOWE_RT_CHAINSEEK_COMMAND_PORT (default: 23720)
  --chain-seek-query-port PORT_NUMBER
                           The port number of the chain-seek server's query API.
                           Can be set as the environment variable
                           MARLOWE_RT_CHAINSEEK_QUERY_PORT (default: 23716)
  --chain-seek-sync-port PORT_NUMBER
                           The port number of the chain-seek server's
                           synchronization API. Can be set as the environment
                           variable MARLOWE_RT_CHAINSEEK_SYNC_PORT
                           (default: 23715)
  --history-host HOST_NAME The hostname of the Marlowe Runtime history server.
                           Can be set as the environment variable
                           MARLOWE_RT_HISTORY_HOST (default: "127.0.0.1")
  --history-command-port PORT_NUMBER
                           The port number of the history server's job API. Can
                           be set as the environment variable
                           MARLOWE_RT_HISTORY_COMMAND_PORT (default: 23717)
  --history-query-port PORT_NUMBER
                           The port number of the history server's query API.
                           Can be set as the environment variable
                           MARLOWE_RT_HISTORY_QUERY_PORT (default: 23718)
  --history-sync-port PORT_NUMBER
                           The port number of the history server's
                           synchronization API. Can be set as the environment
                           variable MARLOWE_RT_HISTORY_SYNC_PORT
                           (default: 23719)
  --discovery-host HOST_NAME
                           The hostname of the Marlowe Runtime discovery server.
                           Can be set as the environment variable
                           MARLOWE_RT_DISCOVERY_HOST (default: "127.0.0.1")
  --discovery-query-port PORT_NUMBER
                           The port number of the discovery server's query API.
                           Can be set as the environment variable
                           MARLOWE_RT_DISCOVERY_QUERY_PORT (default: 23721)
  --discovery-sync-port PORT_NUMBER
                           The port number of the discovery server's
                           synchronization API. Can be set as the environment
                           variable MARLOWE_RT_DISCOVERY_SYNC_PORT
                           (default: 23722)
  --tx-host HOST_NAME      The hostname of the Marlowe Runtime transaction
                           server. Can be set as the environment variable
                           MARLOWE_RT_TX_HOST (default: "127.0.0.1")
  --tx-command-port PORT_NUMBER
                           The port number of the transaction server's job API.
                           Can be set as the environment variable
                           MARLOWE_RT_TX_COMMAND_PORT (default: 23723)
  --timeout-seconds INTEGER
                           Time timeout in seconds for transaction confirmation.
  NATURAL                  The number of contracts to run sequentially for each
                           party.
  ADDRESS=KEYFILE          The addresses of the parties and the files with their
                           signing keys.
```
