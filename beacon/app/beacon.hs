{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @beacon@ benchmarks a Cardano ledger + consensus integration through the
-- 'db-analyser' tool, and lets you summarize, compare, or analyse the
-- variance of results across stored runs.
--
-- It is driven by a chain of subcommands (see 'BeaconCommand'); the typical
-- flow is:
--
-- 1. @build@ -- builds 'db-analyser' for a given Consensus commit\/branch\/tag
--    via the 'db-analyser' nix flake output (see 'shellNixBuildVersion'),
--    linking the resulting binary and its build plan under the beacon data
--    directory. Invoked automatically by @run@ if not done already.
--
-- 2. @run@ -- runs the built 'db-analyser' against a registered synthetic
--    chain fragment (see @list-chains@), producing a JSON file of per-slot
--    'Cardano.Beacon.SlotDataPoint.SlotDataPoint' measurements (e.g. time
--    spent applying a block, or the memory it consumed), tagged with
--    'Cardano.Beacon.RunMeta.BeaconRunMeta' (commit, compiler, chain, apply
--    mode, backend, host, ...).
--
-- 3. @store@ -- files a run's result under the run directory, in a
--    subdirectory named after the run's slug (see
--    'Cardano.Beacon.RunMeta.toSlug', which derives it from the run's
--    metadata, minus 'host'), so repeated runs of the same configuration
--    accumulate side by side. Invoked automatically by @run@.
--
-- 4. @summary@ \/ @compare@ \/ @variance@ -- report on the stored run(s) of
--    one or two slugs, as text and Cairo-rendered plots. For @compare@, the
--    first slug given is treated as the "baseline" (see 'compareMeasurements').
--
-- * Analysis
--
-- At the moment we only analyse the results of the 'benchmark-ledger-ops'
-- 'db-analyser' analysis. See the documentation of this flag for more details.
-- We might add other 'db-analyser' analyses in the future.
--
-- * Caveats
--
-- - The tool is fragile because it assumes the resulting JSON file has a
--   certain shape, which depends on the output of 'db-analyser' - as well
--   as the CLI syntax of that binary. If the either of those has breaking
--   changes, the @beacon@ tool will fail.
--
-- * Next up:
--
-- - [ ] Create a markdown or typst report.
-- - [ ] Drop less portable Cairo rendering in favour of easyplot, or inline gnuplot inside typst.
-- - [ ] Produce an error that can be reacted to if the metrics filter (thresholed, e.g.) is violated.
-- - [ ] Allow to configure metrics filtering (eg "lower is better", pretty name, etc).
-- - [ ] Perform a statistical analysis on the measurements / wire up CDF.hs.
-- - [ ] Allow running as a service / automate inside a GitHub runner.

module Main (main) where

import           Cabal.Plan (PkgId (..), PkgName (..), PlanJson (..), Unit (..),
                     decodePlanJson)
import           Cardano.Beacon.Chain
import           Cardano.Beacon.CLI
import           Cardano.Beacon.Compare
import           Cardano.Beacon.Console
import           Cardano.Beacon.Run
import           Cardano.Beacon.RunMeta
import           Cardano.Beacon.Types
import           Control.Concurrent (threadDelay)
import           Control.Exception (SomeException, bracket_, catchJust,
                     displayException, try)
import           Control.Monad (foldM_, forM_, unless, when)
import           Control.Monad.Extra (ifM)
import           Data.Aeson (eitherDecodeFileStrict, eitherDecodeStrict',
                     encodeFile)
import           Data.Either (rights)
import           Data.List (intercalate, partition, sort, sortBy)
import qualified Data.Map as Map
import           Data.Maybe (fromJust, fromMaybe, listToMaybe, mapMaybe)
import           Data.Monoid
import           Data.Ord (Down (..), comparing)
import           Data.Time.Clock (getCurrentTime)
import           Data.Traversable (for)
import           Data.Version (showVersion)
import           Network.HostName
import qualified Paths_beacon as Paths (version)
import           System.Directory
import           System.Environment (getExecutablePath)
import           System.FilePath
import           System.IO (hClose, hPutStr)
import           System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import           System.Posix.Files (stdFileMode)
import           System.Posix.IO (OpenFileFlags (creat, exclusive),
                     OpenMode (WriteOnly), defaultFileFlags, fdToHandle, openFd)
import           Text.Printf
import           Text.Read (readMaybe)
import           Validation (Validation (..))


