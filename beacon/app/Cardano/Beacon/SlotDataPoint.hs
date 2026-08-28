{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Beacon.SlotDataPoint (
    SlotDataPoint (..)
  , SortedDataPoints (unPoints)
  , applySortedDataPoints
  , mkSortedDataPoints
  , sdpTxCount
  ) where

{-# OPTIONS_GHC -fno-warn-orphans #-}

import           Cardano.Slotting.Slot (SlotNo)
import           Data.Aeson
import           Data.Int
import           Data.List (sortOn)
import           Data.Text (Text)
import           Data.Text.Read (decimal)
import           Data.Word
-- import           Cardano.Tools.DBAnalyser.Analysis.BenchmarkLedgerOps.SlotDataPoint as SDP



-- | type for a lightweight guarantee to have a list of data points
-- sorted by SlotNo in ascending order
newtype SortedDataPoints = SDP {unPoints :: [SlotDataPoint]}
        deriving Show
          via [SlotDataPoint]

instance FromJSON SortedDataPoints where
  parseJSON o = mkSortedDataPoints <$> parseJSON o

mkSortedDataPoints :: [SlotDataPoint] -> SortedDataPoints
mkSortedDataPoints = SDP . sortOn slot

applySortedDataPoints :: ([SlotDataPoint] -> [SlotDataPoint]) -> SortedDataPoints -> SortedDataPoints
applySortedDataPoints f (SDP xs) = SDP (f xs)


instance FromJSON SlotDataPoint where
  parseJSON = withObject "SlotDataPoint" $ \o -> do
    slot            :: SlotNo   <- o .: "slot"
    slotGap         :: Word64   <- o .: "slotGap"
    totalTime       :: Int64    <- o .: "totalTime"
    mut             :: Int64    <- o .: "mut"
    gc              :: Int64    <- o .: "gc"
    -- Absent in runs recorded before these fields existed.
    tableReadTime   :: Int64    <- o .:? "tableReadTime" .!= 0
    mut_tableRead   :: Int64    <- o .:? "mut_tableRead" .!= 0
    majGcCount      :: Word32   <- o .: "majGcCount"
    minGcCount      :: Word32   <- o .: "minGcCount"
    allocatedBytes  :: Word64   <- o .: "allocatedBytes"
    mut_forecast    :: Int64    <- o .: "mut_forecast"
    mut_headerTick  :: Int64    <- o .: "mut_headerTick"
    mut_headerApply :: Int64    <- o .: "mut_headerApply"
    mut_blockTick   :: Int64    <- o .: "mut_blockTick"
    mut_blockApply  :: Int64    <- o .: "mut_blockApply"
    blockStats      :: [Text]   <- o .: "blockStats"

    pure SlotDataPoint{..}


-- Future work: remove duplicate type definition once this has been resolved:
{-
app/Cardano/Beacon/SlotDataPoint.hs:18:1: error:
    Could not load module ‘Cardano.Tools.DBAnalyser.Analysis.BenchmarkLedgerOps.SlotDataPoint’
    it is a hidden module in the package ‘ouroboros-consensus-cardano-0.12.1.0’
    Use -v (or `:set -v` in ghci) to see a list of the files searched for.
   |
18 | import           Cardano.Tools.DBAnalyser.Analysis.BenchmarkLedgerOps.SlotDataPoint as SDP
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
-}

-- | Information about the time db-analyser spent processing the block at
-- 'slot', divided into the 5 major ledger operations (forecast, header
-- tick, header application, block tick, block application).
--
-- Before those 5 operations run, the node fetches the ledger tables the
-- block needs (e.g. the on-disk backend's UTxO-table reads). 'totalTime',
-- 'mut', 'gc', 'majGcCount', 'minGcCount' and 'allocatedBytes' cover that
-- table fetch /and/ the 5 operations together; 'tableReadTime' and
-- 'mut_tableRead' report the fetch on its own, so subtracting them yields
-- the 5 operations alone.
--
-- Caveat -- this holds for runs produced by a db-analyser built from
-- ouroboros-consensus @0ebd397da@ or later, which is where the RTS-stats
-- window behind 'totalTime'\/'mut'\/'gc' was moved to start /before/ the
-- fetch. The table-read fields themselves landed two days earlier, in
-- @3dd0aca3a@, so a run recorded by a build from that short window
-- reports a non-zero 'tableReadTime' that its 'totalTime' does /not/
-- include -- and nothing in the JSON says which of the two semantics a
-- given run was written under. We read the fields as documented above;
-- against such a run 'totalTime' undercounts by 'tableReadTime'.
data SlotDataPoint =
    SlotDataPoint
      { -- | Slot in which the 5 ledger operations were applied.
        slot            :: !SlotNo
        -- | Gap to the previous slot.
      , slotGap         :: !Word64
        -- | Elapsed time spent on the ledger-table fetch and the 5 ledger
        -- operations at 'slot'. Taken from GC.elapsed_ns.
      , totalTime       :: !Int64
        -- | Time the mutator ran during the ledger-table fetch and the 5
        -- ledger operations at 'slot'. Taken from GC.mutator_elapsed_ns.
      , mut             :: !Int64
        -- | Time spent in garbage collection during the ledger-table fetch
        -- and the 5 ledger operations at 'slot'.
      , gc              :: !Int64
        -- | Elapsed time spent fetching this block's ledger tables (e.g. the
        -- on-disk backend's UTxO-table reads) before any of the 5 ledger
        -- operations start. 'totalTime' already counts this time; subtract
        -- it to get the 5 operations on their own.
        -- @0@ for runs recorded before this field existed.
      , tableReadTime   :: !Int64
        -- | Difference of the GC.mutator_elapsed_ns field while fetching
        -- this block's ledger tables; 'tableReadTime' minus this value is
        -- the GC time inside the fetch (see 'tableReadTime'). @0@ for runs
        -- recorded before this field existed.
      , mut_tableRead   :: !Int64
        -- | Total number of __major__ garbage collections that took place
        -- during the ledger-table fetch and the 5 ledger operations at 'slot'.
      , majGcCount      :: !Word32
        -- | Total number of __minor__ garbage collections that took place
        -- during the ledger-table fetch and the 5 ledger operations at 'slot'.
      , minGcCount      :: !Word32
        -- | Allocated bytes during the ledger-table fetch and the 5 ledger
        -- operations at 'slot'.
      , allocatedBytes  :: !Word64
        -- | Difference of the GC.mutator_elapsed_ns field when computing the
        -- forecast. Unlike 'mut', this and the other per-operation @mut_*@
        -- fields never cover the ledger-table fetch -- they bracket their
        -- individual operation, all of which run after it.
      , mut_forecast    :: !Int64
      , mut_headerTick  :: !Int64
      , mut_headerApply :: !Int64
      , mut_blockTick   :: !Int64
      , mut_blockApply  :: !Int64
      -- | Free-form information about the block.
      , blockStats      :: ![Text]
      } deriving Show

sdpTxCount :: SlotDataPoint -> Maybe Int
sdpTxCount SlotDataPoint{blockStats} = case blockStats of
  c_ : _
    | Right (c, "") <- decimal c_ -> Just c
  _                               -> Nothing

