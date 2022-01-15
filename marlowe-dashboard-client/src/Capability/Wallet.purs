module Capability.Wallet
  ( class ManageWallet
  , GetTotalFundsResponse
  , createWallet
  , restoreWallet
  , submitWalletTransaction
  , getWalletInfo
  , getWalletTotalFunds
  , signTransaction
  ) where

import Prologue

import API.Marlowe.Run.Wallet as WBE
import API.Marlowe.Run.Wallet.CentralizedTestnet
  ( RestoreError
  , RestoreWalletOptions
  )
import API.Marlowe.Run.Wallet.CentralizedTestnet as TestnetAPI
import API.MockWallet as MockAPI
import AppM (AppM)
import Bridge (toBack, toFront)
import Component.Contacts.Types (WalletId, WalletInfo)
import Control.Monad.Except (lift, runExceptT)
import Halogen (HalogenM)
import Marlowe.Run.Wallet.API as BE
import Marlowe.Semantics (Assets)
import Plutus.V1.Ledger.Tx (Tx)
import Types (AjaxResponse)
import Unsafe.Coerce (unsafeCoerce)

type GetTotalFundsResponse =
  { assets :: Assets
  , sync :: Number
  }

-- TODO create a Dto module to replace Bridge (but where decoding can fail).
-- This will mirror backend architecture.
getTotalFundsResponseFromDto
  :: BE.GetTotalFundsResponse -> GetTotalFundsResponse
getTotalFundsResponseFromDto = unsafeCoerce

-- FIXME: Abstract away AjaxResponse (just return an `m ResponseType` and
-- handle API failures in the concrete Monad instance).
class Monad m <= ManageWallet m where
  createWallet :: m (AjaxResponse WalletInfo)
  restoreWallet :: RestoreWalletOptions -> m (Either RestoreError WalletInfo)
  submitWalletTransaction :: WalletId -> Tx -> m (AjaxResponse Unit)
  getWalletInfo :: WalletId -> m (AjaxResponse WalletInfo)
  getWalletTotalFunds :: WalletId -> m (AjaxResponse GetTotalFundsResponse)
  signTransaction :: WalletId -> Tx -> m (AjaxResponse Tx)

instance monadWalletAppM :: ManageWallet AppM where
  createWallet = map (map toFront) $ runExceptT $ MockAPI.createWallet
  restoreWallet options = map (map toFront) $ TestnetAPI.restoreWallet options
  submitWalletTransaction wallet tx = runExceptT $
    MockAPI.submitWalletTransaction (toBack wallet) tx
  getWalletInfo wallet = map (map toFront) $ runExceptT $ MockAPI.getWalletInfo
    (toBack wallet)
  getWalletTotalFunds walletId = runExceptT
    $ map getTotalFundsResponseFromDto
    $ WBE.getTotalFunds
    $ unsafeCoerce walletId -- TODO create DTO module like backend
  signTransaction wallet tx = runExceptT $ MockAPI.signTransaction
    (toBack wallet)
    tx

instance monadWalletHalogenM ::
  ManageWallet m =>
  ManageWallet (HalogenM state action slots msg m) where
  createWallet = lift createWallet
  restoreWallet options = lift $ restoreWallet options
  submitWalletTransaction tx wallet = lift $ submitWalletTransaction tx wallet
  getWalletInfo = lift <<< getWalletInfo
  getWalletTotalFunds = lift <<< getWalletTotalFunds
  signTransaction tx wallet = lift $ signTransaction tx wallet