--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn appHeader
  (options, commands) <- getOpts

  hostName <-
    let machId = optMachineId options
    in if null machId then getHostName else pure machId
  let env = envEmpty options { optMachineId = hostName }

  ifM (doesDirectoryExist $ optBeaconDir options)
    (runCommands env commands)
    (printFatalAndDie $ "beacon data directory missing: " ++ optBeaconDir options)


-- constants

chainRegisterFilename :: FilePath
chainRegisterFilename = "chain" </> "chain-register.json"


runCommands :: RunEnvironment -> [BeaconCommand] -> IO ()
runCommands env cmds
  | null lockFile = evalCommands
  | otherwise = bracket_ acquireLock releaseLock evalCommands
  where
    evalCommands = do
      mapM_ warnDropped differing
      foldM_ runCommand env same
      where (same, differing) = sameAndDifferingVersions cmds

    warnDropped cmd = printStyled StyleWarning $
      "dropping " ++ show cmd
      ++ ": Targeting more than one revision / compiler in a single beacon invocation is not supported."

    lockFile = optLockFile $ runOptions env

    -- Atomically (O_CREAT|O_EXCL) claims the lock, retrying after a wait
    -- whenever someone else already holds it. This closes the race where two
    -- parties both observe "no lock" and both proceed to write one.
    acquireLock = tryClaim True
      where
        tryClaim firstAttempt = do
          claimed <- claimLock
          unless claimed $ do
            when firstAttempt $
              printStyled StyleInfo $ "waiting for lock to be released: " ++ lockFile
            threadDelay 1_000_000
            tryClaim False

    claimLock = catchJust
      (\e -> if isAlreadyExistsError e then Just () else Nothing)
      (do
        marker <- lockMarker
        fd     <- openFd lockFile WriteOnly
                    defaultFileFlags{ exclusive = True, creat = Just stdFileMode }
        h      <- fdToHandle fd
        hPutStr h marker
        hClose h
        pure True)
      (const $ pure False)

    -- Only remove the lock if it's still the one we created: an external
    -- tool, or another beacon process, may have raced in and re-claimed it
    -- right as we finished.
    releaseLock = do
      marker <- lockMarker
      owned  <- catchJust
        (\e -> if isDoesNotExistError e then Just () else Nothing)
        ((== marker) <$> readFile lockFile)
        (const $ pure False)
      when owned $
        catchJust
          (\e -> if isDoesNotExistError e then Just () else Nothing)
          (removeFile lockFile)
          (const $ pure ())

    -- Every beacon binary produces the same 'getExecutablePath', so pair it
    -- with 'beaconProcessID' to identify this specific run, not just any run
    -- of the same executable.
    lockMarker = (\exePath -> exePath ++ " " ++ beaconProcessID) <$> getExecutablePath

-- | Targeting more than one revision\/compiler in a single @beacon@
-- invocation is not supported; split off any command that doesn't agree
-- with the first revision\/compiler seen.
sameAndDifferingVersions :: [BeaconCommand] -> ([BeaconCommand], [BeaconCommand])
sameAndDifferingVersions cmds = partition matchesBaseline cmds
  where
    baseline = listToMaybe $ mapMaybe cmdVersion cmds

    matchesBaseline cmd = maybe True (\v -> Just v == baseline) (cmdVersion cmd)

    cmdVersion :: BeaconCommand -> Maybe Version
    cmdVersion (BeaconBuild v)         = Just v
    cmdVersion (BeaconDoRun _ v _ _ _) = Just v
    cmdVersion _                       = Nothing

runCommand :: RunEnvironment -> BeaconCommand -> IO RunEnvironment
runCommand env BeaconListChains = do
  env' <- runCommand env BeaconLoadChains
  case runChains env' of
    Nothing -> printStyled StyleWarning $
         "in: " ++ registerFile ++ "\n"
      ++ "    no registered chain fragments found"
    Just cs -> do
      mapM_ (printStyled StyleNone) $ renderChainsInfo cs
      printStyled StyleInfo $
           "in:    " ++ registerFile ++ "\n"
        ++ "found: " ++ show (countChains cs) ++ " registered chain fragment(s)"
  pure env'
  where
    registerFile = envBeaconDir env </> chainRegisterFilename

runCommand env BeaconLoadChains =
  case runChains env of
    Nothing -> do
      chains <- loadChainsInfo $ envBeaconDir env </> chainRegisterFilename
      pure $ if countChains chains > 0
        then env{ runChains = Just chains }
        else env
    Just{} -> pure env

