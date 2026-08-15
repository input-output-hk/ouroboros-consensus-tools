{-# LANGUAGE NamedFieldPuns #-}

-- | The SPO-facing benchmark: one command, sane defaults, a report at the end.
--
-- beacon's existing surface (@--rev@, @build@, @run@, @compare@, @variance@)
-- is a developer's tool for comparing consensus revisions. Someone who
-- downloaded a distributable to help measure their hardware should not have to
-- learn it, so @beacon benchmark@ expands into the same runs a developer would
-- have typed by hand.
--
-- What it runs mirrors @scripts\/run-received-chains-lsmnc-benchmark.sh@, which
-- is what the Leios team has actually been running:
--
--   * the in-memory backend, to measure the ledger without disk in the way
--   * the LSM backend with the OS page cache bypassed, which is the
--     configuration that puts real disk I\/O on the measured path
--
-- each in both apply (full validation) and reapply (trusted re-application)
-- mode -- reapply being the one on the block-diffusion critical path that
-- ouroboros-leios#1048 is ultimately about.
module Cardano.Beacon.Benchmark (
    BenchmarkPlan (..)
  , PlannedRun (..)
  , benchmarkPlan
  ) where

import           Cardano.Beacon.CLI (ApplyMode (..), Backend (..),
                     BeaconCommand (..))
import           Cardano.Beacon.RunMeta (mkSlug)
import           Cardano.Beacon.Types


-- | One configuration to measure, and the slug its results will land under.
data PlannedRun = PlannedRun
  { prLabel   :: !String
    -- ^ Human-readable, for progress output.
  , prSlug    :: !String
    -- ^ Where the run will be stored; known in advance so the summary can be
    -- requested without parsing beacon's own output for it (which is what the
    -- shell script had to do).
  , prCommand :: !BeaconCommand
  }

data BenchmarkPlan = BenchmarkPlan
  { bpRuns    :: ![PlannedRun]
  , bpSkipped :: ![String]
    -- ^ Configurations left out because this db-analyser cannot do them,
    -- with the reason. Reported rather than silently dropped: a report with
    -- fewer measurements than expected should say why.
  }

-- | Build the set of runs for a chain.
--
-- Configurations the bundled db-analyser does not support are skipped with a
-- reason instead of attempted. That is not hypothetical: @--lmdb@ and
-- @--only-immutable-db@ have both disappeared from db-analyser, and a
-- distributable pinned to such a build must degrade legibly rather than fail
-- halfway through a long benchmark.
benchmarkPlan ::
     EnvironmentCapabilities
  -> CommitInfo
  -> Version
  -> ChainName
  -> Int
     -- ^ Repetitions per configuration.
  -> BenchmarkPlan
benchmarkPlan caps commit version chain count =
    BenchmarkPlan
      { bpRuns    = concatMap mkRuns configurations
      , bpSkipped = concatMap skipReason configurations
      }
  where
    configurations =
      [ ( "in-memory"
        , V2InMem
        , noLimits
        , capBackendInMem
        )
      , ( "LSM, page cache bypassed"
        , V2LSM
        , noLimits { mloLsmNoCache = True }
        , capLsmNoCache caps
        )
      ]

    noLimits = MemLimitOpts
      { mloHeapLimit  = Nothing
      , mloMemLimit   = Nothing
      , mloLsmNoCache = False
      }

    -- The in-memory backend has been present for as long as beacon has
    -- driven db-analyser; there is no capability flag that can turn it off.
    capBackendInMem = True

    mkRuns (label, backend, limits, supported)
      | not supported = []
      | otherwise =
          [ PlannedRun
              { prLabel   = label ++ " (" ++ modeLabel mode ++ ")"
              , prSlug    = mkSlug commit version chain mode backend (Just limits)
              , prCommand =
                  BeaconDoRun chain version count mode (Just backend) limits
              }
          | mode <- [Apply, Reapply]
          ]

    skipReason (label, _, _, supported)
      | supported = []
      | otherwise =
          [ label
            ++ ": the db-analyser in this build does not support it"
          ]

    modeLabel Apply   = "apply"
    modeLabel Reapply = "reapply"
