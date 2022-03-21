module Capability.Marlowe
  ( class ManageMarlowe
  , initializeContract
  , applyTransactionInput
  , redeem
  ) where

import Prologue

import AppM (AppM)
import Capability.PlutusApps.MarloweApp (applyInputs, createContract, redeem) as MarloweApp
import Capability.Toast (addToast)
import Capability.Wallet (class ManageWallet)
import Component.ContractSetup.Types (ContractParams)
import Component.Template.State
  ( InstantiateContractErrorRow
  , instantiateExtendedContract
  )
import Control.Monad.Error.Class (class MonadError, throwError)
import Control.Monad.Except (ExceptT(..), lift, runExceptT, withExceptT)
import Control.Monad.Maybe.Trans (MaybeT)
import Control.Monad.Reader (ReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.UUID (class MonadUUID)
import Data.DateTime.Instant (Instant)
import Data.Lens (view)
import Data.NewContract (NewContract(..))
import Data.PABConnectedWallet (PABConnectedWallet, _address, _marloweAppId)
import Data.Tuple.Nested (type (/\), (/\))
import Data.Variant (Variant)
import Data.Variant.Generic (class Constructors, mkConstructors')
import Effect.Aff (Aff, Error, error)
import Effect.Aff.Unlift (class MonadUnliftAff, askUnliftAff, unliftAff)
import Halogen (HalogenM)
import Halogen.Store.Monad (updateStore)
import Language.Marlowe.Client.Error (showContractError)
import Marlowe.Extended.Metadata (ContractTemplate)
import Marlowe.Run.Server (Api) as MarloweApp
import Marlowe.Semantics (MarloweParams, TokenName, TransactionInput)
import Plutus.PAB.Webserver (Api) as PAB
import Servant.PureScript (class MonadAjax)
import Store as Store
import Toast.Types (errorToast)
import Type.Proxy (Proxy(..))
import Type.Row (type (+))
import Types (AjaxResponse, JsonAjaxErrorRow)

type InitializeContractError = Variant
  (JsonAjaxErrorRow + InstantiateContractErrorRow + ())

initializeContractError
  :: forall c. Constructors InitializeContractError c => c
initializeContractError = mkConstructors'
  (Proxy :: Proxy InitializeContractError)

-- The `ManageMarlowe` class provides a window on the `ManagePAB` and `ManageWallet`
-- capabilities with functions specific to Marlowe.
class
  ManageWallet m <=
  ManageMarlowe m where
  initializeContract
    :: Instant
    -> ContractTemplate
    -> ContractParams
    -> PABConnectedWallet
    -> m (Either InitializeContractError (NewContract /\ Aff MarloweParams))
  applyTransactionInput
    :: PABConnectedWallet
    -> MarloweParams
    -> TransactionInput
    -> m (AjaxResponse (Aff Unit))
  redeem
    :: PABConnectedWallet
    -> MarloweParams
    -> TokenName
    -> m (AjaxResponse (Aff Unit))

instance
  ( MonadUnliftAff m
  , MonadError Error m
  , MonadRec m
  , MonadAjax PAB.Api m
  , MonadAjax MarloweApp.Api m
  , MonadUUID m
  ) =>
  ManageMarlowe (AppM m) where

  initializeContract currentInstant template params wallet = do
    u <- askUnliftAff
    runExceptT do
      let
        { instantiateContractError, jsonAjaxError } = initializeContractError
        { nickname, roles } = params
        marloweAppId = view _marloweAppId wallet
      -- To initialize a Marlowe Contract we first need to make an instance
      -- of a Core.Marlowe contract. We do this by replazing template parameters
      -- from the Extended.Marlowe template and then calling toCore. This can
      -- fail with `instantiateContractError` if not all params were provided.
      contract <-
        withExceptT instantiateContractError
          $ ExceptT
          $ pure
          $ instantiateExtendedContract currentInstant template params
      -- Call the PAB to create the new contract. It returns a request id and a function
      -- that we can use to block and wait for the response
      reqId /\ awaitContractCreation <-
        withExceptT jsonAjaxError $ ExceptT $
          MarloweApp.createContract marloweAppId roles contract

      -- We save in the store the request of a created contract with
      -- the information relevant to show a placeholder of a starting contract.
      let newContract = NewContract reqId nickname template.metaData
      lift $ updateStore $ Store.ContractCreated newContract

      pure $ newContract /\ do
        mParams <- awaitContractCreation
        case mParams of
          Left contractError -> do
            unliftAff u
              $ addToast
              $ errorToast "Failed to create contract"
              $ Just
              $ showContractError contractError
            throwError $ error $ "Failed to create contract: " <>
              showContractError contractError
          Right marloweParams -> do
            -- Update the contract's representation in the store to use its
            -- MarloweParams instead of the temporary UUID
            unliftAff u
              $ updateStore
              $ Store.ContractStarted newContract marloweParams
            pure marloweParams

  -- "apply-inputs" to a Marlowe contract on the blockchain
  applyTransactionInput wallet marloweParams transactionInput = do
    u <- askUnliftAff
    runExceptT do
      let marloweAppId = view _marloweAppId wallet
      awaitResult <- ExceptT
        $ MarloweApp.applyInputs marloweAppId marloweParams transactionInput
      pure do
        mUnit <- awaitResult
        case mUnit of
          Left contractError -> do
            unliftAff u
              $ addToast
              $ errorToast "Failed to update contract"
              $ Just
              $ showContractError contractError
            throwError $ error $ "Failed to update contract: " <>
              showContractError contractError
          Right _ -> pure unit

  -- "redeem" payments from a Marlowe contract on the blockchain
  redeem wallet marloweParams tokenName = do
    u <- askUnliftAff
    runExceptT do
      let marloweAppId = view _marloweAppId wallet
      let address = view _address wallet
      awaitResult <- ExceptT
        $ MarloweApp.redeem marloweAppId marloweParams tokenName address
      pure do
        mUnit <- awaitResult
        case mUnit of
          Left contractError -> do
            unliftAff u
              $ addToast
              $ errorToast "Failed to redeem payment"
              $ Just
              $ showContractError contractError
            throwError $ error $ "Failed to redeem payment: " <>
              showContractError contractError
          Right _ -> pure unit

instance ManageMarlowe m => ManageMarlowe (HalogenM state action slots msg m) where
  initializeContract currentInstant template params wallet =
    lift $ initializeContract currentInstant template params wallet
  applyTransactionInput walletDetails marloweParams transactionInput =
    lift $ applyTransactionInput walletDetails marloweParams transactionInput
  redeem walletDetails marloweParams tokenName =
    lift $ redeem walletDetails marloweParams tokenName

instance ManageMarlowe m => ManageMarlowe (MaybeT m) where
  initializeContract currentInstant template params wallet =
    lift $ initializeContract currentInstant template params wallet
  applyTransactionInput walletDetails marloweParams transactionInput =
    lift $ applyTransactionInput walletDetails marloweParams transactionInput
  redeem walletDetails marloweParams tokenName =
    lift $ redeem walletDetails marloweParams tokenName

instance ManageMarlowe m => ManageMarlowe (ReaderT r m) where
  initializeContract currentInstant template params wallet =
    lift $ initializeContract currentInstant template params wallet
  applyTransactionInput walletDetails marloweParams transactionInput =
    lift $ applyTransactionInput walletDetails marloweParams transactionInput
  redeem walletDetails marloweParams tokenName =
    lift $ redeem walletDetails marloweParams tokenName
