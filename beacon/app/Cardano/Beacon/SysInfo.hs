{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | What machine produced a measurement.
--
-- <https://github.com/input-output-hk/ouroboros-leios/issues/1048> asks to
-- \"gather system information like cpu and disk info\", and disk in particular
-- is not a nicety: the benchmark's headline configuration bypasses the OS page
-- cache specifically to put real disk I\/O on the measured path. A number from
-- an NVMe SSD and the same number from a spinning disk or a network filesystem
-- are not comparable, and a report that does not say which is nearly
-- uninterpretable.
--
-- Everything here is read from the kernel's own interfaces -- @\/proc@ and
-- @\/sys@ on Linux, @sysctl@ on Darwin -- so it adds nothing to what has to be
-- bundled. Every field is optional: this is descriptive context, and failing a
-- benchmark because a kernel did not expose a file would be absurd.
module Cardano.Beacon.SysInfo (
    DiskInfo (..)
  , SysInfo (..)
  , collectSysInfo
  ) where

import           Cardano.Beacon.Types (aesonNoTagFields)
import           Control.Exception (SomeException, try)
import           Data.Aeson
import           Data.Char (isDigit, isSpace)
import           Data.List (dropWhileEnd, isPrefixOf)
import           Data.Maybe (listToMaybe)
import           GHC.Generics (Generic)
import           System.Directory (doesFileExist)
import           System.FilePath ((</>))
import           System.Info (arch, os)
import           System.Process (readProcess)
import           Text.Read (readMaybe)


data SysInfo = SysInfo
  { siOs          :: !String
  , siArch        :: !String
  , siCpuModel    :: !(Maybe String)
  , siCpuCores    :: !(Maybe Int)
    -- ^ Logical CPUs as the OS reports them.
  , siMemTotalKb  :: !(Maybe Integer)
  , siKernel      :: !(Maybe String)
  , siDataDisk    :: !(Maybe DiskInfo)
    -- ^ The device backing the benchmark's data directory -- the one whose
    -- latency the on-disk configurations are measuring.
  }
  deriving (Show, Generic)

instance ToJSON SysInfo where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON SysInfo where
  parseJSON = genericParseJSON aesonNoTagFields

data DiskInfo = DiskInfo
  { diDevice     :: !(Maybe String)
  , diModel      :: !(Maybe String)
  , diRotational :: !(Maybe Bool)
    -- ^ 'Just' 'True' means a spinning disk, which changes how the
    -- page-cache-bypassing numbers should be read entirely.
  , diFilesystem :: !(Maybe String)
    -- ^ A network filesystem here invalidates the disk measurements outright,
    -- so it is worth recording even though it is not a property of a disk.
  }
  deriving (Show, Generic)

instance ToJSON DiskInfo where
  toJSON = genericToJSON aesonNoTagFields

instance FromJSON DiskInfo where
  parseJSON = genericParseJSON aesonNoTagFields

-- | Gather what this kernel is willing to tell us about the machine.
collectSysInfo :: FilePath -> IO SysInfo
collectSysInfo dataDir = do
  siCpuModel   <- cpuModel
  siCpuCores   <- cpuCores
  siMemTotalKb <- memTotalKb
  siKernel     <- kernel
  siDataDisk   <- diskFor dataDir
  pure SysInfo{siOs = os, siArch = arch, ..}

-- Reading a file that may not exist is the normal case here, not an error.
tryRead :: FilePath -> IO (Maybe String)
tryRead path =
  doesFileExist path >>= \case
    False -> pure Nothing
    True ->
      try (readFile path) >>= \case
        Left (_ :: SomeException) -> pure Nothing
        Right s                   -> pure (Just s)

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

tryProcess :: String -> [String] -> IO (Maybe String)
tryProcess cmd args =
  try (readProcess cmd args "") >>= \case
    Left (_ :: SomeException) -> pure Nothing
    Right s                   -> pure (Just (trim s))

-- | Value of the first @key: value@ line in /proc-style output.
procField :: String -> String -> Maybe String
procField key contents =
  listToMaybe
    [ trim (drop 1 after)
    | line <- lines contents
    , let (k, after) = break (== ':') line
    , trim k == key
    , not (null after)
    ]

cpuModel :: IO (Maybe String)
cpuModel
  | isDarwin  = tryProcess "sysctl" ["-n", "machdep.cpu.brand_string"]
  | otherwise = do
      mInfo <- tryRead "/proc/cpuinfo"
      pure $ mInfo >>= \info ->
        procField "model name" info
          -- arm64 Linux has no "model name"; it reports implementer/part
          -- codes instead, which is still better than nothing.
          `orElse` procField "Model" info
          `orElse` procField "CPU implementer" info

cpuCores :: IO (Maybe Int)
cpuCores
  | isDarwin  = (>>= readMaybe) <$> tryProcess "sysctl" ["-n", "hw.logicalcpu"]
  | otherwise = do
      mInfo <- tryRead "/proc/cpuinfo"
      pure $ mInfo >>= \info ->
        case length [() | l <- lines info, "processor" `isPrefixOf` trim l] of
          0 -> Nothing
          n -> Just n

memTotalKb :: IO (Maybe Integer)
memTotalKb
  | isDarwin = do
      mBytes <- tryProcess "sysctl" ["-n", "hw.memsize"]
      pure $ (`div` 1024) <$> (mBytes >>= readMaybe)
  | otherwise = do
      mInfo <- tryRead "/proc/meminfo"
      pure $ mInfo >>= procField "MemTotal" >>= readMaybe . takeWhile isDigit

kernel :: IO (Maybe String)
kernel = tryProcess "uname" ["-sr"]

-- | Identify the device backing a directory, and what kind of device it is.
--
-- Linux only in any detail: Darwin is a developer convenience here, and the
-- machines whose disks matter for ouroboros-leios#1048 are Linux ones.
diskFor :: FilePath -> IO (Maybe DiskInfo)
diskFor dir
  | isDarwin = do
      dev <- tryProcess "sh" ["-c", "df -P " ++ quote dir ++ " | tail -1 | awk '{print $1}'"]
      pure $ Just DiskInfo
        { diDevice = dev
        , diModel = Nothing
        , diRotational = Nothing
        , diFilesystem = Nothing
        }
  | otherwise = do
      dev    <- tryProcess "sh" ["-c", "df -P " ++ quote dir ++ " | tail -1 | awk '{print $1}'"]
      fsType <- tryProcess "sh" ["-c", "df -PT " ++ quote dir ++ " 2>/dev/null | tail -1 | awk '{print $2}'"]
      -- Ask sysfs which whole disk a partition belongs to rather than doing
      -- string surgery on the name: sda1 is a partition of sda, but nvme0n1 is
      -- itself a whole disk while nvme0n1p2 is a partition of it, and no
      -- suffix rule gets both right.
      disk <- tryProcess "sh" ["-c", unwords
        [ "n=$(basename $(df -P", quote dir, "| tail -1 | awk '{print $1}'));"
        , "if [ -e /sys/class/block/$n/partition ];"
        , "then basename $(dirname $(readlink -f /sys/class/block/$n));"
        , "else echo $n; fi"
        ]]
      model <- readDiskAttr disk "device/model"
      rot   <- readDiskAttr disk "queue/rotational"
      pure $ Just DiskInfo
        { diDevice     = dev
        , diModel      = model
        , diRotational = (== "1") <$> rot
        , diFilesystem = fsType
        }
  where
    readDiskAttr Nothing  _    = pure Nothing
    readDiskAttr (Just d) attr =
      fmap trim <$> tryRead ("/sys/block" </> d </> attr)

-- Paths here come from beacon's own configuration rather than a benchmarked
-- chain, but these strings reach a shell, so do not hand it anything clever.
quote :: String -> String
quote s = "'" ++ concatMap esc s ++ "'"
  where
    esc '\'' = "'\\''"
    esc c    = [c]

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just a) _ = Just a
orElse Nothing b  = b

isDarwin :: Bool
isDarwin = os == "darwin"
