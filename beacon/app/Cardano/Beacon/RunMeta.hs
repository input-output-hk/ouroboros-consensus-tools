{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DerivingVia       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Cardano.Beacon.RunMeta (module Cardano.Beacon.RunMeta) where

import           Cardano.Beacon.CLI (ApplyMode (..), Backend, backendCLIOpts)
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
  }
  deriving (Show, Generic)

instance ToJSON BeaconRunMeta where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON BeaconRunMeta where
  parseJSON = genericParseJSON aesonNoTagFields

data BeaconRun = BeaconRun {
    rMeta :: BeaconRunMeta
  , rData :: SortedDataPoints
  }
  deriving Show

instance FromJSON BeaconRun where
  parseJSON = withObject "BeaconRun" $ \o ->
    BeaconRun
      <$> o .: "meta"
      <*> o .: "data"

toSlug :: BeaconRunMeta -> String
toSlug BeaconRunMeta{..} =
  intercalate "-"
    [ commitShort   commit
    , verCompiler   version
    , chainShort    chain
    , applyShort    apply
    , backendShort  backend
    ]
  where
    commitShort = take 8 . ciCommitSHA1
    chainShort (ChainName name) = take 16 $ filter (/= '-') $ T.unpack name
    backendShort = filter (/= '-') . backendCLIOpts

    applyShort Apply   = "appl"
    applyShort Reapply = "reappl"
