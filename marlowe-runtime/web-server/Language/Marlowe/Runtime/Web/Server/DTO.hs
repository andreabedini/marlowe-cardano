{-# LANGUAGE TypeFamilies #-}

-- | This module defines the data-transfer object (DTO) translation layer for
-- the web server. DTOs are the types served by the API, which notably include
-- no cardano-api dependencies and have nice JSON representations. This module
-- describes how they are mapped to the internal API types of the runtime.

module Language.Marlowe.Runtime.Web.Server.DTO
  where

import Language.Marlowe.Runtime.Discovery.Api

import Cardano.Api (metadataValueToJsonNoSchema)
import Data.Coerce (coerce)
import Data.Map (Map)
import Data.Word (Word16, Word64)
import Language.Marlowe.Runtime.Cardano.Api (toCardanoMetadata)
import qualified Language.Marlowe.Runtime.ChainSync.Api as Chain
import Language.Marlowe.Runtime.Core.Api (ContractId(..), MarloweVersion(MarloweV1), SomeMarloweVersion(..))
import qualified Language.Marlowe.Runtime.Web as Web

-- | A class that states a type has a DTO representation.
class HasDTO a where
  -- | The type used in the API to represent this type.
  type DTO a :: *

-- | States that a type can be encoded as a DTO.
class HasDTO a => ToDTO a where
  toDTO :: a -> DTO a

-- | States that a type can be decoded from a DTO.
class HasDTO a => FromDTO a where
  fromDTO :: DTO a -> Maybe a

instance HasDTO (Map k a) where
  type DTO (Map k a) = Map k (DTO a)

instance ToDTO a => ToDTO (Map k a) where
  toDTO = fmap toDTO

instance HasDTO [a] where
  type DTO [a] = [DTO a]

instance ToDTO a => ToDTO [a] where
  toDTO = fmap toDTO

instance HasDTO ContractHeader where
  type DTO ContractHeader = Web.ContractHeader

instance ToDTO ContractHeader where
  toDTO ContractHeader{..} = Web.ContractHeader
    { contractId = toDTO contractId
    , roleTokenMintingPolicyId = toDTO rolesCurrency
    , version = toDTO marloweVersion
    , metadata = toDTO metadata
    , status = Web.Confirmed $ toDTO blockHeader
    }

instance HasDTO Chain.BlockHeader where
  type DTO Chain.BlockHeader = Web.BlockHeader

instance ToDTO Chain.BlockHeader where
  toDTO Chain.BlockHeader{..} = Web.BlockHeader
    { slotNo = toDTO slotNo
    , blockNo = toDTO blockNo
    , blockHeaderHash = toDTO headerHash
    }

instance HasDTO ContractId where
  type DTO ContractId = Web.TxOutRef

instance ToDTO ContractId where
  toDTO = toDTO . unContractId

instance FromDTO ContractId where
  fromDTO = fmap ContractId . fromDTO

instance HasDTO SomeMarloweVersion where
  type DTO SomeMarloweVersion = Web.MarloweVersion

instance ToDTO SomeMarloweVersion where
  toDTO (SomeMarloweVersion MarloweV1) = Web.V1

instance HasDTO Chain.TxOutRef where
  type DTO Chain.TxOutRef = Web.TxOutRef

instance ToDTO Chain.TxOutRef where
  toDTO Chain.TxOutRef{..} = Web.TxOutRef
    { txId = toDTO txId
    , txIx = toDTO txIx
    }

instance FromDTO Chain.TxOutRef where
  fromDTO Web.TxOutRef{..} = Chain.TxOutRef
    <$> fromDTO txId
    <*> fromDTO txIx

instance HasDTO Chain.TxId where
  type DTO Chain.TxId = Web.TxId

instance ToDTO Chain.TxId where
  toDTO = coerce

instance FromDTO Chain.TxId where
  fromDTO = pure . coerce

instance HasDTO Chain.PolicyId where
  type DTO Chain.PolicyId = Web.PolicyId

instance ToDTO Chain.PolicyId where
  toDTO = coerce

instance HasDTO Chain.TxIx where
  type DTO Chain.TxIx = Word16

instance ToDTO Chain.TxIx where
  toDTO = coerce

instance FromDTO Chain.TxIx where
  fromDTO = pure . coerce

instance HasDTO Chain.Metadata where
  type DTO Chain.Metadata = Web.Metadata

instance ToDTO Chain.Metadata where
  toDTO = Web.Metadata . metadataValueToJsonNoSchema . toCardanoMetadata

instance HasDTO Chain.SlotNo where
  type DTO Chain.SlotNo = Word64

instance ToDTO Chain.SlotNo where
  toDTO = coerce

instance HasDTO Chain.BlockNo where
  type DTO Chain.BlockNo = Word64

instance ToDTO Chain.BlockNo where
  toDTO = coerce

instance HasDTO Chain.BlockHeaderHash where
  type DTO Chain.BlockHeaderHash = Web.Base16

instance ToDTO Chain.BlockHeaderHash where
  toDTO = coerce
