{-# LANGUAGE BangPatterns    #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}

{-| = ACTUS

Given ACTUS contract terms, cashflows are projected based on risk factors.

-}

module Actus.Core
  ( genStates
  , genPayoffs
  , genCashflow
  , genProjectedPayoffs
  , genProjectedCashflows
  )
where

import Actus.Domain (CT (..), CashFlow (..), ContractState (..), ContractTerms (..), EventType (..), RiskFactors (..),
                     RoleSignOps (..), ScheduleOps (..), ShiftedDay (..), YearFractionOps (..))
import Actus.Model (CtxPOF (CtxPOF), CtxSTF (..), initializeState, maturity, payoff, schedule, stateTransition)
import Control.Applicative ((<|>))
import Control.Monad (filterM)
import Control.Monad.Reader (Reader, ask, runReader, withReader)
import Data.List (groupBy)
import Data.Maybe (fromMaybe, isNothing)
import Data.Sort (sortOn)
import Data.Time (LocalTime)

-- |'genProjectedCashflows' generates a list of projected cashflows for
-- given contract terms and provided risk factors. The function returns
-- an empty list, if building the initial state given the contract terms
-- fails or in case there are no cash flows.
genProjectedCashflows :: (RoleSignOps a, ScheduleOps a, YearFractionOps a) =>
  (EventType -> LocalTime -> RiskFactors a) -- ^ Risk factors as a function of event type and time
  -> ContractTerms a                        -- ^ Contract terms
  -> [CashFlow a]                           -- ^ List of projected cash flows
genProjectedCashflows rf ct =
  genCashflow ct
    <$> ( runReader
            genProjectedPayoffs
            $ CtxSTF
              ct
              (calculationDay <$> schedule FP ct) -- init & stf rely on the fee payment schedule
              (calculationDay <$> schedule PR ct) -- init & stf rely on the principal redemption schedule
              (calculationDay <$> schedule IP ct) -- init & stf rely on the interest payment schedule
              (maturity ct)
              rf
        )

-- |Generate cash flows
genCashflow ::
  ContractTerms a                                -- ^ Contract terms
  -> (EventType, ShiftedDay, ContractState a, a) -- ^ Projected payoff
  -> CashFlow a                                  -- ^ Projected cash flow
genCashflow ct (ev, t, ContractState {..}, am) =
        CashFlow
          { tick = 0,
            cashContractId = contractId ct,
            cashParty = "party",
            cashCounterParty = "counterparty",
            cashPaymentDay = paymentDay t,
            cashCalculationDay = calculationDay t,
            cashEvent = ev,
            amount = am,
            notional = nt,
            currency = fromMaybe "unknown" (settlementCurrency ct)
          }

-- |Generate projected cash flows
genProjectedPayoffs :: (RoleSignOps a, ScheduleOps a, YearFractionOps a) =>
  Reader (CtxSTF a) [(EventType, ShiftedDay, ContractState a, a)]
genProjectedPayoffs =
  do
    schedules <- genSchedules . contractTerms <$> ask
    st0 <- initializeState
    states <- genStates schedules st0
    payoffs <- trans $ genPayoffs states

    return $
      sortOn (\(x,y,_,_) -> (y,x)) $
        zipWith (\(x,y,!z) -> (x,y,z,)) states payoffs

  where
    trans :: Reader (CtxPOF a) b -> Reader (CtxSTF a) b
    trans = withReader (\c -> CtxPOF (contractTerms c) (riskFactors c))

-- |Generate schedules
genSchedules :: (RoleSignOps a, ScheduleOps a, YearFractionOps a) =>
  ContractTerms a          -- ^ Contract terms
  -> [(EventType, ShiftedDay)] -- ^ Schedules
genSchedules ct@ContractTerms {..} =
  filter filtersSchedules . postProcessSchedules . sortOn (paymentDay . snd) $
    concatMap scheduleEvent eventTypes
  where
    eventTypes = enumFrom (toEnum 0)
    scheduleEvent ev = (ev,) <$> schedule ev ct

    filtersSchedules :: (EventType, ShiftedDay) -> Bool
    filtersSchedules (_, ShiftedDay {..}) | contractType == OPTNS = calculationDay > statusDate
    filtersSchedules (_, ShiftedDay {..}) | contractType == FUTUR = calculationDay > statusDate
    filtersSchedules (_, ShiftedDay {..}) | contractType == CLM = calculationDay > statusDate
    filtersSchedules (_, ShiftedDay {..}) = isNothing terminationDate || Just calculationDay <= terminationDate

    postProcessSchedules :: [(EventType, ShiftedDay)] -> [(EventType, ShiftedDay)]
    postProcessSchedules =
      let trim = dropWhile (\(_, d) -> calculationDay d < statusDate)
          regroup = groupBy (\(_, l) (_, r) -> calculationDay l == calculationDay r)
          overwrite = map (sortOn (\(ev, _) -> fromEnum ev)) . regroup
       in concat . overwrite . trim

mapAccumLM' :: Monad m => (acc -> x -> m (acc, y)) -> acc -> [x] -> m (acc, [y])
mapAccumLM' f = go
  where
    go s (x : xs) = do
      (!s1, !x') <- f s x
      (s2, xs') <- go s1 xs
      return (s2, x' : xs')
    go s [] = return (s, [])

-- |Generate states
genStates :: (RoleSignOps a, ScheduleOps a, YearFractionOps a) =>
  [(EventType, ShiftedDay)]                                           -- ^ Schedules
  -> ContractState a                                              -- ^ Initial state
  -> Reader (CtxSTF a) [(EventType, ShiftedDay, ContractState a)] -- ^ New states
genStates scs stn = mapAccumLM' apply st0 scs >>= filterM filtersStates . snd
  where
    apply (ev, ShiftedDay {..}, st) (ev', t') =
        do !st_n <- stateTransition ev calculationDay st
           return ((ev',t',st_n), (ev',t',st_n))

    st0 = (AD,ShiftedDay (sd stn) (sd stn),stn)

    filtersStates ::
      (RoleSignOps a, ScheduleOps a, YearFractionOps a) =>
      (EventType, ShiftedDay, ContractState a) ->
      Reader (CtxSTF a) Bool
    filtersStates (ev, ShiftedDay {..}, _) =
      do ct@ContractTerms {..} <- contractTerms <$> ask
         return $ case contractType of
                    PAM -> isNothing purchaseDate || Just calculationDay >= purchaseDate
                    LAM -> isNothing purchaseDate || ev == PRD || Just calculationDay > purchaseDate
                    NAM -> isNothing purchaseDate || ev == PRD || Just calculationDay > purchaseDate
                    ANN ->
                      let b1 = isNothing purchaseDate || ev == PRD || Just calculationDay > purchaseDate
                          b2 = let m = maturityDate <|> amortizationDate <|> maturity ct in isNothing m || Just calculationDay <= m
                       in b1 && b2
                    SWPPV -> isNothing purchaseDate || ev == PRD || Just calculationDay > purchaseDate
                    CLM -> isNothing purchaseDate || ev == PRD || Just calculationDay > purchaseDate
                    _ -> True

-- |Generate payoffs
genPayoffs :: (RoleSignOps a, YearFractionOps a) =>
  [(EventType, ShiftedDay, ContractState a)] -- ^ States with schedule
  -> Reader (CtxPOF a) [a]                       -- ^ Payoffs
genPayoffs = mapM calculatePayoff
  where
    calculatePayoff (ev, ShiftedDay {..}, st) = payoff ev calculationDay st
