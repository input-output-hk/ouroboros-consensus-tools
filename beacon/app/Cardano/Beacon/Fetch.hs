{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Acquiring a chain fragment to benchmark.
--
-- This is version 1 of the abstract chain-synthesizer of
-- <https://github.com/input-output-hk/ouroboros-leios/issues/1048>: degenerate,
-- Praos-only, and not a synthesizer at all -- it downloads prebuilt fragments
-- named by a manifest baked into the payload (@share\/chain-manifest.json@).
-- Where they are hosted is therefore a manifest change, not a code change.
--
-- Three properties this has to get right, none optional at ~800 MiB per
-- fragment over an SPO's home connection:
--
--   * resumable, so a dropped connection does not restart from zero
--   * verified by sha256, since a truncated or substituted archive would
--     otherwise surface as an incomprehensible db-analyser failure much later
--   * honest about failure -- in particular refusing to write an error page to
--     disk and call it a zip, which is how a rate-limited or redirected
--     download typically presents itself
module Cardano.Beacon.Fetch (
    ChainManifest (..)
  , ManifestChain (..)
  , ensureChain
  , loadManifest
  , manifestChain
  ) where

import           Cardano.Beacon.Chain (BeaconChain (..), Chains (..))
import           Cardano.Beacon.Console
import           Cardano.Beacon.Types
import           Control.Exception (SomeException, try)
import           Control.Monad (unless, when)
import           Crypto.Hash.SHA256 (hashlazy)
import           Data.Aeson
import qualified Data.ByteString as B (isPrefixOf, readFile)
import qualified Data.ByteString.Base16 as B16 (encode)
import qualified Data.ByteString.Char8 as BSC (unpack)
import qualified Data.ByteString.Lazy as BL (readFile)
import           Data.List (find)
import qualified Data.Map as Map
import qualified Data.Text as T
import           System.Directory (createDirectoryIfMissing, doesDirectoryExist,
                     doesFileExist, getFileSize, listDirectory, removeDirectory,
                     removeFile, renameDirectory)
import           System.Exit (ExitCode (..))
import           System.FilePath ((</>))
import           System.Process (rawSystem)


data ChainManifest = ChainManifest
  { cmBaseUrl      :: !String
  , cmDefaultChain :: !Text
  , cmChains       :: ![ManifestChain]
  }
  deriving (Show)

instance FromJSON ChainManifest where
  parseJSON = withObject "ChainManifest" $ \o ->
    ChainManifest
      <$> o .: "baseUrl"
      <*> o .: "defaultChain"
      <*> o .: "chains"

-- | One prebuilt fragment: where to get it, how to check it, and the registry
-- entry it becomes once unpacked.
data ManifestChain = ManifestChain
  { mcName   :: !Text
  , mcFile   :: !String
  , mcSha256 :: !String
  , mcBytes  :: !Integer
  , mcChain  :: !BeaconChain
    -- ^ Parsed from the same object, so the manifest is the single source of
    -- truth for both the download and the chain-register entry it produces.
  }
  deriving (Show)

instance FromJSON ManifestChain where
  parseJSON = withObject "ManifestChain" $ \o -> do
    mcName   <- o .: "name"
    mcFile   <- o .: "file"
    mcSha256 <- o .: "sha256"
    mcBytes  <- o .: "bytes"
    mcChain  <- parseJSON (Object o)
    pure ManifestChain{..}

loadManifest :: FilePath -> IO (Maybe ChainManifest)
loadManifest path =
  doesFileExist path >>= \case
    False -> pure Nothing
    True ->
      try (B.readFile path >>= throwDecodeStrict') >>= \case
        Left (e :: SomeException) -> do
          printStyled StyleWarning $
            "could not read chain manifest '" ++ path ++ "': " ++ show e
          pure Nothing
        Right m -> pure (Just m)

-- | Look a chain up by name, defaulting to the manifest's own default.
manifestChain :: ChainManifest -> Maybe ChainName -> Either String ManifestChain
manifestChain ChainManifest{cmChains, cmDefaultChain} mName =
  case find ((== wanted) . mcName) cmChains of
    Just c  -> Right c
    Nothing -> Left $
      "no chain named '" ++ T.unpack wanted ++ "' in the manifest; available: "
      ++ T.unpack (T.intercalate ", " (map mcName cmChains))
  where
    wanted = maybe cmDefaultChain (\(ChainName n) -> n) mName

-- | Ensure a fragment is present and registered, downloading it if not.
--
-- Already-unpacked chains are left alone: at 1-2 GiB unpacked, re-fetching one
-- because a command was repeated is not a forgivable default.
ensureChain ::
     FilePath
     -- ^ @curl@ executable.
  -> FilePath
     -- ^ @unzip@ executable.
  -> FilePath
     -- ^ Chain directory (@<data-dir>\/chain@).
  -> String
     -- ^ Base URL from the manifest.
  -> ManifestChain
  -> IO ()
ensureChain curlExe unzipExe chainDir baseUrl mc@ManifestChain{..} = do
  createDirectoryIfMissing True chainDir
  let name    = T.unpack mcName
      dest    = chainDir </> name
      archive = chainDir </> mcFile

  unpacked <- doesDirectoryExist dest
  if unpacked
    then printStyled StyleInfo $ "chain '" ++ name ++ "' is already present"
    else do
      download curlExe (baseUrl ++ "/" ++ mcFile) archive mcBytes
      verifySha256 archive mcSha256
      unpack unzipExe archive dest
      -- The archive is a redundant second copy of 1-2 GiB, and the machines
      -- this is aimed at are the ones short of disk.
      removeFile archive

  registerChain chainDir mc

-- | Download with resume, refusing anything that is not the expected payload.
download :: FilePath -> String -> FilePath -> Integer -> IO ()
download curlExe url dest expectedBytes = do
  printStyled StyleInfo $
    "fetching " ++ url ++ " (" ++ showBytes expectedBytes ++ ")"

  -- -C - resumes a partial file; --fail turns an HTTP error into a non-zero
  -- exit instead of a saved error page; --location follows the redirect that
  -- release downloads always involve.
  code <- rawSystem curlExe
    [ "--fail", "--location", "--continue-at", "-"
    , "--retry", "3", "--retry-delay", "5"
    , "--output", dest
    , url
    ]
  case code of
    ExitFailure c ->
      printFatalAndDie $
        "download of '" ++ url ++ "' failed (curl exit " ++ show c ++ ")"
    ExitSuccess -> pure ()

  -- A download that "succeeded" but produced markup is a rate-limit notice, a
  -- captive portal, or a moved object. Saying so beats failing later at unzip.
  header <- B.readFile dest
  when (any (`B.isPrefixOf` header) ["<!DOCTYPE", "<html", "<HTML"]) $
    printFatalAndDie $
      "'" ++ url ++ "' returned a web page rather than an archive; the link \
      \may have moved or be rate-limited."

  actual <- getFileSize dest
  unless (actual == expectedBytes) $
    printFatalAndDie $
      "downloaded '" ++ dest ++ "' is " ++ show actual ++ " bytes, expected "
      ++ show expectedBytes

verifySha256 :: FilePath -> String -> IO ()
verifySha256 path expected = do
  printStyled StyleInfo $ "verifying " ++ path
  actual <- BSC.unpack . B16.encode . hashlazy <$> BL.readFile path
  unless (actual == expected) $
    printFatalAndDie $ unlines
      [ "checksum mismatch for '" ++ path ++ "'"
      , "  expected " ++ expected
      , "  actual   " ++ actual
      , "Refusing to benchmark an archive that is not the one this build pins."
      ]

-- | Unpack, normalizing whether or not the archive wraps its contents in a
-- single top-level directory.
unpack :: FilePath -> FilePath -> FilePath -> IO ()
unpack unzipExe archive dest = do
  printStyled StyleInfo $ "unpacking " ++ archive
  let staging = dest ++ ".unpacking"
  createDirectoryIfMissing True staging
  code <- rawSystem unzipExe ["-q", archive, "-d", staging]
  case code of
    ExitFailure c -> printFatalAndDie $ "unzip failed (exit " ++ show c ++ ")"
    ExitSuccess   -> pure ()

  -- An archive may or may not wrap its contents in a single top-level
  -- directory; normalize to `dest` either way, and do not leave the staging
  -- directory behind when it does.
  entries <- listDirectory staging
  case entries of
    [single] -> do
      isDir <- doesDirectoryExist (staging </> single)
      if isDir
        then renameDirectory (staging </> single) dest >> removeDirectory staging
        else renameDirectory staging dest
    _ -> renameDirectory staging dest

-- | Merge the fragment's entry into the chain register, so the rest of beacon
-- can find it. Replaces the @jq@ merge the import script used to do.
registerChain :: FilePath -> ManifestChain -> IO ()
registerChain chainDir ManifestChain{mcName, mcChain} = do
  existing <-
    doesFileExist registerPath >>= \case
      False -> pure Map.empty
      True ->
        try (B.readFile registerPath >>= throwDecodeStrict') >>= \case
          Left (_ :: SomeException) -> do
            printStyled StyleWarning $
              "could not parse '" ++ registerPath ++ "'; rewriting it"
            pure Map.empty
          Right (Chains m) -> pure m

  let updated = Map.insert (ChainName mcName) mcChain existing
  encodeFile registerPath (Chains updated)
  where
    registerPath = chainDir </> "chain-register.json"

showBytes :: Integer -> String
showBytes n
  | n >= gib  = show (n `div` gib) ++ "." ++ show (n * 10 `div` gib `mod` 10) ++ " GiB"
  | n >= mib  = show (n `div` mib) ++ " MiB"
  | otherwise = show (n `div` 1024) ++ " KiB"
  where
    mib = 1024 * 1024
    gib = 1024 * mib
