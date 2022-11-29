{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}

module Language.Marlowe.Runtime.CLI.Command.Apply
  where

import qualified Cardano.Api as C
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT(ExceptT), throwE)
import Data.Aeson (toJSON)
import qualified Data.Aeson as A
import Data.Bifunctor (Bifunctor(first))
import Data.ByteString (ByteString)
import qualified Data.Text as T
import Data.Time (UTCTime, secondsToNominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Language.Marlowe (POSIXTime(..))
import qualified Language.Marlowe.Core.V1.Semantics.Types as V1
import qualified Language.Marlowe.Core.V1.Semantics.Types.Address as V1
import Language.Marlowe.Runtime.CLI.Command.Tx (SigningMethod(Manual), TxCommand(..), txCommandParser)
import Language.Marlowe.Runtime.CLI.Monad (CLI, runCLIExceptT, runTxCommand)
import Language.Marlowe.Runtime.CLI.Option (txOutRefParser)
import Language.Marlowe.Runtime.ChainSync.Api (unPolicyId)
import Language.Marlowe.Runtime.Core.Api
  (ContractId(..), IsMarloweVersion(..), MarloweVersion(MarloweV1), MarloweVersionTag(..))
import Language.Marlowe.Runtime.Transaction.Api (ApplyInputsError, InputsApplied(..), MarloweTxCommand(ApplyInputs))
import qualified Language.Marlowe.Util as V1
import Options.Applicative
import qualified Plutus.V1.Ledger.Api as P

data ApplyCommand = V1ApplyCommand
  { contractId :: ContractId
  , inputs :: ContractInputs 'V1
  , validityLowerBound :: Maybe POSIXTime
  , validityUpperBound :: Maybe POSIXTime
  }

data ApplyCommandError v
  = ApplyFailed (ApplyInputsError v)
  | PlainInputsSupportedOnly (ContractInputs v)
  | TransactionFileWriteFailed (C.FileError ())

deriving instance Show (ApplyCommandError 'V1)

data ContractInputs v
  = ContractInputsByFile FilePath
  | ContractInputsByValue (Redeemer v)
  | ContractInputsByValueWithContinuations (Redeemer v) [FilePath]

deriving instance Show (ContractInputs 'V1)

applyCommandParser :: ParserInfo (TxCommand ApplyCommand)
applyCommandParser = info (txCommandParser parser) $ progDesc "Apply inputs to a contract"
  where
    parser = V1ApplyCommand
      <$> contractIdParser "which to apply the inputs"
      <*> (ContractInputsByFile <$> inputsFileParser)
      <*> validityLowerBoundParser
      <*> validityUpperBoundParser

    inputsFileParser = strOption $ mconcat
      [ long "inputs-file"
      , help "A file containing the Marlowe inputs to apply to the contract in JSON format."
      , metavar "FILE_PATH"
      ]

depositCommandParser :: ParserInfo (TxCommand ApplyCommand)
depositCommandParser = singleInputParser "deposit funds into" contentParser $ progDesc "Deposit funds into a contract"
  where
    contentParser = do
      accountId <- accountIdParser
      party <- senderPartyParser
      (token, quantity) <- tokenParser <|> lovelaceParser
      pure $ V1.IDeposit accountId party token quantity

    accountIdParser = partyParser $ mconcat
      [ long "to-party"
      , metavar "ROLE_NAME|ADDRESS"
      , help "The party into whose account to deposit the funds."
      ]
    senderPartyParser = partyParser $ mconcat
      [ long "from-party"
      , metavar "ROLE_NAME|ADDRESS"
      , help "The party depositing the funds."
      ]
    lovelaceParser = option ((V1.ada,) <$> auto) $ mconcat
      [ long "lovelace"
      , short 'l'
      , help "The quantity of lovelace to deposit."
      , metavar "INTEGER"
      ]
    tokenParser = (,) <$> (V1.Token <$> currencySymbolParser <*> tokenNameParser) <*> quantityParser
    currencySymbolParser = fmap (P.CurrencySymbol . P.toBuiltin . unPolicyId) $ strOption $ mconcat
      [ long "currency"
      , short 'c'
      , metavar "MINTING_POLICY_ID"
      , help "The minting policy ID of the token(s) to deposit."
      ]
    tokenNameParser = fmap (P.TokenName . P.toBuiltin @ByteString) $ strOption $ mconcat
      [ long "token-name"
      , short 'n'
      , metavar "TOKEN_NAME"
      , help "The name of the token(s) to deposit."
      ]
    quantityParser = option auto $ mconcat
      [ long "quantity"
      , short 'q'
      , metavar "INTEGER"
      , help "The quantity of tokens to deposit."
      ]

chooseCommandParser :: ParserInfo (TxCommand ApplyCommand)
chooseCommandParser = singleInputParser "make a choice in." contentParser $ progDesc "Notify a contract to proceed"
  where
    contentParser = do
      choiceId <- choiceIdParser
      chosenNum <- chosenNumParser
      pure $ V1.IChoice choiceId chosenNum
    choiceIdParser = V1.ChoiceId <$> choiceIdNameParser <*> choiceIdPartyParser
    choiceIdNameParser = strOption $ mconcat
      [ long "choice"
      , metavar "CHOICE_NAME"
      , help "The name of the choice being made."
      ]
    choiceIdPartyParser = partyParser $ mconcat
      [ long "party"
      , metavar "ROLE_NAME|ADDRESS"
      , help "Make the choice as the specified party."
      ]
    chosenNumParser = option auto $ mconcat
      [ long "value"
      , metavar "INTEGER"
      , help "The value being chosen."
      ]

notifyCommandParser :: ParserInfo (TxCommand ApplyCommand)
notifyCommandParser = singleInputParser "notify" (pure V1.INotify) $ progDesc "Notify a contract to proceed"

singleInputParser :: String -> Parser V1.InputContent -> InfoMod (TxCommand ApplyCommand) -> ParserInfo (TxCommand ApplyCommand)
singleInputParser verb contentParser = info (txCommandParser parser)
  where
    parser = V1ApplyCommand
      <$> contractIdParser verb
      <*> inputParser
      <*> validityLowerBoundParser
      <*> validityUpperBoundParser
    inputParser = do
      content <- V1.NormalInput <$> contentParser
      mContinuation <- optional continuationParser
      pure case mContinuation of
        Nothing -> ContractInputsByValue [content]
        Just continuationFile -> ContractInputsByValueWithContinuations [content] [continuationFile]
    continuationParser = strOption $ mconcat
      [ long "continuation-file"
      , help "A file containing the continuation contract JSON for making a choice in a Merkleized contract."
      , metavar "FILE_PATH"
      ]

advanceCommandParser :: ParserInfo (TxCommand ApplyCommand)
advanceCommandParser = info (txCommandParser parser) $ progDesc "Advance a timed-out contract by applying an empty set of inputs."
  where
    parser = V1ApplyCommand
      <$> contractIdParser "advance."
      <*> pure (ContractInputsByValue [])
      <*> validityLowerBoundParser
      <*> validityUpperBoundParser

contractIdParser :: String -> Parser ContractId
contractIdParser verb = option (ContractId <$> txOutRefParser) $ mconcat
  [ long "contract"
  , short 'c'
  , metavar "CONTRACT_ID"
  , help $ "The ID of the Marlowe contract to " <> verb
  ]

validityLowerBoundParser :: Parser (Maybe POSIXTime)
validityLowerBoundParser = optional $ option readPOSIXTime $ mconcat
  [ long "validity-lower-bound"
  , short 'l'
  , metavar "TIMESTAMP"
  , help "The lower bound of the transaction validity interval in POSIX milliseconds. If not specified, the current time (as determined by the Cardano node) will be used."
  ]

-- Read an integer number of milliseconds from the UNIX epoch
readPOSIXTime :: ReadM POSIXTime
readPOSIXTime = POSIXTime <$> auto

validityUpperBoundParser :: Parser (Maybe POSIXTime)
validityUpperBoundParser = optional $ option readPOSIXTime $ mconcat
  [ long "validity-upper-bound"
  , short 'u'
  , metavar "TIMESTAMP"
  , help "The upper bound of the transaction validity interval in POSIX milliseconds. If not specified, the next timeout in the contract will be used (bounded by the maximum value allowed by the Cardano node)."
  ]

partyParser :: Mod OptionFields V1.Party -> Parser V1.Party
partyParser = option readParty

readParty :: ReadM V1.Party
readParty = readAddress <|> readRole

readAddress :: ReadM V1.Party
readAddress = maybeReader $ fmap (uncurry V1.Address) . V1.deserialiseAddressBech32 . T.pack

readRole :: ReadM V1.Party
readRole = V1.Role . P.TokenName <$> str

runApplyCommand :: TxCommand ApplyCommand -> CLI ()
runApplyCommand TxCommand { walletAddresses, signingMethod, subCommand=V1ApplyCommand{..}} = runCLIExceptT do
  inputs' <- case inputs of
    ContractInputsByValue redeemer -> pure redeemer
    _ -> throwE (PlainInputsSupportedOnly inputs)
  let
    validityLowerBound'= posixTimeToUTCTime <$> validityLowerBound
    validityUpperBound'= posixTimeToUTCTime <$> validityUpperBound

    cmd = ApplyInputs MarloweV1 walletAddresses contractId validityLowerBound' validityUpperBound' inputs'
  InputsApplied{txBody} <- ExceptT $ first ApplyFailed <$> runTxCommand cmd
  case signingMethod of
    Manual outputFile -> do
      ExceptT $ liftIO $ first TransactionFileWriteFailed <$> C.writeFileTextEnvelope outputFile Nothing txBody
      let
        txId = C.getTxId txBody
        res = A.object
          [ ("txId", toJSON txId) ]
      liftIO . print $ A.encode res
  where
    posixTimeToUTCTime :: POSIXTime -> UTCTime
    posixTimeToUTCTime (POSIXTime t) = posixSecondsToUTCTime $ secondsToNominalDiffTime $ fromInteger t / 1000