runCommand env (BeaconLoadCommit ref) = do
  result <- shellCurlGitHubAPI env $ "/repos/IntersectMBO/ouroboros-consensus/commits/" ++ ref
  case eitherDecodeStrict' result of
    Left{} ->
      printFatalAndDie $ "could not find commit for ref '" ++ ref ++ "' on GitHub"
    Right ci -> do
      printStyled StyleInfo $ "found commit on GitHub: " ++ ciCommitSHA1 ci
      pure env{ runCommit = Just ci }

runCommand env@Env{ runCommit = Nothing } cmd@(BeaconBuild ver) = do
  env' <- runCommand env (BeaconLoadCommit $ verGitRef ver)
  runCommand env' cmd
runCommand env (BeaconBuild ver) = do
  install <- shellNixBuildVersion env ver
  printStyled StyleNone $ "installed binary is: " ++ installExePath install
  printStyled StyleNone $ "build plan is available in: " ++ installPlanPath install

  pure env {runInstall = Just install}

runCommand env@Env{ runChains = Nothing } cmd@(BeaconDoRun bChain _ _ _ _) = do
  env' <- runCommand env BeaconLoadChains
  case runChains env' >>= lookupChain bChain of
    Nothing -> printFatalAndDie $ "requested chain " ++ show bChain ++ " is not registered"
    Just{}  -> runCommand env' cmd
runCommand env@Env{ runInstall = Nothing } cmd@(BeaconDoRun _ ver _ _ _) = do
  env' <- runCommand env (BeaconBuild ver)
  runCommand env' cmd
runCommand env@Env{..} (BeaconDoRun bChain ver count apply mBackend) = do
  printStyled StyleInfo "performing run..."

  manifest <- mkManifest $ fromJust runInstall
  date <- getCurrentTime
  let meta = mkMeta date manifest
  shellRunDbAnalyser env apply backend beaconChain currentData
  encodeFile currentMeta meta
  shellMergeMetaAndData env currentMeta currentData currentRun

  forM_ [currentMeta, currentData]
    removeFile
  _ <- runCommand env (BeaconStoreRun currentRun)

  -- For accurate benchmarks, repeating runs are to be done sequentially(!)
  -- to avoid any undesired improvements due to data sharing / caching.
  -- Do not change this to a parallel run strategy.
  if count > 1
    then runCommand env (BeaconDoRun bChain ver (count - 1) apply mBackend)
    else pure env{ runInstall = Nothing }
  where
    currentData   = envBeaconDir env </> "beacon-slotdata" <.> beaconProcessID <.> "json"
    currentMeta   = envBeaconDir env </> "beacon-metadata" <.> beaconProcessID <.> "json"
    currentRun    = envBeaconDir env </> "beacon-result"   <.> beaconProcessID <.> "json"
    beaconChain   = fromJust $ runChains >>= lookupChain bChain
    backend       = fromMaybe V2InMem mBackend
    mkMeta date manifest = BeaconRunMeta {
        commit  = fromJust runCommit
      , version = ver
      , chain   = bChain
      , nixPath = installNixPath $ fromJust runInstall
      , host    = optMachineId runOptions
      , ..
      }

runCommand env (BeaconStoreRun file) = do
  run <- eitherDecodeFileStrict file
  case run of
    Left err -> printFatalAndDie $
      "doesn't seem to be a beacon run result JSON: " ++ file
      ++ "\n" ++ show err
    Right (BeaconRun meta _) -> do
      let slugDir = runDir </> toSlug meta
      createDirectoryIfMissing True slugDir
      target <- nextUnusedFilename slugDir
      let dest = slugDir </> target
      printStyled StyleNone $ "moving file to: " ++ dest
      renameFile file dest
  pure env
  where
    runDir = envBeaconDir env </> "run"

runCommand env@Env{ runChains = Nothing } cmd@BeaconCompare{} = do
  env' <- runCommand env BeaconLoadChains
  runCommand env' cmd
