{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}

module Language.Marlowe.Runtime.Transaction.Server
  where

import Cardano.Api
  ( AddressInEra(..)
  , AddressTypeInEra(..)
  , NetworkId
  , PaymentCredential(..)
  , ScriptDataSupportedInEra(..)
  , SerialiseAsRawBytes(..)
  , ShelleyBasedEra(..)
  , StakeAddressReference(..)
  , StakeCredential
  , Tx
  , TxBody(..)
  , TxBodyContent(..)
  , TxOut(..)
  , getTxBody
  , getTxId
  , makeShelleyAddress
  )
import qualified Cardano.Api as C
import Cardano.Api.Shelley (StakeCredential(..))
import Control.Applicative ((<|>))
import Control.Concurrent (forkFinally)
import Control.Concurrent.Async (Concurrently(..))
import Control.Concurrent.STM (STM, atomically, modifyTVar, newEmptyTMVar, newTVar, putTMVar, readTMVar, readTVar)
import Control.Exception (SomeException, catch)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT(..), except, runExceptT, withExceptT)
import qualified Data.Aeson as Aeson
import Data.Bifunctor (first)
import Data.List (find)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.Time (UTCTime)
import Data.Void (Void)
import Language.Marlowe.Runtime.ChainSync.Api (Address, BlockHeader, ScriptHash(..), SlotConfig, TokenName, TxId(..))
import qualified Language.Marlowe.Runtime.ChainSync.Api as Chain
import Language.Marlowe.Runtime.Core.Api (Contract, ContractId(..), MarloweVersion, PayoutDatum, Redeemer)
import Language.Marlowe.Runtime.Core.ScriptRegistry (getCurrentScripts, marloweScript)
import Language.Marlowe.Runtime.Transaction.Api
  ( ApplyInputsError(..)
  , CreateError(..)
  , JobId(..)
  , MarloweTxCommand(..)
  , SubmitError(..)
  , SubmitStatus(..)
  , WalletAddresses(..)
  , WithdrawError(..)
  )
import Language.Marlowe.Runtime.Transaction.BuildConstraints
  (buildApplyInputsConstraints, buildCreateConstraints, buildWithdrawConstraints)
import Language.Marlowe.Runtime.Transaction.Constraints (MarloweContext(..), SolveConstraints)
import Language.Marlowe.Runtime.Transaction.Query (LoadMarloweContext, LoadWalletContext)
import Language.Marlowe.Runtime.Transaction.Submit (SubmitJob(..), SubmitJobStatus(..))
import Network.Protocol.Job.Server
  (JobServer(..), ServerStAttach(..), ServerStAwait(..), ServerStCmd(..), ServerStInit(..), hoistAttach, hoistCmd)
import System.IO (hPutStrLn, stderr)

newtype RunTransactionServer m = RunTransactionServer (forall a. JobServer MarloweTxCommand m a -> m a)

data TransactionServerDependencies = TransactionServerDependencies
  { acceptRunTransactionServer :: IO (RunTransactionServer IO)
  , mkSubmitJob :: forall era. ScriptDataSupportedInEra era -> Tx era -> STM SubmitJob
  , solveConstraints :: forall era v. SolveConstraints era v
  , loadWalletContext :: LoadWalletContext
  , loadMarloweContext :: LoadMarloweContext
  , slotConfig :: SlotConfig
  , networkId :: NetworkId
  }

newtype TransactionServer = TransactionServer
  { runTransactionServer :: IO ()
  }

mkTransactionServer :: TransactionServerDependencies -> STM TransactionServer
mkTransactionServer TransactionServerDependencies{..} = do
  submitJobsVar <- newTVar mempty
  let
    getSubmitJob txId = Map.lookup txId <$> readTVar submitJobsVar
    trackSubmitJob txId = modifyTVar submitJobsVar . Map.insert txId
    runTransactionServer = do
      runServer <- acceptRunTransactionServer
      Worker{..} <- atomically $ mkWorker WorkerDependencies {..}
      runConcurrently $
        Concurrently (runWorker `catch` catchWorker) *> Concurrently runTransactionServer
  pure $ TransactionServer { runTransactionServer }

catchWorker :: SomeException -> IO ()
catchWorker = hPutStrLn stderr . ("Job worker crashed with exception: " <>) . show

data WorkerDependencies = WorkerDependencies
  { runServer :: RunTransactionServer IO
  , getSubmitJob :: TxId -> STM (Maybe SubmitJob)
  , trackSubmitJob :: TxId -> SubmitJob -> STM ()
  , mkSubmitJob :: forall era. ScriptDataSupportedInEra era -> Tx era -> STM SubmitJob
  , solveConstraints :: forall era v. SolveConstraints era v
  , loadWalletContext :: LoadWalletContext
  , loadMarloweContext :: LoadMarloweContext
  , slotConfig :: SlotConfig
  , networkId :: NetworkId
  }

