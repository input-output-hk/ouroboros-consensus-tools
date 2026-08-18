{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DerivingVia       #-}
{-# LANGUAGE OverloadedStrings #-}

module Cardano.Beacon.Chain (module Cardano.Beacon.Chain) where

import           Cardano.Beacon.Console
import           Cardano.Beacon.Types
import           Control.Exception (SomeException (..), try)
import           Data.Aeson
import qualified Data.ByteString as B (readFile)
import           Data.Map as Map (Map, empty, lookup, size, toAscList)
import           Data.Maybe (fromMaybe)
import qualified Data.Text as T
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           System.FilePath (isRelative, (</>))


data BeaconChain = BeaconChain {
  -- | Base directory of a synthetic chain, or cardano-node.
    chHomeDir       :: !FilePath

  -- | Path for the db passed to db-analyser. This is relative to @chHomeDir@.
  , chDbDir         :: !FilePath

  -- | Path to the node's config.json file. This is relative to @chHomeDir@.
  , chConfigFile    :: !FilePath

  -- | Starts analysis at the given SlotNo.
  , chFromSlot      :: !(Maybe Int)

  -- | Stops after analysing given number of blocks.
  , chProcessBlocks :: !(Maybe Int)

  -- | Free-form description of the chain fragment.
  , chDescription   :: !(Maybe Text)
  } deriving (Generic, Show)

instance FromJSON BeaconChain where
  parseJSON = genericParseJSON aesonNoTagFields

newtype Chains = Chains {unChains :: Map ChainName BeaconChain}
        deriving (Show, FromJSON)
          via Map ChainName BeaconChain


emptyChains :: Chains
emptyChains = Chains Map.empty

countChains :: Chains -> Int
countChains = Map.size . unChains

lookupChain :: ChainName -> Chains -> Maybe BeaconChain
lookupChain name = (name `Map.lookup`) . unChains

renderChainsInfo :: Chains -> [String]
renderChainsInfo (Chains chains) =
  map (T.unpack . infoLine) (Map.toAscList chains)
  where
    infoLine (ChainName name, BeaconChain{ chDescription = descr }) =
      T.concat [alignRight 24 name, " -- ", fromMaybe "(no description provided)" descr]
    alignRight width = T.justifyRight width ' ' . T.take width

loadChainsInfo :: FilePath -> IO Chains
loadChainsInfo jsonFile =
  try (B.readFile jsonFile >>= throwDecodeStrict') >>= either
    warn
    pure
  where
    warn (SomeException e) = do
      printStyled StyleWarning $ unlines
        [ "There was an error reading chains info in '" ++ jsonFile ++ "'"
        , "I will default to no registered chains; the error was:"
        , show e
        ]
      pure emptyChains

-- | Resolve a chain's home directory to an absolute\/usable path, exactly as
-- 'Cardano.Beacon.Run.runDbAnalyser' does when invoking db-analyser.
resolveChainDir :: FilePath -> FilePath -> FilePath
resolveChainDir beaconDir chHomeDir
  | isRelative chHomeDir = beaconDir </> "chain" </> chHomeDir
  | otherwise            = chHomeDir

-- | The subset of a node's @config.json@ we care about.
newtype NodeConfig = NodeConfig { ncShelleyGenesisFile :: FilePath }

instance FromJSON NodeConfig where
  parseJSON = withObject "NodeConfig" $ \o ->
    NodeConfig <$> o .: "ShelleyGenesisFile"

-- | The subset of a Shelley genesis file we care about.
newtype ShelleyGenesis = ShelleyGenesis { sgEpochLength :: Word64 }

instance FromJSON ShelleyGenesis where
  parseJSON = withObject "ShelleyGenesis" $ \o ->
    ShelleyGenesis <$> o .: "epochLength"

-- | Look up a chain's epoch length (in slots), by following its node config
-- to the Shelley genesis file it references. All eras that are live on a
-- beacon-benchmarked chain hard-fork at epoch 0 (see 'chConfigFile'), so the
-- Shelley epoch length applies from the chain's genesis onwards.
-- Returns 'Nothing' (with a warning) if the config or genesis file can't be
-- read/parsed, e.g. for chains registered before epoch length was needed.
loadEpochLength :: FilePath -> BeaconChain -> IO (Maybe Word64)
loadEpochLength beaconDir BeaconChain{chHomeDir, chConfigFile} = do
  mConfig <- decodeFileStrict configPath
  case mConfig of
    Nothing -> warn configPath >> pure Nothing
    Just NodeConfig{ncShelleyGenesisFile} -> do
      let genesisPath = chainDir </> ncShelleyGenesisFile
      mGenesis <- decodeFileStrict genesisPath
      case mGenesis of
        Nothing                            -> warn genesisPath >> pure Nothing
        Just ShelleyGenesis{sgEpochLength} -> pure (Just sgEpochLength)
  where
    chainDir   = resolveChainDir beaconDir chHomeDir
    configPath = chainDir </> chConfigFile

    warn path = printStyled StyleWarning $
      "could not read/parse '" ++ path ++ "' to determine epoch length"
