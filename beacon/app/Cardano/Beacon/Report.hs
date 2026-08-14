{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The thing an SPO sends back.
--
-- <https://github.com/input-output-hk/ouroboros-leios/issues/1048> asks to
-- \"make it also easy to send back reports\". The easiest possible artifact is
-- a single file, so this collects everything the Leios team needs into one
-- JSON document rather than an archive:
--
--   * what was measured -- every stored run, with its per-slot datapoints
--   * what measured it -- the payload's provenance: the pinned db-analyser
--     commit, its compiler, and the build plan behind it
--   * where it was measured -- CPU, memory, and above all the disk backing
--     the data directory
--
-- No tar, no zip, nothing to bundle, nothing for the recipient to unpack, and
-- it stays readable by anything that speaks JSON.
module Cardano.Beacon.Report (
    writeReport
  ) where

import           Cardano.Beacon.Console
import           Cardano.Beacon.SysInfo (SysInfo)
import           Control.Exception (SomeException, try)
import           Data.Aeson
import qualified Data.ByteString as B (readFile)
import           Data.List (sort)
import           Data.String (fromString)
import           Data.Time.Clock (UTCTime, getCurrentTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           System.Directory (doesDirectoryExist, doesFileExist,
                     listDirectory)
import           System.FilePath ((</>))


-- | Assemble a report from runs already stored under @\<data-dir\>\/run@.
--
-- Returns the path written. Slugs that produced no stored run are reported
-- rather than skipped silently: a report that quietly contains three
-- measurements when four were requested is worse than one that says so.
writeReport ::
     FilePath
     -- ^ beacon data directory.
  -> String
     -- ^ Host identifier, for the filename.
  -> Maybe FilePath
     -- ^ Payload provenance, if this build has one.
  -> SysInfo
  -> [String]
     -- ^ Slugs to include.
  -> IO FilePath
writeReport dataDir host mProvenancePath sysInfo slugs = do
  now <- getCurrentTime
  provenance <- maybe (pure Nothing) readJsonValue mProvenancePath

  collected <- mapM (collectSlug dataDir) slugs
  let runs    = [(slug, vals) | (slug, vals@(_ : _)) <- collected]
      missing = [slug | (slug, []) <- collected]

  mapM_ (\slug -> printStyled StyleWarning $
          "no stored runs found for '" ++ slug ++ "'; omitted from the report")
        missing

  let path = dataDir </> reportName host now
      doc = object
        [ "reportVersion" .= (1 :: Int)
        , "generatedAt"   .= now
        , "host"          .= host
        , "provenance"    .= provenance
        , "system"        .= sysInfo
        , "runs"          .= object [ fromString slug .= vals | (slug, vals) <- runs ]
        ]

  encodeFile path doc
  pure path

-- | @glue-report-\<host\>-\<utc timestamp\>.json@.
--
-- Timestamped so repeated runs on the same machine accumulate side by side
-- rather than overwriting each other, and so a mailed-back file says when it
-- was produced without anyone having to ask.
reportName :: String -> UTCTime -> FilePath
reportName host now =
  "glue-report-" ++ sanitize host ++ "-"
    ++ formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now ++ ".json"
  where
    sanitize = map (\c -> if c `elem` ("/\\ :" :: String) then '-' else c)

-- | Every stored sample for a slug, newest last.
collectSlug :: FilePath -> String -> IO (String, [Value])
collectSlug dataDir slug = do
  let dir = dataDir </> "run" </> slug
  present <- doesDirectoryExist dir
  if not present
    then pure (slug, [])
    else do
      files <- sort . filter (\f -> take 4 f == "run-") <$> listDirectory dir
      vals <- mapM (readJsonValue . (dir </>)) files
      pure (slug, [v | Just v <- vals])

readJsonValue :: FilePath -> IO (Maybe Value)
readJsonValue path =
  doesFileExist path >>= \case
    False -> pure Nothing
    True ->
      try (B.readFile path >>= throwDecodeStrict') >>= \case
        Left (e :: SomeException) -> do
          printStyled StyleWarning $
            "could not read '" ++ path ++ "' for the report: " ++ show e
          pure Nothing
        Right v -> pure (Just v)
