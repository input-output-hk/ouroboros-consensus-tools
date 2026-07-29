{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Cardano.Beacon.Run (
    ConsoleStyle (..)
  , RunEnvironment (..)
  , detectEnvironmentCapabilities
  , envBeaconDir
  , envEchoing
  , envEmpty
  , shellCurlGitHubAPI
  , shellMergeMetaAndData
  , shellNixBuildVersion
  , shellRunDbAnalyser
  ) where

import           Cardano.Beacon.Chain
import           Cardano.Beacon.CLI (ApplyMode (..), Backend (..),
                     BeaconOptions (..), backendCLIOpts)
import           Cardano.Beacon.Console
import           Cardano.Beacon.Types
import           Control.Exception (SomeException (..), finally, try)
import           Control.Monad (void, when)
import           Data.ByteString.Char8 as BSC (ByteString, pack, readFile,
                     unpack, writeFile)
import           Data.Char (isSpace)
import           Data.List (dropWhileEnd, isInfixOf, isPrefixOf)
import           Data.Maybe (fromJust, isJust, listToMaybe)
import           System.Directory (createDirectoryIfMissing, doesFileExist,
                     findExecutable, removeFile)
import           System.FilePath (isRelative, (<.>), (</>))
import           System.Process hiding (env)
import           Text.Read (readMaybe)


data RunEnvironment = Env
  { runChains       :: Maybe Chains
  , runCommit       :: Maybe CommitInfo
  , runInstall      :: Maybe InstallInfo
  , runCapabilities :: Maybe EnvironmentCapabilities
  , runOptions      :: BeaconOptions
  }

envEchoing :: RunEnvironment -> EchoCommand
envEchoing = optEchoing . runOptions

envBeaconDir :: RunEnvironment -> FilePath
envBeaconDir = optBeaconDir . runOptions

envEmpty :: BeaconOptions -> RunEnvironment
envEmpty = Env Nothing Nothing Nothing Nothing


-- All commands are currently passed to the shell verbatim, unescaped.
-- This enables using shell features like piping when developing new commands.
-- However, this also removes a thin safety net vs using `proc`, so keep that in mind while working on shell commands.
--
-- Furthermore, `beacon` currently assumes a trusted / isolated enviroment and sanitized user input.
-- If, in the future, `beacon` should ever rely on untrusted user input as part of some remote-controlled
-- automation, sanitization will need to be added - e.g. of file paths read from the chain registry and similar.
runShellEchoing :: EchoCommand -> String -> [String] -> IO String
runShellEchoing echo cmd args =
  tryShellEchoing echo cmd args >>= \case
    Left (SomeException e)  -> printFatalAndDie $ show e
    Right out               -> pure out

-- A non-fatal variant of 'runShellEchoing', for callers that need to probe
-- whether a command is usable at all (e.g. 'probeTimeVerbose') rather than
-- treating any failure as fatal to the whole beacon invocation.
tryShellEchoing :: EchoCommand -> String -> [String] -> IO (Either SomeException String)
tryShellEchoing echo cmd args = do
  when (echo == EchoCommand) $
    printStyled StyleEcho asOneLine
  try (readCreateProcess (shell asOneLine) "")
  where
    asOneLine = concat [cmd, " ", unwords args]

-- cf. https://docs.github.com/en/rest/commits/commits?apiVersion=2022-11-28#get-a-commit
shellCurlGitHubAPI :: RunEnvironment -> String -> IO ByteString
shellCurlGitHubAPI env queryPath = do
  _ <- runShellEchoing (envEchoing env) "curl" curlArgs
  result <- BSC.readFile tempFile
  removeFile tempFile
  pure result
  where
    tempFile = envBeaconDir env </> "temp.curl" <.> beaconProcessID <.> "json"
    curlArgs =
      [ "-s -L"
      , "-H \"Accept: application/vnd.github+json\""
      , "-H \"X-GitHub-Api-Version: 2022-11-28\""
      , "-o", tempFile
      , "https://api.github.com" ++ queryPath
      ]

shellNixBuildVersion :: RunEnvironment -> Version -> IO InstallInfo
shellNixBuildVersion env ver@Version{verCompiler = compiler} = do
  exists <- doesFileExist exePath
  if exists
    then printStyled StyleInfo "target binary already built and linked"
    else do
      currentSystem <- runShellEchoing echoing "nix" nixGetSystemArgs
      printStyled StyleInfo $ "host system identified as " ++ currentSystem

      let
        exeDrv  = "hydraJobs." ++ currentSystem ++ ".native."
                  ++ compiler
                  ++ ".exesNoAsserts.db-analyser"
        -- `hydraJobs.<system>.native.<compiler>.build` only exists on Linux:
        -- consensus's CI skips generating it elsewhere to reduce load (see
        -- `exesOnly` in ouroboros-consensus's nix/ci.nix). `legacyPackages`
        -- exposes the same underlying package set on every platform; its
        -- `hsPkgs.ouroboros-consensus.project.plan-nix` carries the exact same
        -- (shared, project-wide) build plan without touching any of the
        -- CI-gated `build` jobs.
        planDrv = "legacyPackages." ++ currentSystem ++ "." ++ hsPkgsPath compiler
                  ++ "ouroboros-consensus.project.plan-nix"
        hsPkgsPath = \case
          "haskell914" -> "hsPkgs.projectVariants.ghc914.hsPkgs."
          _            -> "hsPkgs."

      createDirectoryIfMissing False binDir
      void $ runShellEchoing echoing "nix" (nixBuildArgs exeDrv linkExe)
      void $ runShellEchoing echoing "nix" (nixBuildArgs planDrv linkPlan)

  nix_path <- runShellEchoing echoing "readlink" [linkExe]
  return $ InstallInfo {
    installExePath  = exePath,
    installPlanPath = linkPlan,
    installNixPath  = head . lines $ nix_path,
    installVersion  = ver
  }
  where
    echoing  = envEchoing env
    sha      = ciCommitSHA1 . fromJust . runCommit $ env
    binDir   = envBeaconDir env </> "bin"
    tag      = take 9 sha ++ "-" ++ compiler
    linkExe  = binDir </> tag
    linkPlan = binDir </> tag <.> "plan-json"
    exePath  = linkExe </> "bin" </> "db-analyser"

    flakeRef    = "github:IntersectMBO/ouroboros-consensus/" ++ sha

    nixBuildArgs drvPath outLink = ["build", flakeRef ++ "#" ++ drvPath, "-o", outLink]
    nixGetSystemArgs             = ["eval", "--impure", "--raw", "--expr", "'builtins.currentSystem'"]

shellRunDbAnalyser :: RunEnvironment -> ApplyMode -> Backend -> MemLimitOpts -> BeaconChain -> FilePath -> IO (Maybe ProcessStats)
shellRunDbAnalyser env applMode backend memLimitOpts BeaconChain{..} outFile = do
  when (mloLsmNoCache memLimitOpts && backend /= V2LSM) $
    printFatalAndDie "--lsm-no-cache only makes sense together with --lsm"

  when (mloLsmNoCache memLimitOpts && not (capLsmNoCache caps)) $
    printFatalAndDie $
         "--lsm-no-cache was requested, but this db-analyser build does not "
      ++ "support it (missing from its --help output); build db-analyser "
      ++ "from a commit that includes it."

  when (isJust (mloMemLimit memLimitOpts) && not (capMemLimit caps)) $
    printFatalAndDie
      "--mem-limit requested, but this host can't enforce it (no \
      \systemd-run, or missing cgroup delegation) -- run would go \
      \unconstrained."

  processStats <- runDbAnalyser dbAnalyser (dbAnalyserArgs <> onlyImmutableFlag <> lsmNoCacheFlag)
  callJQ echoing outFile jqToListArgs
  removeFile tempResult
  pure processStats
  where
    caps = fromJust $ runCapabilities env

    -- These are the compiled-in options specified in cardano-node.cabal, used for relese builds.
    -- We adhere to those for maximum fidelity of beacon benchmarks.
    rtsOpts = "-T -I0 -A16m -N2 -qb1 -qg1 --disable-delayed-os-memory-return"
      ++ maybe "" (" -M" ++) (mloHeapLimit memLimitOpts)

    dbAnalyser  = installExePath . fromJust . runInstall $ env
    tempResult  = envBeaconDir env </> "temp.result"  <.> beaconProcessID <.> "json"
    echoing     = envEchoing env

    chDir
      | isRelative chHomeDir  = envBeaconDir env </> "chain" </> chHomeDir
      | otherwise             = chHomeDir

    dbAnalyserArgs = filter (not . null)
      [ "--db", chDir </> chDbDir
      , maybe "" (\s -> "--analyse-from " ++ show s) chFromSlot
      , "--benchmark-ledger-ops"
      , if applMode == Reapply then "--reapply" else ""
      , "--out-file", tempResult
      , maybe "" (\b -> "--num-blocks-to-process " ++ show b) chProcessBlocks
      , backendCLIOpts backend
      , "--config", chDir </> chConfigFile
      , "+RTS", rtsOpts, "-RTS"
      ]

    onlyImmutableFlag = ["--only-immutable-db" | capOnlyImmutableDb caps]
    lsmNoCacheFlag    = ["--lsm-no-cache" | mloLsmNoCache memLimitOpts]

    jqToListArgs =
      [ "-M"
      , "'map(inputs)'"
      , tempResult
      ]

    -- Wraps the actual db-analyser invocation with `time -v` (if a working
    -- one was detected for this environment) and, if requested, a cgroup
    -- memory limit via systemd-run. The two wrap independently: `time -v`
    -- always measures through to the real db-analyser process, whether or
    -- not it's also cgroup-confined.
    runDbAnalyser cmd args = do
      let (timedCmd, timedArgs, mTimeReport) = wrapWithTime cmd args
          (finalCmd, finalArgs)              = wrapWithMemLimit timedCmd timedArgs
      _ <- runShellEchoing echoing finalCmd finalArgs
      maybe (pure Nothing) readProcessStats mTimeReport

    wrapWithTime cmd args = case capTimeVerbose caps of
      Nothing      -> (cmd, args, Nothing)
      Just timeExe -> (timeExe, ["-v", "-o", timeReportFile, "--", cmd] ++ args, Just timeReportFile)
      where
        timeReportFile = envBeaconDir env </> "temp.time-report" <.> beaconProcessID

    wrapWithMemLimit cmd args = case mloMemLimit memLimitOpts of
      Nothing   -> (cmd, args)
      Just size ->
        ( "systemd-run"
        , [ "--user", "--scope", "--collect", "--quiet"
          , "-p", "MemoryHigh=" ++ size
          , "-p", "MemoryMax="  ++ deriveMemMax size
          , "--", cmd
          ] ++ args
        )

    -- A hard MemoryMax safety net, 25% above the requested MemoryHigh, so a
    -- transient overshoot doesn't get SIGKILLed at the exact same threshold
    -- MemoryHigh is meant to gracefully pressure against.
    deriveMemMax size = maybe size (show . (`div` 4) . (* 5)) (parseSizeBytes size)

    readProcessStats reportFile = do
      exists <- doesFileExist reportFile
      if not exists
        then pure Nothing
        else do
          report <- BSC.unpack <$> BSC.readFile reportFile
          removeFile reportFile
          pure $ parseTimeVerboseReport report

-- | Detects, what the targeted db-analyser binary and host environment support,
-- so downstream command-building never has to re-probe (or thread loose booleans around).
detectEnvironmentCapabilities :: RunEnvironment -> IO EnvironmentCapabilities
detectEnvironmentCapabilities Env{ runInstall = Nothing } =
  printFatalAndDie "detectEnvironmentCapabilities: missing db-analyser install path"
detectEnvironmentCapabilities env@Env{ runInstall = Just install } = do
  helpOut <- words <$> runShellEchoing (envEchoing env) (installExePath install) ["--help"]
  timeVerbose <- probeTimeVerbose env
  memLimit    <- probeMemLimit env
  pure EnvironmentCapabilities
    { capOnlyImmutableDb = "--only-immutable-db" `elem` helpOut
    , capLsmNoCache      = "--lsm-no-cache" `elem` helpOut
    , capMemLimit        = memLimit
    , capTimeVerbose     = timeVerbose
    }

-- Functionally verifies that a `time` binary resolved from PATH actually
-- behaves like GNU time's `-v` (BSD/busybox `time` variants don't support
-- `-v`/`-o` at all, and beacon may not always be run from a nix shell that
-- guarantees GNU time is what's on PATH). If it doesn't, warns and continues
-- without I/O/RSS metrics rather than failing the run.
probeTimeVerbose :: RunEnvironment -> IO (Maybe FilePath)
probeTimeVerbose env = do
  mPath <- findExecutable "time"
  case mPath of
    Nothing   -> unavailable "no 'time' binary found on PATH"
    Just path -> probe path `finally` cleanupProbeFile
  where
    echoing   = envEchoing env
    probeFile = envBeaconDir env </> "temp.time-probe" <.> beaconProcessID

    cleanupProbeFile = do
      exists <- doesFileExist probeFile
      when exists $ removeFile probeFile

    probe path = do
      result <- tryShellEchoing echoing path ["-v", "-o", probeFile, "--", "true", "2>/dev/null"]
      case result of
        Left SomeException{} -> unavailable "'time' binary does not accept -v/-o"
        Right{} -> do
          exists <- doesFileExist probeFile
          if not exists
            then unavailable "'time -v' produced no report file"
            else do
              report <- BSC.unpack <$> BSC.readFile probeFile
              if all (`isInfixOf` report) timeVerboseMarkers
                then pure (Just path)
                else unavailable "'time -v' output missing expected fields (not GNU time?)"

    unavailable reason = do
      printStyled StyleWarning $
           "'time -v' unavailable (" ++ reason ++ "); "
        ++ "peak-memory / I/O metrics will not be collected for this run"
      pure Nothing

timeVerboseMarkers :: [String]
timeVerboseMarkers =
  [ "Maximum resident set size"
  , "File system inputs"
  , "File system outputs"
  ]

-- Verifies '--mem-limit' would actually be enforced here: covers both a
-- missing `systemd-run` (e.g. Darwin) and a present-but-non-delegating
-- cgroup, by spinning up a throwaway scope and reading its MemoryHigh back
-- from its own cgroup.
probeMemLimit :: RunEnvironment -> IO Bool
probeMemLimit env = do
  result <- tryShellEchoing echoing "systemd-run"
    [ "--user", "--scope", "--collect", "--quiet"
    , "-p", "MemoryHigh=" ++ probeSize
    , "--", "sh", "-c"
    , "'cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.high'"
    , "2>/dev/null"
    ]
  pure $ case result of
    Left{}    -> False
    Right out -> dropWhileEnd isSpace out == show probeSizeBytes
  where
    echoing        = envEchoing env
    probeSize      = "100M"
    probeSizeBytes = fromJust $ parseSizeBytes probeSize

parseTimeVerboseReport :: String -> Maybe ProcessStats
parseTimeVerboseReport report =
  ProcessStats
    <$> ((* 1024) <$> field "Maximum resident set size (kbytes): ")
    <*> field "File system inputs: "
    <*> field "File system outputs: "
  where
    field label = listToMaybe
      [ n
      | line <- lines report
      , let trimmed = dropWhile isSpace line
      , label `isPrefixOf` trimmed
      , Just n <- [readMaybe (drop (length label) trimmed)]
      ]

shellMergeMetaAndData :: RunEnvironment -> FilePath -> FilePath -> Maybe FilePath -> FilePath -> IO ()
shellMergeMetaAndData env srcMeta srcData mSrcStats dest =
  callJQ (envEchoing env) dest $ case mSrcStats of
    Nothing ->
      [ "-M"
      , "'{\"meta\": $meta[0], \"data\": $data[0]}'"
      , "--slurpfile", "meta", srcMeta
      , "--slurpfile", "data", srcData
      , "--null-input"
      ]
    Just srcStats ->
      [ "-M"
      , "'{\"meta\": $meta[0], \"data\": $data[0], \"processStats\": $stats[0]}'"
      , "--slurpfile", "meta", srcMeta
      , "--slurpfile", "data", srcData
      , "--slurpfile", "stats", srcStats
      , "--null-input"
      ]

callJQ :: EchoCommand -> FilePath -> [String] -> IO ()
callJQ echoing dest jqArgs = do
  out <- BSC.pack <$> runShellEchoing echoing "jq" jqArgs
  BSC.writeFile dest out
