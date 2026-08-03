{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DerivingVia       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Cardano.Beacon.RunMeta (module Cardano.Beacon.RunMeta) where

import           Cardano.Beacon.CLI (ApplyMode (..), Backend (..),
                     backendCLIOpts)
import           Cardano.Beacon.SlotDataPoint (SortedDataPoints)
import           Cardano.Beacon.Types
import           Data.Aeson
import           Data.List (intercalate)
import           Data.Text as T (unpack)
import           Data.Time.Clock (UTCTime)
import           GHC.Generics (Generic)


data BeaconRunMeta = BeaconRunMeta {
    commit   :: CommitInfo
  , version  :: Version
  , chain    :: ChainName
  , nixPath  :: FilePath
  , host     :: String
  , date     :: UTCTime
  , manifest :: Manifest
  , apply    :: ApplyMode
  , backend  :: Backend
  , memLimit :: Maybe MemLimitOpts
  -- ^ 'Nothing' only for runs stored before this field existed; a run
  -- performed with no memory-limiting flags at all still records
  -- @'Just' (MemLimitOpts Nothing Nothing False)@.
  }
  deriving (Show, Generic)

instance ToJSON BeaconRunMeta where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON BeaconRunMeta where
  parseJSON = genericParseJSON aesonNoTagFields

data BeaconRun = BeaconRun {
    rMeta         :: BeaconRunMeta
  , rData         :: SortedDataPoints
  , rProcessStats :: Maybe ProcessStats
  -- ^ Observed peak-memory\/IO figures for the run, when 'time -v' was
  -- available to measure it (see 'Cardano.Beacon.Run.probeTimeVerbose').
  -- Deliberately not part of 'BeaconRunMeta': this is an observation, not
  -- configuration\/provenance.
  }
  deriving Show

instance FromJSON BeaconRun where
  parseJSON = withObject "BeaconRun" $ \o ->
    BeaconRun
      <$> o .: "meta"
      <*> o .: "data"
      <*> o .:? "processStats"

toSlug :: BeaconRunMeta -> String
toSlug BeaconRunMeta{..} =
  intercalate "-" $ filter (not . null)
    [ commitShort    commit
    , verCompiler    version
    , chainShort     chain
    , applyShort     apply
    , backendVariant backend memLimit
    , memLimitPart   memLimit
    ]
  where
    commitShort = take 8 . ciCommitSHA1
    chainShort (ChainName name) = take 16 $ filter (/= '-') $ T.unpack name
    backendShort = filter (/= '-') . backendCLIOpts

    applyShort Apply   = "appl"
    applyShort Reapply = "reappl"

    -- `--lsm-no-cache` only ever applies to the LSM backend (enforced at run
    -- time), so it's folded into the backend segment itself rather than
    -- always adding its own segment: "lsm" vs "lsmnc".
    backendVariant V2LSM (Just MemLimitOpts{mloLsmNoCache = True}) =
      backendShort V2LSM ++ "nc"
    backendVariant b _ = backendShort b

    -- No memory-limiting flags at all -- either an old run predating this
    -- feature ('Nothing'), or a new one where none were requested -- must
    -- produce the exact same (empty) contribution, so both keep landing in
    -- the same slug as an unlimited run of the same configuration.
    memLimitPart (Just MemLimitOpts{mloHeapLimit = Nothing, mloMemLimit = Nothing}) = ""
    memLimitPart Nothing = ""
    memLimitPart (Just MemLimitOpts{mloHeapLimit, mloMemLimit}) =
      maybe "" ("h" ++) mloHeapLimit ++ maybe "" ("m" ++) mloMemLimit