newtype Worker = Worker
  { runWorker :: IO ()
  }

mkWorker :: WorkerDependencies -> STM Worker
mkWorker WorkerDependencies{..} =
  let
    RunTransactionServer run = runServer
  in
    pure Worker { runWorker = run server }

  where
    server :: JobServer MarloweTxCommand IO ()
    server = JobServer $ pure serverInit

    serverInit :: ServerStInit MarloweTxCommand IO ()
    serverInit = ServerStInit
      { recvMsgExec = \case
          Create era mStakeCredential version addresses roles metadata contract ->
            execCreate
              solveConstraints
              loadWalletContext
              networkId
              era
              mStakeCredential
              version
              addresses
              roles
              metadata
              contract
          ApplyInputs era version addresses contractId invalidBefore invalidHereafter redeemer ->
            execApplyInputs
              slotConfig
              solveConstraints
              loadWalletContext
              loadMarloweContext
              era
              version
              addresses
              contractId
              invalidBefore
              invalidHereafter
              redeemer
          Withdraw era version addresses contractId payoutDatum ->
            execWithdraw
              solveConstraints
              loadWalletContext
              loadMarloweContext
              era
              version
              addresses
              contractId
              payoutDatum
          Submit era tx ->
            execSubmit mkSubmitJob trackSubmitJob era tx
      , recvMsgAttach = \case
          jobId@(JobIdSubmit _ txId) ->
            attachSubmit jobId $ getSubmitJob txId
      }

attachSubmit
  :: JobId MarloweTxCommand SubmitStatus SubmitError BlockHeader
  -> STM (Maybe SubmitJob)
  -> IO (ServerStAttach MarloweTxCommand SubmitStatus SubmitError BlockHeader IO ())
attachSubmit jobId getSubmitJob =
  atomically $ fmap (hoistAttach atomically) <$> submitJobServerAttach jobId =<< getSubmitJob

execCreate
  :: SolveConstraints era v
  -> LoadWalletContext
  -> NetworkId
  -> ScriptDataSupportedInEra era
  -> Maybe StakeCredential
  -> MarloweVersion v
  -> WalletAddresses
  -> Map TokenName Address
  -> Map Int Aeson.Value
  -> Contract v
  -> IO (ServerStCmd MarloweTxCommand Void CreateError (ContractId, TxBody era) IO ())
execCreate solveConstraints loadWalletContext networkId era mStakeCredential version addresses roleTokens metadata contract = execExceptT do
  constraints <- except $ buildCreateConstraints version roleTokens metadata contract
  walletContext <- lift $ loadWalletContext addresses
  -- The marlowe context for a create transaction has no marlowe output and
  -- an empty payout output set. It may specify a stake credential to use.
  let marloweContext = MarloweContext (fromCardanoStakeCredential <$> mStakeCredential) Nothing mempty
  txBody <- except
    $ first CreateUnsolvableConstraints
    $ solveConstraints era marloweContext walletContext constraints
  pure (ContractId $ findMarloweOutput txBody, txBody)
  where
  findMarloweOutput = \case
    body@(TxBody TxBodyContent{..}) -> Chain.TxOutRef (Chain.TxId $ serialiseToRawBytes $ getTxId body)
      $ fst
      $ fromJust
      $ find (isToCurrentScriptAddress . snd)
      $ zip [0..] txOuts
    where
      scriptHash = fromJust
        $ deserialiseFromRawBytes C.AsScriptHash
        $ unScriptHash
        $ marloweScript
        $ getCurrentScripts version
      scriptAddress = makeShelleyAddress networkId (PaymentCredentialByScript scriptHash)
        $ maybe NoStakeAddress StakeAddressByValue mStakeCredential
      isToCurrentScriptAddress = case era of
        ScriptDataInAlonzoEra -> \(TxOut address _ _ _) -> address == AddressInEra (ShelleyAddressInEra ShelleyBasedEraAlonzo) scriptAddress
        ScriptDataInBabbageEra -> \(TxOut address _ _ _) -> address == AddressInEra (ShelleyAddressInEra ShelleyBasedEraBabbage) scriptAddress

fromCardanoStakeCredential :: StakeCredential -> Chain.Credential
fromCardanoStakeCredential = \case
  StakeCredentialByKey pkh -> Chain.PaymentKeyCredential $ Chain.PaymentKeyHash $ serialiseToRawBytes pkh
  StakeCredentialByScript sh -> Chain.ScriptCredential $ Chain.ScriptHash $ serialiseToRawBytes sh

