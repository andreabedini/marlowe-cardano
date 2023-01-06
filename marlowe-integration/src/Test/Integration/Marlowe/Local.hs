{-# LANGUAGE Arrows #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}

module Test.Integration.Marlowe.Local
  ( MarloweRuntime(..)
  , MarloweRuntimeOptions(..)
  , module Test.Integration.Cardano
  , defaultMarloweRuntimeOptions
  , withLocalMarloweRuntime
  ) where

import Cardano.Api
  ( AsType(..)
  , BabbageEra
  , CardanoEra(..)
  , CardanoMode
  , ChainPoint
  , ConsensusModeParams(..)
  , EpochSlots(..)
  , EraInMode(..)
  , LocalNodeConnectInfo(..)
  , NetworkId(..)
  , NetworkMagic(..)
  , QueryInMode
  , ScriptDataSupportedInEra(ScriptDataInBabbageEra)
  , StakeAddressReference(..)
  , Tx
  , TxBody
  , TxInMode(..)
  , TxValidationErrorInMode
  , deserialiseFromBech32
  , deserialiseFromTextEnvelope
  , getTxId
  , queryNodeLocalState
  , shelleyAddressInEra
  )
import qualified Cardano.Api as Cardano
import qualified Cardano.Api.Byron as Byron
import Cardano.Api.Shelley (AcquiringFailure)
import qualified Cardano.Chain.Genesis as Byron
import Cardano.Chain.UTxO (defaultUTxOConfiguration)
import Cardano.Crypto (abstractHashToBytes)
import Control.Concurrent.Async (race_)
import Control.Concurrent.Async.Lifted (Concurrently(..))
import Control.Concurrent.Component
import Control.Concurrent.STM (STM, atomically)
import Control.Exception (onException, throwIO)
import Control.Monad ((<=<))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.Reader (runReaderT)
import Control.Monad.Trans.Resource (allocate, runResourceT, unprotect)
import Data.Aeson (eitherDecodeFileStrict)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Either (fromRight)
import Data.Functor (void)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.String (fromString)
import qualified Data.Text as T
import qualified Data.Text.Lazy.IO as TL
import Data.Time.Clock (secondsToNominalDiffTime)
import Data.UUID.V4 (nextRandom)
import Data.Void (Void)
import Data.Word (Word16)
import Database.PostgreSQL.LibPQ (connectdb, errorMessage, exec, finish, resultErrorMessage)
import Hasql.Connection (settings)
import qualified Hasql.Pool as Pool
import Language.Marlowe.CLI.Transaction (buildPublishingImpl, submitBody)
import Language.Marlowe.CLI.Types
  ( CliEnv(..)
  , MarlowePlutusVersion
  , PrintStats(..)
  , PublishMarloweScripts(..)
  , PublishScript(..)
  , PublishingStrategy(..)
  , ValidatorInfo(..)
  , defaultCoinSelectionStrategy
  )
import Language.Marlowe.Protocol.HeaderSync.Client (MarloweHeaderSyncClient, marloweHeaderSyncClientPeer)
import Language.Marlowe.Protocol.HeaderSync.Codec (codecMarloweHeaderSync)
import Language.Marlowe.Protocol.HeaderSync.Server (MarloweHeaderSyncServer, marloweHeaderSyncServerPeer)
import Language.Marlowe.Protocol.HeaderSync.Types (MarloweHeaderSync)
import Language.Marlowe.Protocol.Sync.Client (MarloweSyncClient, marloweSyncClientPeer)
import Language.Marlowe.Protocol.Sync.Codec (codecMarloweSync)
import Language.Marlowe.Protocol.Sync.Server (MarloweSyncServer, marloweSyncServerPeer)
import Language.Marlowe.Protocol.Sync.Types (MarloweSync)
import Language.Marlowe.Runtime.Cardano.Api
  (fromCardanoAddressInEra, fromCardanoLovelace, fromCardanoScriptHash, fromCardanoTxId)
import Language.Marlowe.Runtime.ChainIndexer
  (ChainIndexerDependencies(..), ChainIndexerSelector, chainIndexer, getChainIndexerSelectorConfig)
import Language.Marlowe.Runtime.ChainIndexer.Database (CommitGenesisBlock(..), DatabaseQueries(..))
import qualified Language.Marlowe.Runtime.ChainIndexer.Database as ChainIndexer
import qualified Language.Marlowe.Runtime.ChainIndexer.Database.PostgreSQL as ChainIndexer
import Language.Marlowe.Runtime.ChainIndexer.Genesis (GenesisBlock, computeGenesisBlock)
import Language.Marlowe.Runtime.ChainIndexer.NodeClient (CostModel(CostModel))
import Language.Marlowe.Runtime.ChainSync (ChainSyncDependencies(..), chainSync)
import Language.Marlowe.Runtime.ChainSync.Api
  ( Assets(..)
  , ChainSyncCommand
  , ChainSyncQuery(..)
  , RuntimeChainSeek
  , RuntimeChainSeekClient
  , RuntimeChainSeekServer
  , TransactionOutput(..)
  , TxOutRef(TxOutRef)
  , WithGenesis(..)
  )
import qualified Language.Marlowe.Runtime.ChainSync.Database as ChainSync
import qualified Language.Marlowe.Runtime.ChainSync.Database.PostgreSQL as ChainSync
import Language.Marlowe.Runtime.Core.Api (MarloweVersion(..), SomeMarloweVersion(..))
import Language.Marlowe.Runtime.Core.ScriptRegistry (MarloweScripts(..), ReferenceScriptUtxo(..))
import Language.Marlowe.Runtime.Discovery
import Language.Marlowe.Runtime.Discovery.Api (DiscoveryQuery)
import Language.Marlowe.Runtime.History
import Language.Marlowe.Runtime.History.Api (HistoryCommand, HistoryQuery)
import Language.Marlowe.Runtime.History.Store (HistoryQueries, hoistHistoryQueries)
import Language.Marlowe.Runtime.History.Store.Memory (mkHistoryQueriesInMemory)
import Language.Marlowe.Runtime.Transaction
import Language.Marlowe.Runtime.Transaction.Api (MarloweTxCommand)
import Language.Marlowe.Runtime.Transaction.Query (LoadMarloweContext)
import qualified Language.Marlowe.Runtime.Transaction.Query as Query
import Language.Marlowe.Runtime.Transaction.Server (TransactionServerSelector)
import Language.Marlowe.Runtime.Transaction.Submit (SubmitJob, SubmitJobDependencies(..))
import qualified Language.Marlowe.Runtime.Transaction.Submit as Submit
import Network.Protocol.ChainSeek.Client (chainSeekClientPeer)
import Network.Protocol.ChainSeek.Codec (codecChainSeek)
import Network.Protocol.ChainSeek.Server (chainSeekServerPeer)
import Network.Protocol.Driver
import Network.Protocol.Job.Client (JobClient, jobClientPeer)
import Network.Protocol.Job.Codec (codecJob)
import Network.Protocol.Job.Server (JobServer, jobServerPeer)
import Network.Protocol.Job.Types (Job)
import Network.Protocol.Query.Client (QueryClient, liftQuery, queryClientPeer)
import Network.Protocol.Query.Codec (codecQuery)
import Network.Protocol.Query.Server (QueryServer, queryServerPeer)
import Network.Protocol.Query.Types (Query)
import Observe.Event (EventBackend, narrowEventBackend)
import Observe.Event.Backend (newOnceFlagMVar)
import Observe.Event.Component
  (ConfigWatcherSelector(..), LoggerDependencies(..), SelectorConfig(..), logger, prependKey, singletonFieldConfig)
import Ouroboros.Network.Protocol.LocalTxSubmission.Type (SubmitResult)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.IO (BufferMode(..), IOMode(..), hSetBuffering)
import System.Process (readCreateProcessWithExitCode)
import qualified System.Process as SP
import Test.Integration.Cardano
import qualified Test.Integration.Cardano as SpoNode (SpoNode(..))
import Text.Read (readMaybe)
import UnliftIO (MonadUnliftIO, withRunInIO)

data MarloweRuntime = MarloweRuntime
  { runChainSyncQueryClient :: RunClient IO (QueryClient ChainSyncQuery)
  , runChainSeekClient :: RunClient IO RuntimeChainSeekClient
  , runDiscoveryQueryClient :: RunClient IO (QueryClient DiscoveryQuery)
  , runDiscoverySyncClient :: RunClient IO MarloweHeaderSyncClient
  , runHistoryJobClient :: RunClient IO (JobClient HistoryCommand)
  , runHistoryQueryClient :: RunClient IO (QueryClient HistoryQuery)
  , runHistorySyncClient :: RunClient IO MarloweSyncClient
  , runTxJobClient :: RunClient IO (JobClient MarloweTxCommand)
  , testnet :: LocalTestnet
  }

data MarloweRuntimeOptions = MarloweRuntimeOptions
  { databaseHost :: ByteString
  , databasePort :: Word16
  , databaseUser :: ByteString
  , databasePassword :: ByteString
  , tempDatabase :: ByteString
  , localTestnetOptions :: LocalTestnetOptions
  }

defaultMarloweRuntimeOptions :: IO MarloweRuntimeOptions
defaultMarloweRuntimeOptions = do
  databaseHost <- lookupEnv "MARLOWE_RT_TEST_DB_HOST"
  databasePort <- lookupEnv "MARLOWE_RT_TEST_DB_PORT"
  databaseUser <- lookupEnv "MARLOWE_RT_TEST_DB_USER"
  databasePassword <- lookupEnv "MARLOWE_RT_TEST_DB_PASSWORD"
  tempDatabase <- lookupEnv "MARLOWE_RT_TEST_TEMP_DB"
  pure $ MarloweRuntimeOptions
    (maybe "127.0.0.1" fromString databaseHost)
    (fromMaybe 5432 $ readMaybe =<< databasePort)
    (maybe "postgres" fromString databaseUser)
    (maybe "" fromString databasePassword)
    (maybe "template1" fromString tempDatabase)
    defaultOptions

withLocalMarloweRuntime :: MonadUnliftIO m => (MarloweRuntime -> m ()) -> m ()
withLocalMarloweRuntime test = do
  options <- liftIO defaultMarloweRuntimeOptions
  withLocalMarloweRuntime' options test

withLocalMarloweRuntime' :: MonadUnliftIO m => MarloweRuntimeOptions -> (MarloweRuntime -> m ()) -> m ()
withLocalMarloweRuntime' MarloweRuntimeOptions{..} test = withRunInIO \runInIO ->
  withLocalTestnet' localTestnetOptions \testnet@LocalTestnet{..} -> runResourceT do
    let localConsensusModeParams = CardanoModeParams $ EpochSlots 500
    let localNodeNetworkId = Testnet $ NetworkMagic $ fromIntegral testnetMagic
    let localNodeSocketPath = SpoNode.socket . head $ spoNodes
    let localNodeConnectInfo = LocalNodeConnectInfo{..}
    marloweScripts <- liftIO $ publishCurrentScripts testnet localNodeConnectInfo
    (dbReleaseKey, dbName) <- allocate (createDatabase workspace) cleanupDatabase
    liftIO $ migrateDatabase dbName
    let connectionString = settings databaseHost databasePort databaseUser databasePassword dbName
    let acquirePool = Pool.acquire (100, secondsToNominalDiffTime 5, connectionString)
    (_, pool) <- allocate acquirePool Pool.release
    logFileHandle <- openWorkspaceFile workspace "logs/runtime.log" WriteMode
    liftIO $ hSetBuffering logFileHandle LineBuffering
    (Concurrently runLogger, rootEventBackend) <- liftIO $ atomically $ unComponent logger LoggerDependencies
      { configFilePath = Just $ resolveWorkspacePath workspace "runtime.log.config"
      , getSelectorConfig = getRuntimeSelectorConfig
      , newRef = nextRandom
      , newOnceFlag = newOnceFlagMVar
      , writeText = TL.hPutStrLn logFileHandle
      , injectConfigWatcherSelector = ConfigWatcher
      }
    Channels{..} <- liftIO $ atomically $ setupChannels rootEventBackend
    historyQueries <- liftIO $ hoistHistoryQueries atomically <$> atomically mkHistoryQueriesInMemory
    genesisConfigResult <- runExceptT . Byron.readGenesisData $ byronGenesisJson network
    (genesisData, genesisHash) <- case genesisConfigResult of
      Left e -> fail $ show e
      Right a -> pure a
    shelleyGenesisConfig <- liftIO $ either error id <$> eitherDecodeFileStrict (shelleyGenesisJson network)
    let
      connectToChainSeek :: RunClient IO RuntimeChainSeekClient
      connectToChainSeek = runChainSeekClient

      byronGenesisConfig = Byron.Config
        genesisData
        genesisHash
        (Byron.toByronRequiresNetworkMagic localNodeNetworkId)
        defaultUTxOConfiguration

      genesisBlock = computeGenesisBlock
        (abstractHashToBytes $ Byron.unGenesisHash genesisHash)
        byronGenesisConfig
        shelleyGenesisConfig

      chainIndexerDatabaseQueries = ChainIndexer.hoistDatabaseQueries
        (either (fail . show) pure <=< Pool.use pool)
        (ChainIndexer.databaseQueries genesisBlock)
      chainSeekDatabaseQueries = ChainSync.hoistDatabaseQueries
        (either (fail . show) pure <=< Pool.use pool)
        ChainSync.databaseQueries

    let mkSubmitJob = Submit.mkSubmitJob SubmitJobDependencies{..}

    -- Persist the genesis block before starting the services so that they
    -- exist already and no database queries fail.
    liftIO do
      runCommitGenesisBlock (commitGenesisBlock chainIndexerDatabaseQueries) genesisBlock
      onException
        ( runComponent_ runtime RuntimeDependencies{..}
          `race_` runLogger
          `race_` runInIO (test MarloweRuntime{..})
        )
        (unprotect dbReleaseKey)
  where
    rootConnectionString = settings databaseHost databasePort databaseUser databasePassword tempDatabase

    checkResult connection = \case
      Nothing -> do
        msg <- errorMessage connection
        fail $ "Fatal database error: " <> show msg
      Just r -> do
        resultErrorMessage r >>= \case
          Nothing -> pure ()
          Just "" -> pure ()
          Just msg -> fail $ "Error creating database: " <> show msg

    createDatabase workspace = do
      connection <- connectdb rootConnectionString
      let dbName = fromString $ "chain_test_" <> show (workspaceId workspace)
      result1 <- exec connection $ "CREATE DATABASE \"" <> dbName <> "\"" <> ";"
      result2 <- exec connection $ "GRANT ALL PRIVILEGES ON DATABASE \"" <> dbName <> "\" TO " <> databaseUser <> ";"
      checkResult connection result1
      checkResult connection result2
      finish connection
      pure dbName

    cleanupDatabase dbName = do
      connection <- connectdb rootConnectionString
      result <- exec connection $ "DROP DATABASE \"" <> dbName <> "\";"
      checkResult connection result
      finish connection

    migrateDatabase dbName = do
      (exitCode, _, stderr) <- flip readCreateProcessWithExitCode "" $ (SP.proc "sqitch"
        [ "deploy"
        , "-h", BS.unpack databaseHost
        , "-p", show databasePort
        , "-u", BS.unpack databaseUser
        , "-d", BS.unpack dbName
        ])
        { SP.cwd = Just "./marlowe-chain-sync"
        }
      case exitCode of
        ExitFailure _ -> fail $ "sqitch failed: \n" <> stderr
        ExitSuccess -> pure ()

publishCurrentScripts :: LocalTestnet -> LocalNodeConnectInfo CardanoMode -> IO MarloweScripts
publishCurrentScripts LocalTestnet{..} localNodeConnectInfo = do
  let Delegator{..} = head delegators
  let PaymentKeyPair{..} = paymentKeyPair
  let StakingKeyPair{..} = stakingKeyPair
  signingKey <- Left
      . either (error . show) id
      . deserialiseFromTextEnvelope (AsSigningKey AsPaymentKey)
      . either error id
    <$> eitherDecodeFileStrict paymentSKey
  changeAddress <-
    either (error . show) shelleyAddressInEra
        . deserialiseFromBech32 (AsAddress AsShelleyAddr)
        . T.pack
      <$> execCli
        [ "address", "build"
        , "--payment-verification-key-file", paymentVKey
        , "--stake-verification-key-file", stakingVKey
        , "--testnet-magic", show testnetMagic
        ]
  let publishingStrategy = PublishPermanently NoStakeAddress
  let coinSelectionStrategy = defaultCoinSelectionStrategy
  either throwIO pure =<< runExceptT do
    flip runReaderT (CliEnv ScriptDataInBabbageEra) do
      (txBody, publishScripts) <- buildPublishingImpl
        localNodeConnectInfo
        signingKey
        Nothing
        changeAddress
        publishingStrategy
        coinSelectionStrategy
        (PrintStats False)
      void $ submitBody localNodeConnectInfo txBody [signingKey] 30
      pure $ toMarloweScripts testnetMagic txBody publishScripts

toMarloweScripts :: Int -> TxBody BabbageEra -> PublishMarloweScripts MarlowePlutusVersion BabbageEra -> MarloweScripts
toMarloweScripts testnetMagic txBody PublishMarloweScripts{..} = MarloweScripts{..}
  where
    marloweValidatorInfo = psReferenceValidator pmsMarloweScript
    payoutValidatorInfo = psReferenceValidator pmsRolePayoutScript
    marloweScript = fromCardanoScriptHash $ viHash marloweValidatorInfo
    payoutScript = fromCardanoScriptHash $ viHash payoutValidatorInfo
    networkId = Testnet $ NetworkMagic $ fromIntegral testnetMagic
    publishTxId = fromCardanoTxId $ getTxId txBody
    marloweTxOutRef = TxOutRef publishTxId 1
    payoutTxOutRef = TxOutRef publishTxId 2
    marloweReferenceScriptUTxO = ReferenceScriptUtxo
      { txOutRef = marloweTxOutRef
      , txOut = TransactionOutput
        { address = fromCardanoAddressInEra BabbageEra $ psPublisher pmsMarloweScript
        , assets = Assets (fromCardanoLovelace $ psMinAda pmsMarloweScript) mempty
        , datumHash = Nothing
        , datum = Nothing
        }
      , script = viScript marloweValidatorInfo
      }
    payoutReferenceScriptUTxO = ReferenceScriptUtxo
      { txOutRef = payoutTxOutRef
      , txOut = TransactionOutput
        { address = fromCardanoAddressInEra BabbageEra $ psPublisher pmsRolePayoutScript
        , assets = Assets (fromCardanoLovelace $ psMinAda pmsRolePayoutScript) mempty
        , datumHash = Nothing
        , datum = Nothing
        }
      , script = viScript payoutValidatorInfo
      }
    marloweScriptUTxOs = Map.singleton networkId marloweReferenceScriptUTxO
    payoutScriptUTxOs = Map.singleton networkId payoutReferenceScriptUTxO

data RuntimeSelector f where
  ChainSeekClientEvent :: ConnectSocketDriverSelector RuntimeChainSeek f -> RuntimeSelector f
  ChainSeekServerEvent :: AcceptSocketDriverSelector RuntimeChainSeek f -> RuntimeSelector f
  ChainSyncJobClientEvent :: ConnectSocketDriverSelector (Job ChainSyncCommand) f -> RuntimeSelector f
  ChainSyncJobServerEvent :: AcceptSocketDriverSelector (Job ChainSyncCommand) f -> RuntimeSelector f
  ChainSyncQueryClientEvent :: ConnectSocketDriverSelector (Query ChainSyncQuery) f -> RuntimeSelector f
  ChainSyncQueryServerEvent :: AcceptSocketDriverSelector (Query ChainSyncQuery) f -> RuntimeSelector f
  DiscoveryQueryClientEvent :: ConnectSocketDriverSelector (Query DiscoveryQuery) f -> RuntimeSelector f
  DiscoveryQueryServerEvent :: AcceptSocketDriverSelector (Query DiscoveryQuery) f -> RuntimeSelector f
  DiscoverySyncClientEvent :: ConnectSocketDriverSelector MarloweHeaderSync f -> RuntimeSelector f
  DiscoverySyncServerEvent :: AcceptSocketDriverSelector MarloweHeaderSync f -> RuntimeSelector f
  HistoryJobClientEvent :: ConnectSocketDriverSelector (Job HistoryCommand) f -> RuntimeSelector f
  HistoryJobServerEvent :: AcceptSocketDriverSelector (Job HistoryCommand) f -> RuntimeSelector f
  HistoryQueryClientEvent :: ConnectSocketDriverSelector (Query HistoryQuery) f -> RuntimeSelector f
  HistoryQueryServerEvent :: AcceptSocketDriverSelector (Query HistoryQuery) f -> RuntimeSelector f
  HistorySyncClientEvent :: ConnectSocketDriverSelector MarloweSync f -> RuntimeSelector f
  HistorySyncServerEvent :: AcceptSocketDriverSelector MarloweSync f -> RuntimeSelector f
  TxJobClientEvent :: ConnectSocketDriverSelector (Job MarloweTxCommand) f -> RuntimeSelector f
  TxJobServerEvent :: AcceptSocketDriverSelector (Job MarloweTxCommand) f -> RuntimeSelector f
  TxEvent :: TransactionServerSelector f -> RuntimeSelector f
  ChainIndexerEvent :: ChainIndexerSelector f -> RuntimeSelector f
  ConfigWatcher :: ConfigWatcherSelector f -> RuntimeSelector f

data RuntimeDependencies r = RuntimeDependencies
  { acceptRunChainSeekServer :: IO (RunServer IO RuntimeChainSeekServer)
  , acceptRunChainSyncJobServer :: IO (RunServer IO (JobServer ChainSyncCommand))
  , acceptRunChainSyncQueryServer :: IO (RunServer IO (QueryServer ChainSyncQuery))
  , acceptRunDiscoveryQueryServer :: IO (RunServer IO (QueryServer DiscoveryQuery))
  , acceptRunDiscoverySyncServer :: IO (RunServer IO MarloweHeaderSyncServer)
  , acceptRunHistoryJobServer :: IO (RunServer IO (JobServer HistoryCommand))
  , acceptRunHistoryQueryServer :: IO (RunServer IO (QueryServer HistoryQuery))
  , acceptRunHistorySyncServer :: IO (RunServer IO MarloweSyncServer)
  , acceptRunTxJobServer :: IO (RunServer IO (JobServer MarloweTxCommand))
  , chainIndexerDatabaseQueries :: ChainIndexer.DatabaseQueries IO
  , chainSeekDatabaseQueries :: ChainSync.DatabaseQueries IO
  , genesisBlock :: !GenesisBlock
  , historyQueries :: HistoryQueries IO
  , localNodeConnectInfo :: LocalNodeConnectInfo CardanoMode
  , mkSubmitJob :: Tx BabbageEra -> STM SubmitJob
  , rootEventBackend :: EventBackend IO r RuntimeSelector
  , runChainSeekClient :: RunClient IO RuntimeChainSeekClient
  , runChainSyncJobClient :: RunClient IO (JobClient ChainSyncCommand)
  , runChainSyncQueryClient :: RunClient IO (QueryClient ChainSyncQuery)
  , securityParameter :: Int
  , marloweScripts :: MarloweScripts
  }

runtime :: Component IO (RuntimeDependencies r) ()
runtime = proc RuntimeDependencies{..} -> do
  let
    connectToChainSeek :: RunClient IO RuntimeChainSeekClient
    connectToChainSeek = runChainSeekClient

    MarloweScripts{..} = marloweScripts

    getMarloweVersion scriptHash
      | scriptHash == marloweScript = Just (SomeMarloweVersion MarloweV1, marloweScripts)
      | otherwise = Nothing

    getScripts :: MarloweVersion v -> Set MarloweScripts
    getScripts MarloweV1 = Set.singleton marloweScripts

    getCurrentScripts :: MarloweVersion v -> MarloweScripts
    getCurrentScripts MarloweV1 = marloweScripts

    LocalNodeConnectInfo{..} = localNodeConnectInfo

  chainIndexer -<
    let
      maxCost = 100_000
      costModel = CostModel 1 10
      persistRateLimit = secondsToNominalDiffTime 0.1
      databaseQueries = chainIndexerDatabaseQueries
      eventBackend = narrowEventBackend ChainIndexerEvent rootEventBackend
      connectToLocalNode = Cardano.connectToLocalNode localNodeConnectInfo
     in
      ChainIndexerDependencies{..}

  chainSync -<
    let
      acceptRunJobServer = acceptRunChainSyncJobServer
      acceptRunQueryServer = acceptRunChainSyncQueryServer
      databaseQueries = chainSeekDatabaseQueries

      queryLocalNodeState :: Maybe ChainPoint -> QueryInMode CardanoMode result -> IO (Either AcquiringFailure result)
      queryLocalNodeState = queryNodeLocalState localNodeConnectInfo

      submitTxToNodeLocal :: CardanoEra era -> Tx era -> IO (SubmitResult (TxValidationErrorInMode CardanoMode))
      submitTxToNodeLocal era tx = Cardano.submitTxToNodeLocal localNodeConnectInfo $ TxInMode tx case era of
        ByronEra -> ByronEraInCardanoMode
        ShelleyEra -> ShelleyEraInCardanoMode
        AllegraEra -> AllegraEraInCardanoMode
        MaryEra -> MaryEraInCardanoMode
        AlonzoEra -> AlonzoEraInCardanoMode
        BabbageEra -> BabbageEraInCardanoMode
     in
      ChainSyncDependencies{..}

  history -<
    let
      acceptRunJobServer = acceptRunHistoryJobServer
      acceptRunQueryServer = acceptRunHistoryQueryServer
      acceptRunSyncServer = acceptRunHistorySyncServer
      followerPageSize = 1024

      queryChainSeek :: ChainSyncQuery Void err results -> IO (Either err results)
      queryChainSeek = runChainSyncQueryClient . liftQuery

    in
      HistoryDependencies{..}

  discovery -<
    let
      acceptRunQueryServer = acceptRunDiscoveryQueryServer
      acceptRunSyncServer = acceptRunDiscoverySyncServer
      pageSize = 1024
    in
      DiscoveryDependencies{..}

  transaction -<
    let
      acceptRunTransactionServer = acceptRunTxJobServer

      queryChainSync :: ChainSyncQuery Void err results -> IO results
      queryChainSync = fmap (fromRight $ error "failed to query chain seek server")
        . runChainSyncQueryClient
        . liftQuery

      loadWalletContext = Query.loadWalletContext $ queryChainSync . GetUTxOs

      networkId = localNodeNetworkId

      loadMarloweContext :: LoadMarloweContext r
      loadMarloweContext = Query.loadMarloweContext getScripts networkId connectToChainSeek runChainSyncQueryClient

      eventBackend = narrowEventBackend TxEvent rootEventBackend
    in
      TransactionDependencies{..}

data Channels = Channels
  { acceptRunChainSeekServer :: IO (RunServer IO RuntimeChainSeekServer)
  , acceptRunChainSyncJobServer :: IO (RunServer IO (JobServer ChainSyncCommand))
  , acceptRunChainSyncQueryServer :: IO (RunServer IO (QueryServer ChainSyncQuery))
  , acceptRunDiscoveryQueryServer :: IO (RunServer IO (QueryServer DiscoveryQuery))
  , acceptRunDiscoverySyncServer :: IO (RunServer IO MarloweHeaderSyncServer)
  , acceptRunHistoryJobServer :: IO (RunServer IO (JobServer HistoryCommand))
  , acceptRunHistoryQueryServer :: IO (RunServer IO (QueryServer HistoryQuery))
  , acceptRunHistorySyncServer :: IO (RunServer IO MarloweSyncServer)
  , acceptRunTxJobServer :: IO (RunServer IO (JobServer MarloweTxCommand))
  , runChainSeekClient :: RunClient IO RuntimeChainSeekClient
  , runChainSyncJobClient :: RunClient IO (JobClient ChainSyncCommand)
  , runChainSyncQueryClient :: RunClient IO (QueryClient ChainSyncQuery)
  , runDiscoveryQueryClient :: RunClient IO (QueryClient DiscoveryQuery)
  , runDiscoverySyncClient :: RunClient IO MarloweHeaderSyncClient
  , runHistoryJobClient :: RunClient IO (JobClient HistoryCommand)
  , runHistoryQueryClient :: RunClient IO (QueryClient HistoryQuery)
  , runHistorySyncClient :: RunClient IO MarloweSyncClient
  , runTxJobClient :: RunClient IO (JobClient MarloweTxCommand)
  }

setupChannels :: EventBackend IO r RuntimeSelector -> STM Channels
setupChannels eventBackend = do
  ClientServerPair acceptRunChainSeekServer runChainSeekClient <- clientServerPair
    (narrowEventBackend ChainSeekServerEvent eventBackend)
    (narrowEventBackend ChainSeekClientEvent eventBackend)
    throwIO
    codecChainSeek
    (chainSeekServerPeer Genesis)
    (chainSeekClientPeer Genesis)
  ClientServerPair acceptRunChainSyncJobServer runChainSyncJobClient <- clientServerPair
    (narrowEventBackend ChainSyncJobServerEvent eventBackend)
    (narrowEventBackend ChainSyncJobClientEvent eventBackend)
    throwIO
    codecJob
    jobServerPeer
    jobClientPeer
  ClientServerPair acceptRunChainSyncQueryServer runChainSyncQueryClient <- clientServerPair
    (narrowEventBackend ChainSyncQueryServerEvent eventBackend)
    (narrowEventBackend ChainSyncQueryClientEvent eventBackend)
    throwIO
    codecQuery
    queryServerPeer
    queryClientPeer
  ClientServerPair acceptRunDiscoveryQueryServer runDiscoveryQueryClient <- clientServerPair
    (narrowEventBackend DiscoveryQueryServerEvent eventBackend)
    (narrowEventBackend DiscoveryQueryClientEvent eventBackend)
    throwIO
    codecQuery
    queryServerPeer
    queryClientPeer
  ClientServerPair acceptRunDiscoverySyncServer runDiscoverySyncClient <- clientServerPair
    (narrowEventBackend DiscoverySyncServerEvent eventBackend)
    (narrowEventBackend DiscoverySyncClientEvent eventBackend)
    throwIO
    codecMarloweHeaderSync
    marloweHeaderSyncServerPeer
    marloweHeaderSyncClientPeer
  ClientServerPair acceptRunHistoryJobServer runHistoryJobClient <- clientServerPair
    (narrowEventBackend HistoryJobServerEvent eventBackend)
    (narrowEventBackend HistoryJobClientEvent eventBackend)
    throwIO
    codecJob
    jobServerPeer
    jobClientPeer
  ClientServerPair acceptRunHistoryQueryServer runHistoryQueryClient <- clientServerPair
    (narrowEventBackend HistoryQueryServerEvent eventBackend)
    (narrowEventBackend HistoryQueryClientEvent eventBackend)
    throwIO
    codecQuery
    queryServerPeer
    queryClientPeer
  ClientServerPair acceptRunHistorySyncServer runHistorySyncClient <- clientServerPair
    (narrowEventBackend HistorySyncServerEvent eventBackend)
    (narrowEventBackend HistorySyncClientEvent eventBackend)
    throwIO
    codecMarloweSync
    marloweSyncServerPeer
    marloweSyncClientPeer
  ClientServerPair acceptRunTxJobServer runTxJobClient <- clientServerPair
    (narrowEventBackend TxJobServerEvent eventBackend)
    (narrowEventBackend TxJobClientEvent eventBackend)
    throwIO
    codecJob
    jobServerPeer
    jobClientPeer
  pure Channels{..}

getRuntimeSelectorConfig :: RuntimeSelector f -> SelectorConfig f
getRuntimeSelectorConfig = \case
  ChainSeekClientEvent sel -> prependKey "chain-seek.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  ChainSeekServerEvent sel -> prependKey "chain-seek.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  ChainSyncJobClientEvent sel -> prependKey "chain-sync-job.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  ChainSyncJobServerEvent sel -> prependKey "chain-sync-job.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  ChainSyncQueryClientEvent sel -> prependKey "chain-sync-query.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  ChainSyncQueryServerEvent sel -> prependKey "chain-sync-query.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  DiscoveryQueryClientEvent sel -> prependKey "discovery-query.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  DiscoveryQueryServerEvent sel -> prependKey "discovery-query.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  DiscoverySyncClientEvent sel -> prependKey "discovery-job.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  DiscoverySyncServerEvent sel -> prependKey "discovery-job.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  HistoryJobClientEvent sel -> prependKey "history-sync.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  HistoryJobServerEvent sel -> prependKey "history-sync.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  HistoryQueryClientEvent sel -> prependKey "history-query.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  HistoryQueryServerEvent sel -> prependKey "history-query.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  HistorySyncClientEvent sel -> prependKey "history-sync.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  HistorySyncServerEvent sel -> prependKey "history-sync.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  TxJobClientEvent sel -> prependKey "tx-job.client" $ getConnectSocketDriverSelectorConfig socketDriverConfig sel
  TxJobServerEvent sel -> prependKey "tx-job.server" $ getAcceptSocketDriverSelectorConfig socketDriverConfig sel
  TxEvent sel -> prependKey "marlowe-tx" $ getTransactionSererSelectorConfig sel
  ChainIndexerEvent sel -> prependKey "marlowe-chain-indexer" $ getChainIndexerSelectorConfig sel
  ConfigWatcher ReloadConfig -> SelectorConfig "reload-log-config" True
    $ singletonFieldConfig "config" True

socketDriverConfig :: SocketDriverConfigOptions
socketDriverConfig = SocketDriverConfigOptions
  { enableConnected = True
  , enableDisconnected = True
  , enableServerDriverEvent = True
  }
