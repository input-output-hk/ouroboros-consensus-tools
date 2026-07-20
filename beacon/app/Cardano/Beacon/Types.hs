{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingVia        #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StandaloneDeriving #-}

module Cardano.Beacon.Types (
    module Cardano.Beacon.Types
  , module Text
  ) where


import           Cabal.Plan (PkgName, Ver)
import           Control.Applicative ((<|>))
import           Data.Aeson
import           Data.Map (Map)
import           Data.Text as Text (Text)
import           Data.Time.Clock (UTCTime)
import           GHC.Generics (Generic)
import           System.IO.Unsafe (unsafePerformIO)
import           System.PosixCompat.Process


{-# NOINLINE beaconProcessID #-}
beaconProcessID :: String
beaconProcessID = unsafePerformIO $
  show <$> getProcessID


data EchoCommand =
    EchoCommand
  | DoNotEchoCommand
  deriving (Eq, Show)

newtype ChainName = ChainName Text
        deriving (Eq, Ord, Show, FromJSON, FromJSONKey, ToJSON)
          via Text

data CommitInfo = CommitInfo
  { ciCommitSHA1 :: !String
  , ciCommitDate :: !UTCTime
  }
  deriving (Show, Generic)

-- this instance also parses the GitHub API query result
instance FromJSON CommitInfo where
  parseJSON a =
    parseNative a <|> parseFromGitHub a
    where
      parseNative = withObject "CommitInfo" $ \o -> do
        ciCommitSHA1 <- o .: "ciCommitSHA1"
        ciCommitDate <- o .: "ciCommitDate"
        pure CommitInfo{..}

      parseFromGitHub = withObject "CommitInfo" $ \o -> do
        ciCommitSHA1 <- o .: "sha"
        commit       <- o .: "commit"
        author       <- commit .: "author"
        ciCommitDate <- author .: "date"
        pure CommitInfo{..}

instance ToJSON CommitInfo where
  toJSON = genericToJSON aesonNoTagFields

data Version = Version {
    -- | The git commit hash or tag or branch name to build db-analyser from.
    -- Commit must be publicly visible on GitHub; shortened hashes are valid.
    verGitRef   :: String
    -- | Compiler version used to compile db-analyser.
    --
    -- This comes from the 'ouroboros-consensus' 'nix' setup.
    -- Since relying on this is brittle anyway, we do not define a type for it, and rely instead on a free-form string.
  , verCompiler :: String
  }
  deriving (Eq, Show, Generic)

instance ToJSON Version where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON Version where
  parseJSON = genericParseJSON aesonNoTagFields

newtype Manifest = Manifest (Map PkgName Ver)
  deriving (Show, Generic)

data InstallInfo = InstallInfo
  { installExePath  :: FilePath
  , installPlanPath :: FilePath
  , installNixPath  :: FilePath
  , installVersion  :: Version
  }
  deriving Show

deriving via (Map PkgName Ver) instance ToJSON Manifest
deriving via (Map PkgName Ver) instance FromJSON Manifest

aesonNoTagFields :: Options
aesonNoTagFields = defaultOptions { sumEncoding = ObjectWithSingleField }
