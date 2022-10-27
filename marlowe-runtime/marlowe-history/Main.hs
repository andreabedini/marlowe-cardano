{-# LANGUAGE GADTs #-}

module Main
  where

import qualified Colog
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, bracket, bracketOnError, catch, throw, throwIO)
import qualified Data.Text as T
import Data.Void (Void)
import Language.Marlowe.Protocol.Sync.Codec (codecMarloweSync)
import Language.Marlowe.Protocol.Sync.Server (marloweSyncServerPeer)
import Language.Marlowe.Runtime.CLI.Option.Colog (Verbosity(LogLevel), logActionParser)
import Language.Marlowe.Runtime.ChainSync.Api
  (ChainSyncQuery(..), RuntimeChainSeekClient, WithGenesis(..), runtimeChainSeekCodec)
import qualified Language.Marlowe.Runtime.ChainSync.Api as ChainSync
import Language.Marlowe.Runtime.History (History(..), HistoryDependencies(..), mkHistory)
import Language.Marlowe.Runtime.History.Api (historyJobCodec, historyQueryCodec)
import Language.Marlowe.Runtime.History.JobServer (RunJobServer(RunJobServer))
import Language.Marlowe.Runtime.History.QueryServer (RunQueryServer(RunQueryServer))
import Language.Marlowe.Runtime.History.Store (hoistHistoryQueries)
import Language.Marlowe.Runtime.History.Store.Memory (mkHistoryQueriesInMemory)
import Language.Marlowe.Runtime.History.SyncServer (RunSyncServer(..))
import Language.Marlowe.Runtime.Logging.Colog (logErrorM)
import Network.Channel (socketAsChannel)
import Network.Protocol.ChainSeek.Client (chainSeekClientPeer)
import Network.Protocol.Driver (mkDriver)
import Network.Protocol.Job.Server (jobServerPeer)
import Network.Protocol.Query.Client (liftQuery', queryClientPeer)
import Network.Protocol.Query.Codec (codecQuery)
import Network.Protocol.Query.Server (queryServerPeer)
import Network.Socket
  ( AddrInfo(..)
  , AddrInfoFlag(..)
  , HostName
  , PortNumber
  , SockAddr
  , Socket
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
run Options{logAction=mainLogAction,..} = withSocketsDo do
  jobAddr <- resolve commandPort
  queryAddr <- resolve queryPort
  syncAddr <- resolve syncPort
  Colog.withBackgroundLogger Colog.defCapacity mainLogAction \logAction -> do
    let
      withNetworkClient :: forall a. String -> AddrInfo -> (Socket -> IO a) -> IO a
      withNetworkClient name serverAddr action = do
        let open = openClient serverAddr
        bracket open close action `catch` \(err :: SomeException) -> do
          let
            serverInfo = show (addrAddress serverAddr)
          logErrorM logAction . T.pack $
            show name <> " client (server at: " <> serverInfo <> ") failure: " <> show err <> " ."
          throw err

    bracket (openServer jobAddr) close \jobSocket ->
      bracket (openServer queryAddr) close \querySocket -> do
        bracket (openServer syncAddr) close \syncSocket -> do
          slotConfig <- queryChainSync GetSlotConfig
          securityParameter <- queryChainSync GetSecurityParameter
          let
            connectToChainSeek :: forall a. RuntimeChainSeekClient IO a -> IO a
            connectToChainSeek client = do
              chainSeekAddr <- head <$> getAddrInfo (Just clientHints) (Just chainSeekHost) (Just $ show chainSeekPort)
              withNetworkClient "Chain Seek" chainSeekAddr \chainSeekSocket -> do
                let driver = mkDriver throwIO runtimeChainSeekCodec $ socketAsChannel chainSeekSocket
                let peer = chainSeekClientPeer Genesis client
                fst <$> runPeerWithDriver driver peer (startDState driver)

            acceptRunJobServer = do
              (conn, _ :: SockAddr) <- accept jobSocket
              let driver = mkDriver throwIO historyJobCodec $ socketAsChannel conn
              pure $ RunJobServer \server -> do
                let peer = jobServerPeer server
                fst <$> runPeerWithDriver driver peer (startDState driver)

            acceptRunQueryServer = do
              (conn, _ :: SockAddr) <- accept querySocket
              let driver = mkDriver throwIO historyQueryCodec $ socketAsChannel conn
              pure $ RunQueryServer \server -> do
                let peer = queryServerPeer server
                fst <$> runPeerWithDriver driver peer (startDState driver)

            acceptRunSyncServer = do
              (conn, _ :: SockAddr) <- accept syncSocket
              let driver = mkDriver throwIO codecMarloweSync $ socketAsChannel conn
              pure $ RunSyncServer \server -> do
                let peer = marloweSyncServerPeer server
                fst <$> runPeerWithDriver driver peer (startDState driver)

          let followerPageSize = 1024 -- TODO move to config with a default
          History{..} <- atomically do
            historyQueries <- hoistHistoryQueries atomically <$> mkHistoryQueriesInMemory
            mkHistory HistoryDependencies{..}
          runHistory
  where
    openClient addr = bracketOnError (openSocket addr) close \sock -> do
      connect sock $ addrAddress addr
      pure sock

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
        let onHandshakeFailure _ = error "Chain seek handshake failed"
        let client = liftQuery' ChainSync.querySchema onHandshakeFailure . pure $ query
        let peer = queryClientPeer client
        result <- fst <$> runPeerWithDriver driver peer (startDState driver)

        let onFailure _ = error "failed to query chain seek server"
        pure $ either onFailure id result

data Options = Options
  { chainSeekPort       :: PortNumber
  , chainSeekQueryPort  :: PortNumber
  , commandPort         :: PortNumber
  , queryPort           :: PortNumber
  , syncPort            :: PortNumber
  , chainSeekHost       :: HostName
  , host                :: HostName
  , logAction           :: Colog.LogAction IO Colog.Message
  }

getOptions :: IO Options
getOptions = execParser $ info (helper <*> parser) infoMod
  where
    parser = Options
      <$> chainSeekPortParser
      <*> chainSeekQueryPortParser
      <*> commandPortParser
      <*> queryPortParser
      <*> syncPortParser
      <*> chainSeekHostParser
      <*> hostParser
      <*> logActionParser (LogLevel Colog.Error)

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

    commandPortParser = option auto $ mconcat
      [ long "command-port"
      , value 3717
      , metavar "PORT_NUMBER"
      , help "The port number to run the job server on."
      , showDefault
      ]

    queryPortParser = option auto $ mconcat
      [ long "query-port"
      , value 3718
      , metavar "PORT_NUMBER"
      , help "The port number to run the query server on."
      , showDefault
      ]

    syncPortParser = option auto $ mconcat
      [ long "sync-port"
      , value 3719
      , metavar "PORT_NUMBER"
      , help "The port number to run the sync server on."
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
      , help "The host name to run the history server on."
      , showDefault
      ]

    infoMod = mconcat
      [ fullDesc
      , progDesc "Contract history service for Marlowe Runtime"
      , header "marlowe-history : a contract history service for the Marlowe Runtime."
      ]
