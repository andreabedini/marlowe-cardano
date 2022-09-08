-----------------------------------------------------------------------------
--
-- Module      :  $Headers
-- License     :  Apache 2.0
--
-- Stability   :  Experimental
-- Portability :  Portable
--
-- | Types for testing Marlowe contracts.
--
-----------------------------------------------------------------------------


{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE ViewPatterns               #-}


module Language.Marlowe.CLI.Test.Types (
  AnyMarloweThread
, ContractNickname(..)
, ContractSource(..)
, CustomCurrency(..)
, CurrencyNickname(..)
, Finished
, MarloweContract(..)
, MarloweTests(..)
, MarloweThread(..)
, PartyRef(..)
, Running
, ScriptTest(..)
, ScriptOperation(..)
, ScriptState
, ScriptEnv(..)
, AUTxO(..)
, TokenAssignment(..)
, TokenName(..)
, UseTemplate(..)
, Wallet(..)
, WalletNickname(..)
, WalletTransaction(..)
, anyMarloweThread
, faucetNickname
, foldlMarloweThread
, foldrMarloweThread
, fromUTxO
, getMarloweThreadTransaction
, getMarloweThreadTxIn
, overAnyMarloweThread
, scriptState
, walletPubKeyHash
, seConnection
, seSlotConfig
, seCostModelParams
, seEra
, ssContracts
, ssCurrencies
, ssWallets
, toUTxO
) where


import Cardano.Api (AddressInEra, CardanoMode, Key (VerificationKey), LocalNodeConnectInfo, Lovelace, NetworkId,
                    PaymentKey, PolicyId, ScriptDataSupportedInEra, TxBody)
import qualified Cardano.Api as C
import Control.Lens (Lens')
import Control.Lens.Lens (lens)
import Data.Aeson (FromJSON (..), ToJSON (..), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as List
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.String (IsString (fromString))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GHC.Generics (Generic)
import Language.Marlowe.CLI.Types (AnyTimeout, MarloweTransaction (MarloweTransaction, mtInputs), SomePaymentSigningKey)
import qualified Language.Marlowe.Core.V1.Semantics.Types as M
import qualified Language.Marlowe.Extended.V1 as E
import Ledger.Orphans ()
import qualified Ledger.Tx.CardanoAPI as L
import Plutus.V1.Ledger.Api (CostModelParams, CurrencySymbol, TokenName)
import Plutus.V1.Ledger.SlotConfig (SlotConfig)
import qualified Plutus.V1.Ledger.Value as P
import qualified Plutus.V2.Ledger.Api as P


-- | Configuration for a set of Marlowe tests.
data MarloweTests era a =
    -- | Test contracts on-chain.
    ScriptTests
    {
      network              :: NetworkId   -- ^ The network ID, if any.
    , socketPath           :: FilePath    -- ^ The path to the node socket.
    , faucetSigningKeyFile :: FilePath    -- ^ The file containing the faucet's signing key.
    , faucetAddress        :: AddressInEra era  -- ^ The faucet address.
    , burnAddress          :: AddressInEra era -- ^ The address to which to send unneeded native tokens.
    , tests                :: [a]         -- ^ Input for the tests.
    }
    deriving stock (Eq, Generic, Show)


-- | An on-chain test of the Marlowe contract and payout validators.
data ScriptTest =
  ScriptTest
  {
    stTestName         :: String             -- ^ The name of the test.
  -- , stSlotLength       :: Integer            -- ^ The slot length, in milliseconds.
  -- , stSlotZeroOffset   :: Integer            -- ^ The effective POSIX time of slot zero, in milliseconds.
  -- , stInitialContract  :: Contract           -- ^ The contract.
  -- , stInitialState     :: State              -- ^ The the contract's initial state.
  , stScriptOperations :: [ScriptOperation]  -- ^ The sequence of test operations.
  }
    deriving stock (Eq, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)


data ContractSource = InlineContract A.Value | UseTemplate UseTemplate
    deriving stock (Eq, Generic, Show)


instance ToJSON ContractSource where
    toJSON (InlineContract c)            = Aeson.object [("inline", toJSON c)]
    toJSON (UseTemplate templateCommand) = Aeson.object [("template", toJSON templateCommand)]


instance FromJSON ContractSource where
    parseJSON json = case json of
      Aeson.Object (KeyMap.toList -> [("inline", contractJson)]) -> do
        parsedContract <- parseJSON contractJson
        pure $ InlineContract parsedContract
      Aeson.Object (KeyMap.toList -> [("template", templateCommandJson)]) -> do
        parsedTemplateCommand <- parseJSON templateCommandJson
        pure $ UseTemplate parsedTemplateCommand
      _ -> fail "Expected object with a single field of either `inline` or `template`"


newtype CurrencyNickname = CurrencyNickname String
    deriving stock (Eq, Ord, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)
instance IsString CurrencyNickname where fromString = CurrencyNickname


data TokenAssignment = TokenAssignment
  { taAmount         :: Integer
  , taTokenName      :: TokenName
  , taWalletNickname :: Maybe WalletNickname  -- ^ Default to the same wallet nickname as a token name.
  }
  deriving stock (Eq, Generic, Show)
  -- TODO: provide more concise encoding:
  -- - "Alice" or
  -- - roleName: "Alice"
  --   walletNickname: "TestWallet"
  --      -- ^ Amount defaults to 1 during role minting.
  deriving anyclass (FromJSON, ToJSON)


-- | On-chain test operations for the Marlowe contract and payout validators.
data ScriptOperation =
    Mint
    {
      soCurrencyNickname  :: CurrencyNickname
    , soIssuer            :: Maybe WalletNickname   -- ^ Fallbacks to faucet
    , soMetadata          :: Maybe Aeson.Object
    , soTokenDistribution :: [TokenAssignment]
    }
  | Initialize
    {
      soMinAda           :: Integer
    , soContractNickname :: ContractNickname   -- ^ The name of the wallet's owner.
    , soRoleCurrency     :: Maybe CurrencyNickname
    , soContractSource   :: ContractSource     -- ^ The Marlowe contract to be created.
    -- | FIXME: No *JSON instances for this
    -- , soStake :: Maybe StakeAddressReference
    }
  | Prepare
    {
      soContractNickname :: ContractNickname   -- ^ The name of the wallet's owner.
    , soInputs           :: [A.Value]
    , soMinimumTime      :: AnyTimeout
    , soMaximumTime      :: AnyTimeout
    }
  | AutoRun
    {
      soContractNickname :: ContractNickname
    , soSubmitter        :: Maybe WalletNickname   -- ^ By default we use role token owner or faucet to perform notification.
    }
  | CreateWallet
    {
      soWalletNickname :: WalletNickname
    }
  | FundWallet
    {
      soWalletNickname   :: WalletNickname
    , soValue            :: Lovelace
    , soCreateCollateral :: Maybe Bool
    }
  | Fail
    {
      soFailureMessage :: String
    }
    deriving stock (Eq, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)


data WalletTransaction era = WalletTransaction
  {
    wtFees   :: Lovelace
  , wtTxBody :: TxBody era
  }
  deriving stock (Generic, Show)


data Wallet era =
  Wallet
  {
    waAddress         :: AddressInEra era
  , waSigningKey      :: SomePaymentSigningKey
  , waTokens          :: P.Value                      -- ^ Custom tokens cache which simplifies
                                                      -- ^ autoexecution and swap transfers asserts.
  , waTransactions    :: [WalletTransaction era]
  , waVerificationKey :: VerificationKey PaymentKey
  }
  deriving stock (Generic, Show)


walletPubKeyHash :: Wallet era -> P.PubKeyHash
walletPubKeyHash Wallet { waVerificationKey } =
  L.fromCardanoPaymentKeyHash . C.verificationKeyHash $ waVerificationKey


-- | In many contexts this defaults to the `RoleName` but at some
-- | point we want to also support multiple marlowe contracts scenarios
-- | in a one transaction.
newtype WalletNickname = WalletNickname String
    deriving stock (Eq, Ord, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)

instance IsString WalletNickname where fromString = WalletNickname


-- | We encode `PartyRef` as `Party` so we can use role based contracts
-- | without any change in the JSON structure.
-- | In the case of the `PubKeyHash` you should use standard encoding but
-- | reference a wallet instead of providing hash value:
-- | ```
-- |  "pk_hash": "Wallet-1"
-- | ```
data PartyRef =
    WalletRef WalletNickname
  | RoleRef TokenName
  deriving stock (Eq, Generic, Show)


instance FromJSON PartyRef where
  parseJSON = \case
    Aeson.Object (KeyMap.toList -> [("pk_hash", A.String walletNickname)]) ->
      pure . WalletRef . WalletNickname . T.unpack $ walletNickname
    Aeson.Object (KeyMap.toList -> [("role_token", A.String roleToken)]) ->
      pure . RoleRef . P.tokenName . T.encodeUtf8 $ roleToken
    _ -> fail "Expecting a Party object."


instance ToJSON PartyRef where
    toJSON (WalletRef (WalletNickname walletNickname)) = A.object
        [ "pk_hash" .= A.String (T.pack walletNickname) ]
    toJSON (RoleRef (P.TokenName name)) = A.object
        [ "role_token" .= (A.String $ T.decodeUtf8 $ P.fromBuiltin name) ]


data UseTemplate =
    UseTrivial
    {
      utBystander          :: Maybe WalletNickname        -- ^ The party providing the min-ADA. Falls back to the faucet wallet.
    , utParty              :: Maybe PartyRef              -- ^ The party. Falls back to the faucet wallet pkh.
    , utDepositLovelace    :: Integer                     -- ^ Lovelace in the deposit.
    , utWithdrawalLovelace :: Integer                     -- ^ Lovelace in the withdrawal.
    , utTimeout            :: AnyTimeout                  -- ^ The timeout.
    }
    -- | Use for escrow contract.
  | UseEscrow
    {
      utPrice             :: Lovelace    -- ^ Price of the item for sale, in lovelace.
    , utSeller            :: PartyRef   -- ^ Defaults to a wallet with the "Buyer" nickname.
    , utBuyer             :: PartyRef    -- ^ Defaults to a wallet with the "Seller" ncikname.
    , utMediator          :: PartyRef   -- ^ The mediator.
    , utPaymentDeadline   :: AnyTimeout -- ^ The deadline for the buyer to pay.
    , utComplaintDeadline :: AnyTimeout -- ^ The deadline for the buyer to complain.
    , utDisputeDeadline   :: AnyTimeout -- ^ The deadline for the seller to dispute a complaint.
    , utMediationDeadline :: AnyTimeout -- ^ The deadline for the mediator to decide.
    }
    -- | Use for swap contract.
  | UseSwap
    {
      utAParty   :: PartyRef    -- ^ First party.
    , utAToken   :: E.Token      -- ^ First party's token.
    , utAAmount  :: Integer    -- ^ Amount of first party's token.
    , utATimeout :: AnyTimeout -- ^ Timeout for first party's deposit.
    , utBParty   :: PartyRef    -- ^ Second party.
    , utBToken   :: E.Token      -- ^ Second party's token.
    , utBAmount  :: Integer    -- ^ Amount of second party's token.
    , utBTimeout :: AnyTimeout -- ^ Timeout for second party's deposit.
    }
    -- | Use for zero-coupon bond.
  | UseZeroCouponBond
    {
      utLender          :: PartyRef    -- ^ The lender.
    , utBorrower        :: PartyRef    -- ^ The borrower.
    , utPrincipal       :: Integer    -- ^ The principal.
    , utInterest        :: Integer    -- ^ The interest.
    , utLendingDeadline :: AnyTimeout -- ^ The lending deadline.
    , utPaybackDeadline :: AnyTimeout -- ^ The payback deadline.
    }
    -- | Use for covered call.
  | UseCoveredCall
    {
      utIssuer         :: PartyRef  -- ^ The issuer.
    , utCounterparty   :: PartyRef  -- ^ The counter-party.
    , utCurrency       :: E.Token    -- ^ The currency token.
    , utUnderlying     :: E.Token    -- ^ The underlying token.
    , utStrike         :: Integer    -- ^ The strike in currency.
    , utAmount         :: Integer    -- ^ The amount of underlying.
    , utIssueDate      :: AnyTimeout -- ^ The issue date.
    , utMaturityDate   :: AnyTimeout -- ^ The maturity date.
    , utSettlementDate :: AnyTimeout -- ^ The settlement date.
    }
    -- | Use for actus contracts.
  | UseActus
    {
      utParty          :: Maybe PartyRef   -- ^ The party. Fallsback to the faucet wallet.
    , utCounterparty   :: PartyRef         -- ^ The counter-party.
    , utActusTermsFile :: FilePath         -- ^ The Actus contract terms.
    }
    deriving stock (Eq, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)


newtype ContractNickname = ContractNickname String
    deriving stock (Eq, Ord, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)
instance IsString ContractNickname where fromString = ContractNickname


data Running

data Finished

data MarloweThread era status where
  Created :: MarloweTransaction era
          -> C.TxBody era
          -> C.TxIn
          -> MarloweThread era Running
  InputsApplied :: MarloweTransaction era
                -> C.TxBody era
                -> C.TxIn
                -> List.NonEmpty M.Input
                -> MarloweThread era Running
                -> MarloweThread era Running
  Closed :: MarloweTransaction era
         -> C.TxBody era
         -> [M.Input]
         -> MarloweThread era Running
         -> MarloweThread era Finished


foldlMarloweThread :: (forall status'. b -> MarloweThread era status' -> b) -> b -> MarloweThread era status -> b
foldlMarloweThread step acc m@(Closed _ _ _ th)          = foldlMarloweThread step (step acc m) th
foldlMarloweThread step acc m@(InputsApplied _ _ _ _ th) = foldlMarloweThread step (step acc m) th
foldlMarloweThread step acc m                            = step acc m


foldrMarloweThread :: (forall status'. MarloweThread era status' -> b -> b) -> b -> MarloweThread era status -> b
foldrMarloweThread step acc m@(Closed _ _ _ th)          = step m (foldrMarloweThread step acc th)
foldrMarloweThread step acc m@(InputsApplied _ _ _ _ th) = step m (foldrMarloweThread step acc th)
foldrMarloweThread step acc m                            = step m acc


getMarloweThreadTransaction :: MarloweThread era status -> MarloweTransaction era
getMarloweThreadTransaction (Created mt _ _)           = mt
getMarloweThreadTransaction (InputsApplied mt _ _ _ _) = mt
getMarloweThreadTransaction (Closed mt _ _ _)          = mt

getMarloweThreadTxIn :: MarloweThread era status -> Maybe C.TxIn
getMarloweThreadTxIn (Created _ _ txIn)           = Just txIn
getMarloweThreadTxIn (InputsApplied _ _ txIn _ _) = Just txIn
getMarloweThreadTxIn Closed {}                    = Nothing


data AnyMarloweThread era where
  AnyMarloweThread :: MarloweThread era status -> AnyMarloweThread era


anyMarloweThread :: MarloweTransaction era -> C.TxBody era -> Maybe C.TxIn -> Maybe (AnyMarloweThread era) -> Maybe (AnyMarloweThread era)
anyMarloweThread mt@MarloweTransaction{..} txBody mTxIn mth = case (mTxIn, mtInputs, mth) of
  (Just txIn, [], Nothing) -> Just (AnyMarloweThread (Created mt txBody txIn))

  (Just txIn, input:inputs, Just (AnyMarloweThread th)) -> case th of
    m@Created {}       -> Just $ AnyMarloweThread $ InputsApplied mt txBody txIn (input :| inputs) m
    m@InputsApplied {} -> Just $ AnyMarloweThread $ InputsApplied mt txBody txIn (input :| inputs) m
    _                  -> Nothing

  (Nothing, inputs, Just (AnyMarloweThread th)) -> case th of
    m@Created {}       -> Just $ AnyMarloweThread $ Closed mt txBody inputs m
    m@InputsApplied {} -> Just $ AnyMarloweThread $ Closed mt txBody inputs m
    _                  -> Nothing

  -- Inputs are not allowed in the initial transaction.
  (Just _, _:_, Nothing) -> Nothing
  -- Auto application should not be possible becaue contract on chain is quiescent.
  (Just _, [], Just _) -> Nothing
  -- It is impossible to deploy anything without marlowe output.
  (Nothing, _, Nothing) -> Nothing


overAnyMarloweThread :: forall a era. (forall status'. MarloweThread era status' -> a) -> AnyMarloweThread era -> a
overAnyMarloweThread f (AnyMarloweThread th) = f th


data MarloweContract era = MarloweContract
  {
    mcContract :: M.Contract
  , mcCurrency :: Maybe CurrencyNickname
  -- , mcCurr     :: PossiblyOnChainMarloweTransaction era
  -- , mcPrev       :: Maybe (PossiblyOnChainMarloweTransaction era)
  , mcPlan     :: List.NonEmpty (MarloweTransaction era)
  , mcThread   :: Maybe (AnyMarloweThread era)
  }

data CustomCurrency = CustomCurrency
  {
    ccPolicyId       :: PolicyId
  , ccCurrencySymbol :: CurrencySymbol
  }


data ScriptState era = ScriptState
  {
    _ssContracts  :: Map ContractNickname (MarloweContract era)
  , _ssCurrencies :: Map CurrencyNickname CustomCurrency
  , _ssWallets    :: Map WalletNickname (Wallet era)               -- ^ Faucet wallet should be included here.
  }


faucetNickname :: WalletNickname
faucetNickname = "Faucet"


scriptState :: Wallet era -> ScriptState era
scriptState faucet = do
  let
    wallets = Map.singleton faucetNickname faucet
  ScriptState mempty mempty wallets


newtype AUTxO era = AUTxO { unAUTxO :: (C.TxIn, C.TxOut C.CtxUTxO era) }

fromUTxO :: C.UTxO era -> [AUTxO era]
fromUTxO (Map.toList . C.unUTxO -> items) = map AUTxO items


toUTxO :: [AUTxO era] -> C.UTxO era
toUTxO (map unAUTxO -> utxos) = C.UTxO . Map.fromList $ utxos


data ScriptEnv era = ScriptEnv
  { _seConnection      :: LocalNodeConnectInfo CardanoMode
  , _seCostModelParams :: CostModelParams
  , _seEra             :: ScriptDataSupportedInEra era
  , _seSlotConfig      :: SlotConfig
  }



ssContracts :: Lens' (ScriptState era) (Map ContractNickname (MarloweContract era))
ssContracts = lens _ssContracts (\se v -> se { _ssContracts = v })


ssCurrencies :: Lens' (ScriptState era) (Map CurrencyNickname CustomCurrency)
ssCurrencies = lens _ssCurrencies (\se v -> se { _ssCurrencies = v })


ssWallets :: Lens' (ScriptState era) (Map WalletNickname (Wallet era))
ssWallets = lens _ssWallets (\se v -> se { _ssWallets = v })


seConnection :: Lens' (ScriptEnv era) (LocalNodeConnectInfo CardanoMode)
seConnection = lens _seConnection (\se v -> se { _seConnection = v })


seSlotConfig :: Lens' (ScriptEnv era) SlotConfig
seSlotConfig = lens _seSlotConfig (\se v -> se { _seSlotConfig = v })


seCostModelParams :: Lens' (ScriptEnv era) CostModelParams
seCostModelParams = lens _seCostModelParams (\se v -> se { _seCostModelParams = v })


seEra :: Lens' (ScriptEnv era) (ScriptDataSupportedInEra era)
seEra = lens _seEra (\se v -> se { _seEra = v })