execApplyInputs
  :: SlotConfig
  -> SolveConstraints era v
  -> LoadWalletContext
  -> LoadMarloweContext
  -> ScriptDataSupportedInEra era
  -> MarloweVersion v
  -> WalletAddresses
  -> ContractId
  -> Maybe UTCTime
  -> Maybe UTCTime
  -> Redeemer v
  -> IO (ServerStCmd MarloweTxCommand Void ApplyInputsError (TxBody era) IO ())
execApplyInputs
  slotConfig
  solveConstraints
  loadWalletContext
  loadMarloweContext
  era
  version
  addresses
  contractId
  invalidBefore
  invalidHereafter
  inputs = execExceptT do
    marloweContext@MarloweContext{..} <- withExceptT ApplyInputsLoadMarloweContextFailed
      $ ExceptT
      $ loadMarloweContext version contractId
    scriptOutput' <- except $ maybe (Left ScriptOutputNotFound) Right scriptOutput
    constraints <- except $ buildApplyInputsConstraints
        slotConfig
        version
        scriptOutput'
        invalidBefore
        invalidHereafter
        inputs
    walletContext <- lift $ loadWalletContext addresses
    except
      $ first ApplyInputsUnsolvableConstraints
      $ solveConstraints era marloweContext walletContext constraints

execWithdraw
  :: SolveConstraints era v
  -> LoadWalletContext
  -> LoadMarloweContext
  -> ScriptDataSupportedInEra era
  -> MarloweVersion v
  -> WalletAddresses
  -> ContractId
  -> PayoutDatum v
  -> IO (ServerStCmd MarloweTxCommand Void WithdrawError (TxBody era) IO ())
execWithdraw solveConstraints loadWalletContext loadMarloweContext era version addresses contractId datum = execExceptT do
  constraints <- except $ buildWithdrawConstraints version datum
  walletContext <- lift $ loadWalletContext addresses
  marloweContext <- withExceptT WithdrawLoadMarloweContextFailed
    $ ExceptT
    $ loadMarloweContext version contractId
  except
    $ first WithdrawUnsolvableConstraints
    $ solveConstraints era marloweContext walletContext constraints

execSubmit
  :: (ScriptDataSupportedInEra era -> Tx era -> STM SubmitJob)
  -> (TxId -> SubmitJob -> STM ())
  -> ScriptDataSupportedInEra era
  -> Tx era
  -> IO (ServerStCmd MarloweTxCommand SubmitStatus SubmitError BlockHeader IO ())
execSubmit mkSubmitJob trackSubmitJob era tx = do
  let txId = TxId $ serialiseToRawBytes $ getTxId $ getTxBody tx
  (submitJob, exVar) <- atomically do
    exVar <- newEmptyTMVar
    submitJob <- mkSubmitJob era tx
    let getExceptionStatus = Failed SubmitException <$ readTMVar exVar
    let submitJob' = submitJob { submitJobStatus = getExceptionStatus <|> submitJobStatus submitJob }
    trackSubmitJob txId submitJob'
    pure (submitJob', exVar)
  -- Run the job in a new thread
  _ <- forkFinally (runSubmitJob submitJob) \case
    Left ex -> atomically $ putTMVar exVar ex
    _ -> pure ()
  -- Make a new server and run it in IO.
  hoistCmd atomically <$> atomically (submitJobServerCmd (JobIdSubmit era txId) submitJob)

submitJobServerAttach
  :: JobId MarloweTxCommand SubmitStatus SubmitError BlockHeader
  -> Maybe SubmitJob
  -> STM (ServerStAttach MarloweTxCommand SubmitStatus SubmitError BlockHeader STM ())
submitJobServerAttach jobId = maybe
  (pure $ SendMsgAttachFailed ())
  (fmap SendMsgAttached . submitJobServerCmd jobId)

submitJobServerCmd
  :: JobId MarloweTxCommand SubmitStatus SubmitError BlockHeader
  -> SubmitJob
  -> STM (ServerStCmd MarloweTxCommand SubmitStatus SubmitError BlockHeader STM ())
submitJobServerCmd jobId submitJob = do
  jobStatus <- submitJobStatus submitJob
  pure case jobStatus of
    Running status -> SendMsgAwait status jobId ServerStAwait
      { recvMsgDetach = pure ()
      , recvMsgPoll = submitJobServerCmd jobId submitJob
      }
    Succeeded block -> SendMsgSucceed block ()
    Failed err -> SendMsgFail err ()

execExceptT
  :: Functor m
  => ExceptT e m a
  -> m (ServerStCmd cmd status e a m ())
execExceptT = fmap (either (flip SendMsgFail ()) (flip SendMsgSucceed ())) . runExceptT
