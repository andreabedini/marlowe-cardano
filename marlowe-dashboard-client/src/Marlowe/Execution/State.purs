module Marlowe.Execution.State
  ( contractName
  , expandBalances
  , extractNamedActions
  , getActionParticipant
  , getAllPayments
  , isClosed
  , mkInitialState
  , mkTx
  , nextState
  , nextTimeout
  , numberOfConfirmedTxs
  , restoreState
  , setPendingTransaction
  , timeoutState
  ) where

import Prologue

import Data.Array (foldl, length)
import Data.Array as Array
import Data.BigInt.Argonaut (fromInt)
import Data.ContractNickname (ContractNickname)
import Data.ContractNickname as ContractNickname
import Data.Lens (_1, _2, view, (^.))
import Data.List (List(..), concat, fromFoldable)
import Data.Map as Map
import Data.Maybe (fromMaybe, fromMaybe', maybe)
import Data.Tuple.Nested ((/\))
import Marlowe.Client (ContractHistory, _chHistory, _chParams)
import Marlowe.Execution.Lenses (_resultingPayments)
import Marlowe.Execution.Types
  ( NamedAction(..)
  , PastAction(..)
  , PendingTimeouts
  , State
  , TimeoutInfo
  )
import Marlowe.Extended.Metadata (MetaData)
import Marlowe.Semantics
  ( Accounts
  , Action(..)
  , Case(..)
  , ChoiceId(..)
  , Contract(..)
  , Environment(..)
  , Input
  , MarloweParams
  , Party
  , Payment
  , ReduceResult(..)
  , Slot
  , SlotInterval(..)
  , Timeouts(..)
  , Token
  , TransactionInput(..)
  , TransactionOutput(..)
  , _accounts
  , _marloweContract
  , _marloweState
  , computeTransaction
  , emptyState
  , evalValue
  , makeEnvironment
  , reduceContractUntilQuiescent
  , timeouts
  )
import Marlowe.Semantics (State) as Semantic
import Marlowe.Slot (posixTimeToSlot, slotToPOSIXTime)
import Plutus.V1.Ledger.Time (POSIXTime(..))

mkInitialState
  :: Slot
  -> Maybe ContractNickname
  -> MarloweParams
  -> MetaData
  -> Contract
  -> State
mkInitialState currentSlot contractNickname marloweParams metadata contract =
  { semanticState: emptyState (slotToPOSIXTime currentSlot)
  , contractNickname
  , contract
  , metadata
  , marloweParams
  , history: mempty
  , mPendingTransaction: Nothing
  , mPendingTimeouts: Nothing
  , mNextTimeout: nextTimeout contract
  }

restoreState
  :: Slot -> Maybe ContractNickname -> MetaData -> ContractHistory -> State
restoreState currentSlot contractNickname metadata history =
  let
    contract = view (_chParams <<< _2 <<< _marloweContract) history
    marloweParams = view (_chParams <<< _1) history
    initialSemanticState = view (_chParams <<< _2 <<< _marloweState) history
    inputs = view _chHistory history
    -- Derive the initial params from the Follower Contract params
    initialState =
      { semanticState: initialSemanticState
      , contractNickname
      , contract
      , metadata
      , marloweParams
      , history: mempty
      , mPendingTransaction: Nothing
      , mPendingTimeouts: Nothing
      , mNextTimeout: nextTimeout contract
      }
  in
    -- Apply all the transaction inputs
    foldl (flip nextState) initialState inputs
      -- See if any step has timeouted
      # timeoutState currentSlot

-- Each contract should always have a name, if we
-- have given a Local nickname, we use that, if not we
-- show the currency symbol
-- TODO: SCP-3500 Show the currency symbol when we don't have a nickname
contractName :: State -> String
contractName { contractNickname } = maybe "Unknown"
  ContractNickname.toString
  contractNickname

numberOfConfirmedTxs :: State -> Int
numberOfConfirmedTxs state = length state.history

setPendingTransaction :: TransactionInput -> State -> State
setPendingTransaction txInput state = state
  { mPendingTransaction = Just txInput }

nextState :: TransactionInput -> State -> State
nextState txInput state =
  let
    { semanticState, contract, history } =
      state
    TransactionInput { interval: SlotInterval minTime _, inputs } = txInput
    minSlot = posixTimeToSlot minTime

    { txOutState, txOutContract, txOutPayments } =
      case computeTransaction txInput semanticState contract of
        (TransactionOutput { txOutState, txOutContract, txOutPayments }) ->
          { txOutState, txOutContract, txOutPayments }
        -- We should not have contracts which cause errors in the dashboard so we will just ignore error cases for now
        -- FIXME: Change nextState to return an Either
        -- TODO: SCP-2088 We need to discuss how to display the warnings that computeTransaction may give
        (Error _) ->
          { txOutState: semanticState
          , txOutContract: contract
          , txOutPayments: mempty
          }

    -- For the moment the only way to get an empty transaction is if there was a timeout,
    -- but later on there could be other reasons to move a contract forward, and we should
    -- compare with the contract to see the reason.
    action = case inputs of
      Nil -> TimeoutAction
        { slot: minSlot
        , missedActions: extractActionsFromContract minSlot semanticState
            contract
        }
      _ -> InputAction

    mPendingTransaction =
      if state.mPendingTransaction == Just txInput then
        Nothing
      else
        state.mPendingTransaction

    pastState =
      { balancesAtStart: semanticState ^. _accounts
      , action
      , txInput
      , balancesAtEnd: txOutState ^. _accounts
      , resultingPayments: txOutPayments
      }
  in
    state
      { semanticState = txOutState
      , contract = txOutContract
      , history = Array.snoc history pastState
      , mPendingTransaction = mPendingTransaction
      , mPendingTimeouts = Nothing
      , mNextTimeout = nextTimeout txOutContract
      }

nextTimeout :: Contract -> Maybe Slot
nextTimeout = timeouts >>> \(Timeouts { minTime }) -> map posixTimeToSlot
  minTime

mkTx :: Slot -> Contract -> List Input -> TransactionInput
mkTx currentSlot contract inputs =
  let
    interval = mkInterval currentSlot contract
  in
    TransactionInput { interval, inputs }

-- This function checks if the are any new timeouts in the current execution state
timeoutState :: Slot -> State -> State
timeoutState
  currentSlot
  state =
  let
    { semanticState
    , contract
    , mPendingTimeouts
    , mNextTimeout
    } = state
    -- We start of by getting a PendingTimeout structure from the execution state (because the
    -- contract could already have some timeouts that were "advanced")
    { continuation, timeouts } =
      fromMaybe'
        ( \_ ->
            { continuation: { state: semanticState, contract }, timeouts: [] }
        )
        mPendingTimeouts

    -- This helper function does all the leg work.
    -- A contract step can be stale/timeouted but it does not advance on its own, it needs
    -- an empty transaction or the next meaningfull transaction. With this function we check if
    -- the contract has timeouted and calculate what would be the resulting continuation contract
    -- and resulting state if we'd apply an empty transaction.
    advanceAllTimeouts
      :: Maybe Slot
      -> Array TimeoutInfo
      -> Semantic.State
      -> Contract
      -> { mNextTimeout :: Maybe Slot
         , mPendingTimeouts :: Maybe PendingTimeouts
         }
    advanceAllTimeouts (Just timeoutSlot) newTimeouts state' contract'
      | timeoutSlot <= currentSlot =
          let
            time = slotToPOSIXTime currentSlot

            env = makeEnvironment time time

            { txOutState, txOutContract } =
              case reduceContractUntilQuiescent env state' contract' of
                -- TODO: SCP-2088 We need to discuss how to display the warnings that computeTransaction may give
                ContractQuiescent _ _ _ txOutState txOutContract ->
                  { txOutState, txOutContract }
                -- FIXME: Change timeoutState to return an Either
                RRAmbiguousSlotIntervalError ->
                  { txOutState: state', txOutContract: contract' }

            timeoutInfo =
              { slot: timeoutSlot
              , missedActions: extractActionsFromContract timeoutSlot state'
                  contract'
              }

            newNextTimeout = nextTimeout txOutContract
          in
            advanceAllTimeouts newNextTimeout
              (Array.snoc newTimeouts timeoutInfo)
              txOutState
              txOutContract

    advanceAllTimeouts mNextTimeout' newTimeouts state' contract' =
      { mNextTimeout: mNextTimeout'
      , mPendingTimeouts:
          if newTimeouts == mempty then
            Nothing
          else
            Just
              { continuation: { state: state', contract: contract' }
              , timeouts: newTimeouts
              }
      }

    advancedTimeouts = advanceAllTimeouts mNextTimeout timeouts
      continuation.state
      continuation.contract
  in
    state
      { mPendingTransaction = Nothing
      , mPendingTimeouts = advancedTimeouts.mPendingTimeouts
      , mNextTimeout = advancedTimeouts.mNextTimeout
      }

------------------------------------------------------------
isClosed :: State -> Boolean
isClosed { contract: Close } = true

isClosed _ = false

getActionParticipant :: NamedAction -> Maybe Party
getActionParticipant (MakeDeposit _ party _ _) = Just party

getActionParticipant (MakeChoice (ChoiceId _ party) _ _) = Just party

getActionParticipant _ = Nothing

extractNamedActions :: Slot -> State -> Array NamedAction
extractNamedActions
  _
  { mPendingTimeouts: Just { continuation: { contract: Close } } } =
  [ CloseContract ]

extractNamedActions currentSlot { mPendingTimeouts: Just { continuation } } =
  extractActionsFromContract currentSlot continuation.state
    continuation.contract

extractNamedActions currentSlot { semanticState, contract } =
  extractActionsFromContract currentSlot semanticState contract

-- a When can only progress if it has timed out or has Cases
extractActionsFromContract
  :: Slot -> Semantic.State -> Contract -> Array NamedAction
extractActionsFromContract _ _ Close = mempty

extractActionsFromContract currentSlot semanticState contract@(When cases _ _) =
  cases <#> \(Case action _) -> toNamedAction action
  where
  toNamedAction (Deposit a p t v) =
    let
      interval = mkInterval currentSlot contract

      env = Environment { slotInterval: interval }

      amount = evalValue env semanticState v
    in
      MakeDeposit a p t amount

  toNamedAction (Choice cid bounds) = MakeChoice cid bounds Nothing

  toNamedAction (Notify obs) = MakeNotify obs

-- In reality other situations should never occur as contracts always reduce to When or Close
-- however someone could in theory publish a contract that starts with another Contract constructor
-- and we would want to enable moving forward with Evaluate
extractActionsFromContract _ _ _ =
  [ Evaluate { bindings: Map.empty, payments: [] } ]

-- This function expands the balances inside the Semantic.State to all participants and tokens,
-- using zero if the participant does not have balance for that token.
expandBalances :: Array Party -> Array Token -> Accounts -> Accounts
expandBalances participants tokens stateAccounts =
  Map.fromFoldable do
    party <- participants
    tokens
      <#> \token ->
        let
          key = party /\ token
        in
          key /\ (fromMaybe zero $ Map.lookup key stateAccounts)

mkInterval :: Slot -> Contract -> SlotInterval
mkInterval currentSlot contract =
  let
    time = slotToPOSIXTime currentSlot
  in
    case nextTimeout contract of
      Nothing -> SlotInterval time
        (time + POSIXTime { getPOSIXTime: (fromInt 10) })
      Just minTime
        -- FIXME: We should change this for a Maybe SlotInterval and return Nothing in this case.
        --        86400 is one day in seconds
        | minTime < currentSlot -> SlotInterval time
            (time + POSIXTime { getPOSIXTime: (fromInt 86400) })
        | otherwise -> SlotInterval time
            (slotToPOSIXTime minTime - POSIXTime { getPOSIXTime: (fromInt 1) })

getAllPayments :: State -> List Payment
getAllPayments { history } = concat $ fromFoldable $ map
  (view _resultingPayments)
  history