-- | Compares only the first stored sample (@run-001.json@) of each slug,
-- not every run recorded under it. This is a known, deliberate limitation:
-- runs sharing a slug are guaranteed identical only along the fields
-- 'Cardano.Beacon.RunMeta.toSlug' derives it from (commit/compiler/chain
-- /apply mode/backend) -- notably *not* 'host', since the same
-- configuration may legitimately be benchmarked on different hardware.
-- A single sample therefore isn't guaranteed representative of the whole
-- slug. The intended fix is to compare the combined distribution of all
-- samples in a slug rather than one arbitrary run, using
-- 'Cardano.Beacon.CDF.combineCDFs' (implemented, but not yet wired up here).
runCommand env@Env{ runChains = Just chains } (BeaconCompare slugA mSlugB) = do
  readA <- eitherDecodeFileStrict $ runDir </> slugA </> "run-001.json"
  readB <- maybe
    (pure $ Left "summary only requested")
    (\slugB -> eitherDecodeFileStrict $ runDir </> slugB </> "run-001.json")
    mSlugB

  case (mSlugB, readA, readB) of
    (Just{},  Right runA, Right runB) -> doCompare chains runA runB
    (Nothing, Right runA, _)          -> doCompare chains runA Nothing
    _                                 -> printFatalAndDie "could not read / parse specified slugs"

  pure env
  where
    runDir = envBeaconDir env </> "run"

runCommand env (BeaconVariance slug) = do
  results <- sort <$> listDirectory (runDir </> slug)
  parses  <- mapM (\f -> eitherDecodeFileStrict $ runDir </> slug </> f) results
  doVariance $ rights parses
  pure env
  where
    runDir = envBeaconDir env </> "run"

-- | A single sample is sufficient here: unlike 'BeaconCompare' against a
-- second slug, a summary only reports on one slug, and all fields the slug
-- is derived from are guaranteed identical across its stored runs.
runCommand env (BeaconSummary slug) =
  runCommand env (BeaconCompare slug Nothing)


nextUnusedFilename :: FilePath -> IO FilePath
nextUnusedFilename inSlugDir = do
  fileNamesDesc <- sortBy (comparing Down) <$> listDirectory inSlugDir
  let target =
        indexedName
        $ maybe 1 (+ 1)
        $ getAlt
        $ mconcat
        $ map (Alt . parseFileName) fileNamesDesc

  -- The only legitimate way to land on the very first name is an empty slug
  -- dir. Seeing it with existing runs present means none of them parsed as a
  -- run-NNN.json index (or one is indexed 000), so we're about to overwrite.
  when (target == indexedName 1 && not (null fileNamesDesc)) $
    printStyled StyleWarning $
      "next run for " ++ inSlugDir ++ " computed as " ++ target
      ++ " despite existing runs in this slug; this will overwrite a run"

  pure target
  where
    indexedName :: Int -> FilePath
    indexedName = printf "run-%03d.json" . max 1 . min 999

    parseFileName fn
      | length fn /= 12 || takeExtension fn /= ".json" = Nothing
      | otherwise = readMaybe $ take 3 $ drop 4 fn


mkManifest :: InstallInfo -> IO Manifest
mkManifest InstallInfo{installPlanPath} =
  try (decodePlanJson installPlan) >>= \case
    Left (ex :: SomeException) -> do
      printStyled StyleWarning $ displayException ex  ++ "; continuing with empty Manifest"
      pure $ Manifest Map.empty
    Right (pjUnits -> units) ->
      let mPkgVers =
            for manifestPackages $ \pn ->
              maybe
                (Failure [pn])
                (Success . uPId)
                (findPackage units pn)
      in case mPkgVers of
        Failure missingPkgs ->
          printFatalAndDie $
            unlines
              [ "The following packages are missing from db-analyser's build plan!\n",
                intercalate "," (map show missingPkgs)
              ]
        Success pkgVers ->
          return $ Manifest $ Map.fromList [(pn, pv) | PkgId pn pv <- pkgVers]
  where
    installPlan = installPlanPath </> "plan.json"
    findPackage units pn =
      listToMaybe
        [ unit | unit <- Map.elems units, PkgId pn' _pver <- [uPId unit], pn' == pn
        ]

    manifestPackages =
      map
        PkgName
        [ "ouroboros-consensus",
          "ouroboros-network",
          "cardano-ledger-core",
          "plutus-core",
          "cardano-crypto",
          "cardano-prelude"
        ]


appHeader :: String
appHeader = unlines
  [ "┳┓"
  , "┣┫┏┓┏┓┏┏┓┏┓"
  , "┻┛┗ ┗┻┗┗┛┛┗     v" ++ showVersion Paths.version
  , "Benchmarking, exploration, and analysis of Consensus"
  ]
