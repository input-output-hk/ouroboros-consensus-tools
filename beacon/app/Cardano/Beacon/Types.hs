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
import           Data.Char (isDigit, toUpper)
import           Data.Map (Map)
import           Data.Text as Text (Text)
import           Data.Time.Clock (UTCTime)
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           System.IO.Unsafe (unsafePerformIO)
import           System.PosixCompat.Process
import           Text.Read (readMaybe)


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

-- | Configuration for the memory-limiting feature of a @beacon run@: two
-- independent, alternative mechanisms for forcing the LSM backend to do real
-- disk I\/O (@mloMemLimit@, a cgroup memory pressure limit; @mloLsmNoCache@,
-- an @O_DIRECT@ CLI flag on db-analyser), plus a GHC heap cap that applies
-- regardless of which (if either) of those is used.
data MemLimitOpts = MemLimitOpts
  { mloHeapLimit  :: Maybe String
    -- ^ GHC RTS heap limit, e.g. \"2G\"; passed to db-analyser as @-M<SIZE>@.
  , mloMemLimit   :: Maybe String
    -- ^ cgroup memory limit, e.g. \"2G\"; runs db-analyser under
    -- @systemd-run --user --scope@ with this as @MemoryHigh@ (a looser,
    -- derived @MemoryMax@ acts as a hard safety net).
  , mloLsmNoCache :: Bool
    -- ^ Pass @--lsm-no-cache@ to db-analyser (bypasses the OS page cache via
    -- @O_DIRECT@ for the LSM backend's UTxO table). Requires a db-analyser
    -- build that supports the flag; see 'EnvironmentCapabilities'.
  }
  deriving (Eq, Show, Generic)

instance ToJSON MemLimitOpts where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON MemLimitOpts where
  parseJSON = genericParseJSON aesonNoTagFields

-- | What the currently-installed db-analyser build \/ host environment is
-- known to support, detected once per resolved 'InstallInfo' and cached in
-- 'Cardano.Beacon.Run.RunEnvironment' rather than re-probed per call.
data EnvironmentCapabilities = EnvironmentCapabilities
  { capOnlyImmutableDb :: Bool
    -- ^ Whether this db-analyser build supports @--only-immutable-db@.
  , capLsmNoCache      :: Bool
    -- ^ Whether this db-analyser build supports @--lsm-no-cache@.
  , capMemLimit        :: Bool
    -- ^ Whether this host's user cgroup actually enforces a memory limit set
    -- via @systemd-run --user --scope -p MemoryHigh=...@ (as opposed to
    -- silently accepting but not applying it, e.g. for lack of cgroup v2
    -- memory-controller delegation).
  , capTimeVerbose     :: Maybe FilePath
    -- ^ Resolved path to a working GNU @time -v@, or 'Nothing' if absent or
    -- non-conforming (e.g. a BSD\/busybox @time@ without @-v@\/@-o@ support).
  }
  deriving Show

-- | Peak memory\/IO figures for a single db-analyser invocation, as reported
-- by GNU @time -v@. Purely descriptive context, not a correctness check.
data ProcessStats = ProcessStats
  { statsMaxResidentSetSize :: Word64
    -- ^ Peak resident set size, in bytes.
  , statsFileSystemInputs   :: Word64
    -- ^ GNU time's \"File system inputs\": a count of block input
    -- operations (@ru_inblock@), not a byte count.
  , statsFileSystemOutputs  :: Word64
    -- ^ GNU time's \"File system outputs\": a count of block output
    -- operations (@ru_oublock@), not a byte count.
  }
  deriving (Show, Generic)

instance ToJSON ProcessStats where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON ProcessStats where
  parseJSON = genericParseJSON aesonNoTagFields

-- | Parse a size string like \"512M\", \"2G\" (M\/G suffix, base-1024,
-- case-insensitive) or a bare byte count, into a number of bytes. \'K\'\/\'T\'
-- suffixes are rejected: they're out of the realistic range for a memory
-- limit on this tool.
parseSizeBytes :: String -> Maybe Integer
parseSizeBytes s = do
  let (digits, suffix) = span isDigit s
  base <- readMaybe digits
  mult <- case map toUpper suffix of
    ""  -> Just 1
    "M" -> Just mebi
    "G" -> Just gibi
    _   -> Nothing
  pure (base * mult)

mebi, gibi :: Integer
mebi = 1024 * 1024
gibi = 1024 * 1024 * 1024

-- | Validate and canonicalize a user-supplied @--heap-limit@\/@--mem-limit@
-- size string. The canonical form is always a whole number of at most 5
-- digits followed by \'M\' or \'G\' (uppercase, no decimal point).
normalizeSize :: String -> Maybe String
normalizeSize s = case span isDigit s of
  ([], _)           -> Nothing
  (digits, suffix)  -> do
    n <- readMaybe digits
    case map toUpper suffix of
      ""  -> uncurry inRange (roundToNearestUnit n)
      "M" -> inRange n "M"
      "G" -> inRange n "G"
      _   -> Nothing
  where
    inRange n unit
      | n >= 1 && n <= 99999 = Just (show (n :: Integer) ++ unit)
      | otherwise            = Nothing

    roundToNearestUnit :: Integer -> (Integer, String)
    roundToNearestUnit bytes
      | roundedG >= 1 = (roundedG, "G")
      | otherwise     = (roundDiv bytes mebi, "M")
      where
        roundedG = roundDiv bytes gibi
        roundDiv n d = (n + d `div` 2) `div` d
