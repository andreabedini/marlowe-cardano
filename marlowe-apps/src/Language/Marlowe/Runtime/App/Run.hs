

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}


module Language.Marlowe.Runtime.App.Run
  ( runChainSeekClient
  , runClientWithConfig
  , runJobClient
  , runMarloweHeaderSyncClient
  , runMarloweSyncClient
  , runQueryClient
  ) where


import Control.Exception (Exception, bracket, bracketOnError, throwIO)
import Control.Monad.Trans.Control (liftBaseWith)
import Control.Monad.Trans.Reader (ReaderT(..), ask)
import Data.ByteString.Lazy (ByteString)
import Language.Marlowe.Protocol.HeaderSync.Client
  (MarloweHeaderSyncClient, hoistMarloweHeaderSyncClient, marloweHeaderSyncClientPeer)
import Language.Marlowe.Protocol.HeaderSync.Codec (codecMarloweHeaderSync)
import Language.Marlowe.Protocol.Sync.Client (MarloweSyncClient, hoistMarloweSyncClient, marloweSyncClientPeer)
import Language.Marlowe.Protocol.Sync.Codec (codecMarloweSync)
import Language.Marlowe.Runtime.App.Types (Client(..), Config(..), RunClient, Services(..))
import Language.Marlowe.Runtime.ChainSync.Api (RuntimeChainSeekClient, WithGenesis(Genesis))
import Network.Channel (socketAsChannel)
import Network.Protocol.ChainSeek.Client (chainSeekClientPeer, hoistChainSeekClient)
import Network.Protocol.ChainSeek.Codec (codecChainSeek)
import Network.Protocol.Driver (mkDriver)
import Network.Protocol.Job.Client (JobClient, hoistJobClient, jobClientPeer)
import Network.Protocol.Job.Codec (codecJob)
import Network.Protocol.Query.Client (QueryClient, hoistQueryClient, queryClientPeer)
import Network.Protocol.Query.Codec (codecQuery)
import Network.Socket
  (AddrInfo, SocketType(..), addrAddress, addrSocketType, close, connect, defaultHints, getAddrInfo, openSocket)
import Network.TypedProtocol (Driver(startDState), Peer, PeerRole(..), runPeerWithDriver)
import Network.TypedProtocol.Codec (Codec)


runQueryClient
  :: (Services IO -> QueryClient q IO a -> IO a)
  -> QueryClient q Client a
  -> Client a
runQueryClient query client =
  do
    services <- Client ask
    liftBaseWith $ \runInBase -> query services $ hoistQueryClient runInBase client


runJobClient
  :: (Services IO -> JobClient q IO a -> IO a)
  -> JobClient q Client a
  -> Client a
runJobClient job client =
  do
    services <- Client ask
    liftBaseWith $ \runInBase -> job services $ hoistJobClient runInBase client


runChainSeekClient
  :: (Services IO -> RuntimeChainSeekClient IO a -> IO a)
  -> RuntimeChainSeekClient Client a
  -> Client a
runChainSeekClient seek client =
  do
    services <- Client ask
    liftBaseWith $ \runInBase -> seek services $ hoistChainSeekClient runInBase client


runMarloweSyncClient
  :: (Services IO -> MarloweSyncClient IO a -> IO a)
  -> MarloweSyncClient Client a
  -> Client a
runMarloweSyncClient sync client =
  do
    services <- Client ask
    liftBaseWith $ \runInBase -> sync services $ hoistMarloweSyncClient runInBase client


runMarloweHeaderSyncClient
  :: (Services IO -> MarloweHeaderSyncClient IO a -> IO a)
  -> MarloweHeaderSyncClient Client a
  -> Client a
runMarloweHeaderSyncClient sync client =
  do
    services <- Client ask
    liftBaseWith $ \runInBase -> sync services $ hoistMarloweHeaderSyncClient runInBase client


runClientWithConfig
  :: Config
  -> Client a
  -> IO a
runClientWithConfig Config{..} client = do
  chainSeekCommandAddr <- resolve chainSeekHost chainSeekCommandPort
  chainSeekQueryAddr <- resolve chainSeekHost chainSeekQueryPort
  chainSeekSyncAddr <- resolve chainSeekHost chainSeekSyncPort
  historyJobAddr <- resolve historyHost historyCommandPort
  historyQueryAddr <- resolve historyHost historyQueryPort
  historySyncAddr <- resolve historyHost historySyncPort
  discoveryQueryAddr <- resolve discoveryHost discoveryQueryPort
  discoverySyncAddr <- resolve discoveryHost discoverySyncPort
  txJobAddr <- resolve txHost txCommandPort
  runReaderT (runClient client) Services
    { runChainSeekCommandClient = runClientPeerOverSocket chainSeekCommandAddr codecJob jobClientPeer
    , runChainSeekQueryClient = runClientPeerOverSocket chainSeekQueryAddr codecQuery queryClientPeer
    , runChainSeekSyncClient = runClientPeerOverSocket chainSeekSyncAddr codecChainSeek (chainSeekClientPeer Genesis)
    , runHistoryCommandClient = runClientPeerOverSocket historyJobAddr codecJob jobClientPeer
    , runHistoryQueryClient = runClientPeerOverSocket historyQueryAddr codecQuery queryClientPeer
    , runHistorySyncClient = runClientPeerOverSocket historySyncAddr codecMarloweSync marloweSyncClientPeer
    , runTxCommandClient = runClientPeerOverSocket txJobAddr codecJob jobClientPeer
    , runDiscoveryQueryClient = runClientPeerOverSocket discoveryQueryAddr codecQuery queryClientPeer
    , runDiscoverySyncClient = runClientPeerOverSocket discoverySyncAddr codecMarloweHeaderSync marloweHeaderSyncClientPeer
    }
  where
    resolve host port =
      head <$> getAddrInfo (Just defaultHints { addrSocketType = Stream }) (Just host) (Just $ show port)


-- | Run a client as a typed protocols peer over a socket.
runClientPeerOverSocket
  :: Exception ex
  => AddrInfo -- ^ Socket address to connect to
  -> Codec protocol ex IO ByteString -- ^ A codec for the protocol
  -> (forall a. client IO a -> Peer protocol 'AsClient st IO a) -- ^ Interpret the client as a protocol peer
  -> RunClient IO client
runClientPeerOverSocket addr codec clientToPeer client = bracket open close $ \socket -> do
  let channel = socketAsChannel socket
  let driver = mkDriver throwIO codec channel
  let peer = clientToPeer client
  fst <$> runPeerWithDriver driver peer (startDState driver)
  where
    open = bracketOnError (openSocket addr) close $ \sock -> do
      connect sock $ addrAddress addr
      pure sock
