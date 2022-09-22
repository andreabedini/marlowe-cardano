{-# LANGUAGE GADTs #-}

module Main
  where

import Control.Concurrent.STM (atomically)
import Control.Exception (bracket, bracketOnError, throwIO)
import Data.Either (fromRight)
import Data.Void (Void)
import Language.Marlowe.Protocol.Sync.Client (MarloweSyncClient, marloweSyncClientPeer)
import Language.Marlowe.Protocol.Sync.Codec (codecMarloweSync)
import Language.Marlowe.Runtime.ChainSync.Api (ChainSyncQuery(..))
import Language.Marlowe.Runtime.Transaction.Constraints (SolveConstraints)
import qualified Language.Marlowe.Runtime.Transaction.Constraints as Constraints
import qualified Language.Marlowe.Runtime.Transaction.Query as Query
import Language.Marlowe.Runtime.Transaction.Server
  (RunTransactionServer(..), TransactionServer(..), TransactionServerDependencies(..), mkTransactionServer)
import qualified Language.Marlowe.Runtime.Transaction.Submit as Submit
import Network.Channel (socketAsChannel)
import Network.Protocol.Driver (mkDriver)
import Network.Protocol.Job.Codec (codecJob)
import Network.Protocol.Job.Server (jobServerPeer)
import Network.Protocol.Query.Client (liftQuery, queryClientPeer)
import Network.Protocol.Query.Codec (codecQuery)
import Network.Socket
  ( AddrInfo(..)
  , AddrInfoFlag(..)
  , HostName
  , PortNumber
  , SockAddr
  , SocketOption(..)
  , SocketType(..)
  , accept
  , bind
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , listen
  , openSocket
  , setCloseOnExecIfNeeded
  , setSocketOption
  , withFdSocket
  , withSocketsDo
  )
import Network.TypedProtocol (runPeerWithDriver, startDState)
import Options.Applicative
  ( auto
  , execParser
  , fullDesc
  , header
  , help
  , helper
  , info
  , long
  , metavar
  , option
  , progDesc
  , short
  , showDefault
  , strOption
  , value
  )

main :: IO ()
main = run =<< getOptions

clientHints :: AddrInfo
clientHints = defaultHints { addrSocketType = Stream }

run :: Options -> IO ()
run Options{..} = withSocketsDo do
  addr <- resolve port
  bracket (openServer addr) close \socket -> do
    let
      acceptRunTransactionServer = do
        (conn, _ :: SockAddr) <- accept socket
        let driver = mkDriver throwIO codecJob $ socketAsChannel conn
        pure $ RunTransactionServer \server -> do
          let peer = jobServerPeer server
          fst <$> runPeerWithDriver driver peer (startDState driver)

      runHistorySyncClient :: MarloweSyncClient IO a -> IO a
      runHistorySyncClient client = do
        historySyncAddr <- head <$> getAddrInfo (Just clientHints) (Just chainSeekHost) (Just $ show chainSeekQueryPort)
        bracket (openClient historySyncAddr) close \historySyncSocket -> do
          let driver = mkDriver throwIO codecMarloweSync $ socketAsChannel historySyncSocket
          let peer = marloweSyncClientPeer client
          fst <$> runPeerWithDriver driver peer (startDState driver)

    let mkSubmitJob = Submit.mkSubmitJob
    systemStart <- queryChainSync GetSystemStart
    eraHistory <- queryChainSync GetEraHistory
    protocolParameters <- queryChainSync GetProtocolParameters
    slotConfig <- queryChainSync GetSlotConfig
    networkId <- queryChainSync GetNetworkId
    let
      solveConstraints :: forall era v. SolveConstraints era v
      solveConstraints = Constraints.solveConstraints
        networkId
        systemStart
        eraHistory
        protocolParameters
    let loadWalletContext = Query.loadWalletContext
    let loadMarloweContext = Query.loadMarloweContext runHistorySyncClient
    TransactionServer{..} <- atomically do
      mkTransactionServer TransactionServerDependencies{..}
    runTransactionServer
  where
    openServer addr = bracketOnError (openSocket addr) close \socket -> do
      setSocketOption socket ReuseAddr 1
      withFdSocket socket setCloseOnExecIfNeeded
      bind socket $ addrAddress addr
      listen socket 2048
      return socket

    resolve p = do
      let hints = defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
      head <$> getAddrInfo (Just hints) (Just host) (Just $ show p)

    queryChainSync :: ChainSyncQuery Void e a -> IO a
    queryChainSync query = do
      addr <- head <$> getAddrInfo (Just clientHints) (Just chainSeekHost) (Just $ show chainSeekQueryPort)
      bracket (openClient addr) close \socket -> do
        let driver = mkDriver throwIO codecQuery $ socketAsChannel socket
        let client = liftQuery query
        let peer = queryClientPeer client
        result <- fst <$> runPeerWithDriver driver peer (startDState driver)
        pure $ fromRight (error "failed to query chain seek server") result

    openClient addr = bracketOnError (openSocket addr) close \sock -> do
      connect sock $ addrAddress addr
      pure sock

data Options = Options
  { chainSeekPort      :: PortNumber
  , chainSeekQueryPort :: PortNumber
  , chainSeekHost      :: HostName
  , port               :: PortNumber
  , host               :: HostName
  , historySyncPort :: PortNumber
  , historyHost :: HostName
  }

getOptions :: IO Options
getOptions = execParser $ info (helper <*> parser) infoMod
  where
    parser = Options
      <$> chainSeekPortParser
      <*> chainSeekQueryPortParser
      <*> chainSeekHostParser
      <*> portParser
      <*> hostParser
      <*> historySyncPortParser
      <*> historyHostParser

    chainSeekPortParser = option auto $ mconcat
      [ long "chain-seek-port-number"
      , value 3715
      , metavar "PORT_NUMBER"
      , help "The port number of the chain seek server."
      , showDefault
      ]

    chainSeekQueryPortParser = option auto $ mconcat
      [ long "chain-seek-query-port-number"
      , value 3716
      , metavar "PORT_NUMBER"
      , help "The port number of the chain sync query server."
      , showDefault
      ]

    portParser = option auto $ mconcat
      [ long "command-port"
      , value 3720
      , metavar "PORT_NUMBER"
      , help "The port number to run the job server on."
      , showDefault
      ]

    chainSeekHostParser = strOption $ mconcat
      [ long "chain-seek-host"
      , value "127.0.0.1"
      , metavar "HOST_NAME"
      , help "The host name of the chain seek server."
      , showDefault
      ]

    hostParser = strOption $ mconcat
      [ long "host"
      , short 'h'
      , value "127.0.0.1"
      , metavar "HOST_NAME"
      , help "The host name to run the tx server on."
      , showDefault
      ]

    historySyncPortParser = option auto $ mconcat
      [ long "history-sync-port"
      , value 3719
      , metavar "PORT_NUMBER"
      , help "The port number of the history sync server."
      , showDefault
      ]

    historyHostParser = strOption $ mconcat
      [ long "history-host"
      , value "127.0.0.1"
      , metavar "HOST_NAME"
      , help "The host name of the history server."
      , showDefault
      ]

    infoMod = mconcat
      [ fullDesc
      , progDesc "Marlowe runtime transaction creation server"
      , header "marlowe-tx : the transaction creation server of the Marlowe Runtime"
      ]
