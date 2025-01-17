# Command-Line Interface to Marlowe Runtime

The `marlowe` executable provides a command-line interface to interacting with Marlowe Runtime services. All communication is via TCP sockets.

- Building transactions
	- [Create a contract](marlowe/create.md)
	- [Advance a contract through a timeout](marlowe/advance.md)
	- [Apply a choice to a contract](marlowe/choose.md)
	- [Deposit funds into a contract](marlowe/deposit.md)
	- [Notify a contract](marlowe/notify.md)
	- [Apply multiple inputs to a contract](marlowe/apply.md)
	- [Withdraw funds paid by a contract](marlowe/withdraw.md)
- Submitting transactions
	- [Submit a signed transaction to the node](marlowe/submit.md)
- Querying history
	- [List the contracts being tracked](marlowe/ls.md)
	- [Add a contract to the set of tracked contracts](marlowe/add.md)
	- [Remove a contract from the set of tracked contracts](marlowe/rm.md)
	- [Output the History of a contract](marlowe/log.md)

```console
Usage: marlowe [--history-host HOST_NAME] [--history-command-port PORT_NUMBER] 
               [--history-query-port PORT_NUMBER] 
               [--history-sync-port PORT_NUMBER] [--discovery-host HOST_NAME] 
               [--discovery-query-port PORT_NUMBER] [--tx-host HOST_NAME] 
               [--tx-command-port PORT_NUMBER] (COMMAND | COMMAND | COMMAND)

  Command line interface for managing Marlowe smart contracts on Cardano.

Available options:
  -h,--help                Show this help text
  --history-host HOST_NAME The hostname of the Marlowe Runtime history server.
                           Can be set as the environment variable
                           MARLOWE_RT_HISTORY_HOST (default: "127.0.0.1")
  --history-command-port PORT_NUMBER
                           The port number of the history server's job API. Can
                           be set as the environment variable
                           MARLOWE_RT_HISTORY_COMMAND_PORT (default: 3717)
  --history-query-port PORT_NUMBER
                           The port number of the history server's query API.
                           Can be set as the environment variable
                           MARLOWE_RT_HISTORY_QUERY_PORT (default: 3718)
  --history-sync-port PORT_NUMBER
                           The port number of the history server's
                           synchronization API. Can be set as the environment
                           variable MARLOWE_RT_HISTORY_SYNC_PORT (default: 3719)
  --discovery-host HOST_NAME
                           The hostname of the Marlowe Runtime discovery server.
                           Can be set as the environment variable
                           MARLOWE_RT_DISCOVERY_HOST (default: "127.0.0.1")
  --discovery-query-port PORT_NUMBER
                           The port number of the discovery server's query API.
                           Can be set as the environment variable
                           MARLOWE_RT_DISCOVERY_QUERY_PORT (default: 3721)
  --tx-host HOST_NAME      The hostname of the Marlowe Runtime transaction
                           server. Can be set as the environment variable
                           MARLOWE_RT_TX_HOST (default: "127.0.0.1")
  --tx-command-port PORT_NUMBER
                           The port number of the transaction server's job API.
                           Can be set as the environment variable
                           MARLOWE_RT_TX_COMMAND_PORT (default: 3723)

Contract history commands
  add                      Start managing a new contract
  log                      Display the history of a contract
  ls                       List managed contracts
  rm                       Stop managing a contract

Contract transaction commands
  apply                    Apply inputs to a contract
  advance                  Advance a timed-out contract by applying an empty set
                           of inputs.
  deposit                  Deposit funds into a contract
  choose                   Notify a contract to proceed
  notify                   Notify a contract to proceed
  create                   Create a new Marlowe Contract
  withdraw                 Withdraw funds paid to a role in a contract

Low level commands
  submit                   Submit a signed transaction to the Cardano node.
                           Expects the CBOR bytes of the signed Tx from stdin.
```
