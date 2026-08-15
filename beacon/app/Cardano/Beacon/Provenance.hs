{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | What a distributed beacon knows without asking anyone.
--
-- Normally @beacon run@ obtains db-analyser by shelling out to
-- @nix build github:IntersectMBO/ouroboros-consensus\/\<sha\>#...@
-- ('Cardano.Beacon.Run.shellNixBuildVersion') and its commit metadata from
-- the GitHub API ('Cardano.Beacon.Run.shellCurlGitHubAPI'). Both are fine on
-- a developer machine and impossible in the SPO-facing distributable of
-- <https://github.com/input-output-hk/ouroboros-leios/issues/1048>, which has
-- neither nix nor a network.
--
-- Both are also build-time facts: the payload pins exactly one db-analyser,
-- so whoever built the payload already knew the answers. This module reads
-- them back from the payload rather than rediscovering them.
--
-- Payload layout (see @perSystem\/glue.nix@):
--
-- > bin/beacon
-- > bin/db-analyser
-- > share/provenance.json
-- > share/plan.json
--
-- Absence is not an error: a beacon built by @cabal build@ has no payload
-- around it, and must keep behaving exactly as it does today.
module Cardano.Beacon.Provenance (
    AnalyzerProvenance (..)
  , Provenance (..)
  , loadPayloadProvenance
  , provenanceCommitInfo
  , provenanceInstallInfo
  , provenanceTool
  , provenanceVersion
  ) where

import           Cardano.Beacon.Console
import           Cardano.Beacon.Types
import           Control.Exception (SomeException, try)
import           Data.Aeson
import qualified Data.ByteString as B (readFile)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           GHC.Generics (Generic)
import           System.Directory (doesFileExist)
import           System.Environment (getExecutablePath)
import           System.FilePath (takeDirectory, (</>))


data Provenance = Provenance
  { provPayloadVersion :: !Int
  , provSystem         :: !String
  , provAnalyzer       :: !AnalyzerProvenance
    -- | Helper executables shipped in the payload's @bin\/@, as
    -- name -> filename (e.g. @\"jq\" -> \"jq\"@). See 'provenanceTool'.
  , provTools          :: !(Map String FilePath)
    -- | Directory the payload's @share\/@ files live in; derived at load
    -- time, not stored in the JSON.
  , provShareDir       :: !FilePath
    -- | Directory the payload's binaries live in; likewise derived.
  , provBinDir         :: !FilePath
  }
  deriving (Show)

instance FromJSON Provenance where
  parseJSON = withObject "Provenance" $ \o -> do
    provPayloadVersion <- o .: "payloadVersion"
    provSystem         <- o .: "system"
    provAnalyzer       <- o .: "analyzer"
    provTools          <- o .:? "tools" .!= Map.empty
    -- Filled in by 'loadPayloadProvenance', which knows where it read from.
    let provShareDir = ""
        provBinDir   = ""
    pure Provenance{..}

-- | The pinned db-analyser: which one, built how.
data AnalyzerProvenance = AnalyzerProvenance
  { apName               :: !String
  , apCommit             :: !CommitInfo
    -- ^ Field names in the JSON deliberately match 'CommitInfo', so this is
    -- the very value the GitHub lookup would have produced.
  , apCompiler           :: !String
  , apAssertionsDisabled :: !Bool
  }
  deriving (Show, Generic)

instance FromJSON AnalyzerProvenance where
  parseJSON = withObject "AnalyzerProvenance" $ \o ->
    AnalyzerProvenance
      <$> o .: "name"
      <*> parseJSON (Object o)
      <*> o .: "compiler"
      <*> o .: "assertionsDisabled"

-- | Look for a payload around the running executable.
--
-- Returns 'Nothing' when there is no payload -- the ordinary development
-- case -- and only warns when a payload is present but unreadable, since that
-- means a distributable was built wrong and silently falling back to the nix
-- path would be worse than saying so.
loadPayloadProvenance :: IO (Maybe Provenance)
loadPayloadProvenance = do
  exe <- getExecutablePath
  let binDir   = takeDirectory exe
      shareDir = takeDirectory binDir </> "share"
      file     = shareDir </> "provenance.json"
  present <- doesFileExist file
  if not present
    then pure Nothing
    else do
      parsed <- try (B.readFile file >>= throwDecodeStrict')
      case parsed of
        Left (e :: SomeException) -> do
          printStyled StyleWarning $ unlines
            [ "found a payload provenance at '" ++ file ++ "' but could not read it:"
            , show e
            , "falling back to building db-analyser via nix"
            ]
          pure Nothing
        Right p -> pure $ Just p
          { provShareDir = shareDir
          , provBinDir   = binDir
          }

-- | The commit 'Cardano.Beacon.Run.shellCurlGitHubAPI' would have returned.
provenanceCommitInfo :: Provenance -> CommitInfo
provenanceCommitInfo = apCommit . provAnalyzer

-- | The 'Version' the payload was built against, for callers that would
-- otherwise require the user to pass @--rev@\/@--ghc@.
provenanceVersion :: Provenance -> Version
provenanceVersion p = Version
  { verGitRef   = ciCommitSHA1 (provenanceCommitInfo p)
  , verCompiler = apCompiler (provAnalyzer p)
  }

-- | The install 'Cardano.Beacon.Run.shellNixBuildVersion' would have produced,
-- pointing at the db-analyser shipped alongside us.
--
-- @installNixPath@ records the payload's own share directory rather than a
-- /nix/store path: on an SPO's machine there is no store, and the field is
-- only ever recorded as provenance in the run metadata.
provenanceInstallInfo :: Provenance -> InstallInfo
provenanceInstallInfo p = InstallInfo
  { installExePath  = provBinDir p </> "db-analyser"
  , installPlanPath = provShareDir p
  , installNixPath  = provShareDir p
  , installVersion  = provenanceVersion p
  }

-- | Absolute path to a helper executable shipped in the payload, if this
-- build ships one under that name.
--
-- Callers fall back to @PATH@ when this returns 'Nothing', which is what a
-- development checkout always does. The point of preferring the bundled copy
-- is not merely availability: the host's @time@ may be a BSD\/busybox one
-- with no @-v@\/@-o@, in which case beacon silently loses the peak-memory
-- and I\/O figures for the run.
provenanceTool :: Provenance -> String -> Maybe FilePath
provenanceTool p name =
  (provBinDir p </>) <$> Map.lookup name (provTools p)
