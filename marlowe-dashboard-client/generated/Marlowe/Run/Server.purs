-- File auto generated by servant-purescript! --
module Marlowe.Run.Server where

import Prelude

import Affjax.RequestHeader (RequestHeader(..))
import Cardano.Wallet.Mock.Types (WalletInfo)
import Component.Contacts.Types (WalletId)
import Data.Argonaut (Json, JsonDecodeError)
import Data.Argonaut.Decode.Aeson ((</$\>), (</*\>), (</\>))
import Data.Argonaut.Decode.Aeson as D
import Data.Argonaut.Encode.Aeson ((>$<), (>/\<))
import Data.Argonaut.Encode.Aeson as E
import Data.Array (catMaybes)
import Data.Either (Either(..))
import Data.Foldable (fold)
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple)
import Marlowe.Run.Wallet.V1 (GetTotalFundsResponse)
import Marlowe.Run.Wallet.V1.CentralizedTestnet.Types
  ( CheckPostData
  , RestoreError
  , RestorePostData
  )
import Servant.PureScript
  ( class MonadAjax
  , AjaxError
  , flagQueryPairs
  , paramListQueryPairs
  , paramQueryPairs
  , request
  , toHeader
  , toPathSegment
  )
import URI (RelativePart(..), RelativeRef(..))

data Api = Api

getApiVersion
  :: forall m
   . MonadAjax Api m
  => m (Either (AjaxError JsonDecodeError Json) String)
getApiVersion =
  request Api req
  where
  req = { method, uri, headers, content, encode, decode }
  method = Left GET
  uri = RelativeRef relativePart query Nothing
  headers = catMaybes
    [
    ]
  content = Nothing
  encode = E.encode encoder
  decode = D.decode decoder
  encoder = E.null
  decoder = D.value
  relativePart = RelativePartNoAuth $ Just
    [ "api"
    , "version"
    ]
  query = Nothing

getApiWalletV1ByWalletidTotalfunds
  :: forall m
   . MonadAjax Api m
  => WalletId
  -> m (Either (AjaxError JsonDecodeError Json) GetTotalFundsResponse)
getApiWalletV1ByWalletidTotalfunds wallet_id =
  request Api req
  where
  req = { method, uri, headers, content, encode, decode }
  method = Left GET
  uri = RelativeRef relativePart query Nothing
  headers = catMaybes
    [
    ]
  content = Nothing
  encode = E.encode encoder
  decode = D.decode decoder
  encoder = E.null
  decoder = D.value
  relativePart = RelativePartNoAuth $ Just
    [ "api"
    , "wallet"
    , "v1"
    , toPathSegment wallet_id
    , "total-funds"
    ]
  query = Nothing

postApiWalletV1CentralizedtestnetRestore
  :: forall m
   . MonadAjax Api m
  => RestorePostData
  -> m
       ( Either (AjaxError JsonDecodeError Json)
           (Either RestoreError WalletInfo)
       )
postApiWalletV1CentralizedtestnetRestore reqBody =
  request Api req
  where
  req = { method, uri, headers, content, encode, decode }
  method = Left POST
  uri = RelativeRef relativePart query Nothing
  headers = catMaybes
    [
    ]
  content = Just reqBody
  encode = E.encode encoder
  decode = D.decode decoder
  encoder = E.value
  decoder = (D.either D.value D.value)
  relativePart = RelativePartNoAuth $ Just
    [ "api"
    , "wallet"
    , "v1"
    , "centralized-testnet"
    , "restore"
    ]
  query = Nothing

postApiWalletV1CentralizedtestnetCheckmnemonic
  :: forall m
   . MonadAjax Api m
  => CheckPostData
  -> m (Either (AjaxError JsonDecodeError Json) Boolean)
postApiWalletV1CentralizedtestnetCheckmnemonic reqBody =
  request Api req
  where
  req = { method, uri, headers, content, encode, decode }
  method = Left POST
  uri = RelativeRef relativePart query Nothing
  headers = catMaybes
    [
    ]
  content = Just reqBody
  encode = E.encode encoder
  decode = D.decode decoder
  encoder = E.value
  decoder = D.value
  relativePart = RelativePartNoAuth $ Just
    [ "api"
    , "wallet"
    , "v1"
    , "centralized-testnet"
    , "check-mnemonic"
    ]
  query = Nothing
