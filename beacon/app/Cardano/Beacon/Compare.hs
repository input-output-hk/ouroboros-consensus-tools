{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}

{- HLINT ignore "Use sortOn" -}
{- HLINT ignore "Use <$>" -}

module Cardano.Beacon.Compare (
    doCompare
  , doVariance
  ) where

import           Cardano.Beacon.Chain
import           Cardano.Beacon.Console
import           Cardano.Beacon.RunMeta
import           Cardano.Beacon.SlotDataPoint
import           Cardano.Beacon.Types
import           Cardano.Slotting.Slot (SlotNo (..))
import           Control.Arrow ((>>>))
import           Control.Monad (forM_, unless, when)
import           Data.Maybe (isNothing, mapMaybe)
import           Data.Ord (Down (Down), comparing)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Vector (Vector)
import qualified Data.Vector as V
import           Data.Vector.Algorithms.Merge (sortBy)
import qualified Graphics.Rendering.Chart.Backend.Cairo as Chart.Cairo
import           Graphics.Rendering.Chart.Easy ((.=))
import qualified Graphics.Rendering.Chart.Easy as Chart
import           Numeric
import           Prelude hiding (putStr, putStrLn)
import qualified Statistics.Function as Stat
import qualified Statistics.Quantile as Stat
import qualified Statistics.Sample as Stat


doCompare :: Chains -> BeaconRun -> Maybe BeaconRun -> IO ()
doCompare chains runA_@BeaconRun{rMeta = metaA} mRunB
  | isNothing ch =
      printStyled StyleFatal $ "chain fragment not found: " ++ show (chain metaA)
  | otherwise = case mRunB of
      Nothing -> summarizeOne runA
      Just runB_
        | chain metaA /= chain (rMeta runB_) ->
            printStyled StyleFatal "meaningful comparisons between runs on different chain fragments is currently not supported"
        | otherwise -> do
          let runB = postProc runB_
          compareMeasurements True runA runB selMutForecast
          compareMeasurements True runA runB selMutBlockApply
          compareMeasurements True runA runB selMutTotalTime
          compareMeasurements True runA runB selTotalOverMut

          summarizeOne runA
          summarizeOne runB
  where
    ch         = lookupChain (chain metaA) chains
    dropUntil  = maybe id (\from -> dropWhile (\SlotDataPoint{slot} -> slot < fromIntegral from)) (ch >>= chFromSlot)
    takeBlocks = maybe id take (ch >>= chProcessBlocks)
    runA       = postProc runA_

    postProc run@BeaconRun{rData} =
      run {rData = applySortedDataPoints (takeBlocks . dropUntil) rData}

    summarizeOne run = do
      printStyled StyleInfo "---------------------------------------------------"
      summarizeBeaconRun True  run selMutBlockApply
      putStrLn ""
      summarizeBeaconRun False run selMutTotalTime
      putStrLn ""
      summarizeBeaconRun False run selTotalOverMut
      putStrLn ""
      summarizeMajorGcImpact   run selMutTotalTime
      putStrLn ""
      printProcessStats        run
      putStrLn ""


doVariance :: [BeaconRun] -> IO ()
doVariance [] =
  printStyled StyleWarning "doVariance: empty list of beacon runs"
doVariance runs = do
  forM_ selectors $ \selector ->
    let
      title = selName selector
      fName = "variance-" ++ slug ++ "-" ++ title ++ ".png"
    in plotMeasurements' runs (ChartTitle title) selector Nothing fName
  where
    slug = toSlug $ rMeta $ head runs
    selectors =
      [ selMutBlockApply
      , selMutTotalTime
      , selTotalOverMut
      , selAllocatedBytes
      ]


--------------------------------------------------------------------------------
-- Output data analysis functions
--------------------------------------------------------------------------------

-- Future options: We might consider making selectors part of the program
-- CLI options. Alternatively, the fields names could be obtained from
-- SlotDataPoint for increased robustness.

data Selector = Selector {
    selName       :: String
  , selProjection :: SlotDataPoint -> Double
  , selUnit       :: String
  , selPerTx      :: Bool
    -- ^ Whether an "avg per tx" figure is meaningful for this metric.
    -- Time-like metrics scale with tx count; dimensionless ratios (e.g.
    -- 'selTotalOverMut') do not.
  }

selSlot, selMutForecast, selMutBlockApply, selMutTotalTime, selAllocatedBytes, selTotalOverMut :: Selector
selSlot             = Selector "slot"           (fromIntegral . unSlotNo . slot)  ""    True
selMutForecast      = Selector "mut_forecast"   (fromIntegral . mut_forecast)     "μs"  True
selMutBlockApply    = Selector "mut_blockApply" (fromIntegral . mut_blockApply)   "μs"  True
selMutTotalTime     = Selector "totalTime"      (fromIntegral . totalTime)        "μs"  True
selAllocatedBytes   = Selector "allocatedBytes" (fromIntegral . allocatedBytes)   "B"   True
-- | Wall-clock time relative to mutator time, per slot: how many times
-- longer 'totalTime' is than 'mut' at that slot. Unlike 'mut'/'mut_blockApply',
-- this is sensitive to GC pauses and (per real measurement) to I/O
-- forced by an on-disk backend, since neither shows up in mutator time but
-- both inflate totalTime.
-- Aggregate as a mean/median *of this per-slot ratio*, never as @mean totalTime / mean mut@;
-- the latter is dominated by whichever run happens to contain the biggest single outlier and
-- can diverge sharply from the per-slot mean (seen empirically to differ by >50% on real data).
selTotalOverMut     = Selector "totalTime_per_mut" (\sdp -> if mut sdp == 0 then 0 else fromIntegral (totalTime sdp) / fromIntegral (mut sdp)) "x" False

-- | Get metric specified by the selector for all slots.
(.>) ::
     BeaconRun
  -> Selector
  -> Vector Double
BeaconRun{ rData } .> Selector{ selProjection } =
  V.map selProjection $ V.fromList $ unPoints rData

infixl 9 .>


-- | Sample aggregation for a summary: All data points whose tx count
-- matches the run's maximum observed tx count. Guarantees symmetrical
-- blocks that are comparable to one another.
-- The 'chFromSlot' filter is assumed to have been applied to the @run@.
selectMaxTxSample :: BeaconRun -> IO (Maybe (Int, Vector SlotDataPoint))
selectMaxTxSample run
  | null points = printFatalAndDie $
      "cannot summarize " ++ slug ++ ": run contains no data points"
  | otherwise = case maxTxCount of
      Nothing -> do
        printStyled StyleWarning $
          "cannot summarize " ++ slug ++ ": no block's stats parsed as a tx count"
        pure Nothing
      Just n -> pure $ Just (n, V.fromList (filter ((== Just n) . sdpTxCount) points))
  where
    slug   = toSlug (rMeta run)
    points = unPoints (rData run)

    maxTxCount = case mapMaybe sdpTxCount points of
      [] -> Nothing
      cs -> Just (maximum cs)

median :: Vector Double -> Double
median = Stat.median Stat.medianUnbiased

summarizeBeaconRun :: Bool -> BeaconRun -> Selector -> IO ()
summarizeBeaconRun withChainInfo run (Selector header selProjection unit perTx) = do
    mSample <- selectMaxTxSample run
    forM_ mSample $ \(n, points) -> do
      let sample       = V.map selProjection points
          meanV        = Stat.mean sample
          medianV      = median sample
          (sMin, sMax) = Stat.minMax sample
      printStyled StyleInfo $ "Summary for " ++ header ++ "/" ++ toSlug (rMeta run)
      when withChainInfo $ do
        putStrLn $ "sample size: " ++ show (V.length points) ++ " blocks"
        putStrLn $ "   tx/block: " ++ show n
      putStrLn   $ "       mean: " ++ withUnit meanV ++ "   (" ++ withUnit sMin ++ " .. " ++ withUnit sMax ++ ")"
      putStrLn   $ "     median: " ++ withUnit medianV
      when perTx $ do
        putStrLn $ " avg per tx (mean):   " ++ if n == 0 then "n/a" else withUnit (meanV / fromIntegral n)
        putStrLn $ " avg per tx (median): " ++ if n == 0 then "n/a" else withUnit (medianV / fromIntegral n)
  where
    withUnit :: Double -> String
    withUnit d = showFFloat (Just 2) d "" ++ unit

-- | Print a run's process-level stats if any were recorded.
printProcessStats :: BeaconRun -> IO ()
printProcessStats run =
  forM_ (rProcessStats run) $ \ProcessStats{..} -> do
    printStyled StyleInfo "Process stats"
    putStrLn $ "      max RSS: " ++ show statsMaxResidentSetSize ++ " B"
    putStrLn $ " fs blocks in: " ++ show statsFileSystemInputs
    putStrLn $ "fs blocks out: " ++ show statsFileSystemOutputs

-- | Split a run's sample by whether a major GC occurred during that slot
-- and summarize the chosen metric on each side.
-- This is a deliberate alternative to discarding "outlier" slots: the
-- split is on a causal fact rather than a statistical threshold picked after looking
-- at the specific run's own distribution.
summarizeMajorGcImpact :: BeaconRun -> Selector -> IO ()
summarizeMajorGcImpact run (Selector header selProjection unit _) = do
    mSample <- selectMaxTxSample run
    forM_ mSample $ \(_, points) -> do
      let (affected, steady) = V.partition ((> 0) . majGcCount) points
      printStyled StyleInfo $ "major GC affected: " ++ show (V.length affected) ++ " / " ++ show (V.length points) ++ " blocks"
      reportSubset "slots w/o major GC" steady
      reportSubset "slots w/  major GC" affected
  where
    withUnit :: Double -> String
    withUnit d = showFFloat (Just 2) d "" ++ unit

    reportSubset :: String -> Vector SlotDataPoint -> IO ()
    reportSubset label points
      | V.null points = pure ()
      | otherwise =
          putStrLn $ "  " ++ header ++ ", " ++ label ++ ":  mean "
                   ++ withUnit (Stat.mean sample) ++ ", median " ++ withUnit (median sample)
      where sample = V.map selProjection points


-- | Compare two measurements (benchmarks).
--
-- At the moment we perform a very simple comparison between the benchmark
-- results of versions 'A' and 'B'. We will refine the comparison process in
-- later versions. Per each slot 's', and each metric 'm' at that slot (eg block
-- processing time), we compute the relative change between measurements 'A'
-- and 'B':
--
-- > d_s A B = (m_s_B - m_s_A) / (max m_s_A m_s_B)
--
-- where 'm_s_v' is the measurement of metric 'm' at slot 's' for version 'v'.
--
-- Given the way we compute this ratio, 'd_s A B' will be positive if the
-- measurement for version 'B' is larger than the measurement for version 'A',
-- and conversely, 'd_s A B' will be negative if the measurement for version 'A' is
-- larger than the corresponding measurement for 'B'.
--
-- For instance, if we're measuring block application time, and 'd_100' is '0.6'
-- this means that version 'B' took 60% more time to apply a block in that
-- particular run.
--
-- We use the maximum betweeen 'm_s_A' and 'm_s_B' as quotient to guarantee that
-- a change from 'm_s_A' to 'm_s_B' has the same magnitude as a change in the
-- opposite direction. In other words:
--
-- > d_s A B = - (d_s B A)
--
-- Future work:
-- * Provide a continuation to handle comparison results.
-- * Make threshold and condition(s) on it configurable.
compareMeasurements :: Bool -> BeaconRun -> BeaconRun -> Selector -> IO ()
compareMeasurements emitPlots runA runB selector@(Selector header _ _ _) = do
    unless (runA .> selSlot == runB .> selSlot) $
      printFatalAndDie "Slot columns must be the same!"

    when (V.null (runA .> selSlot)) $
      printFatalAndDie "cannot compare: run(s) contain no data points"

    let threshold = 0.8

    let abRelChange = relChangeAscending runA runB

    printStyled StyleInfo $ "Comparison for " ++ header

    -- see above: "Bigger is better" or "smaller is better" depends on the metric - make configurable.
    abRelChange `shouldBeBelow` threshold

    let n = 10 :: Int

    putStrLn $ "Top " <> show n <> " measurements smaller than baseline (" <> versionA <> ")"
    printPairs "slot" header $ V.take 10 $ relativeChange abRelChange

    putStrLn $ "Top " <> show n <> " measurements larger than baseline ("  <> versionA <> ")"
    printPairs "slot" header $ V.take 10 $ V.reverse $ relativeChange abRelChange

    -- Filter the slots that have a difference above the given threshold.
    let outliers = Set.fromList
                 $ V.toList
                 $ filterSlots (\v -> v <= -threshold || v >= threshold ) abRelChange

    print outliers

    when emitPlots $
      plotMeasurements
        (ChartTitle header)
        selector
        (Just outliers)
        runA
        runB
        $ "compare_"
          <> header
          <> "-"
          <> take 9 versionA
          <> "_vs_"
          <> take 9 versionB
          <> ".png"
    where
      versionA = verGitRef $ version $ rMeta runA
      versionB = verGitRef $ version $ rMeta runB
      -- Given two runs and a column name, return the relative change, sorted in
      -- ascending order.
      relChangeAscending ::
           BeaconRun
        -> BeaconRun
        -> RelativeChange
      relChangeAscending dfA dfB =
            RelativeChange
          $ sortAscendingWithSlot dfA
          $ fmap relChange
          $ V.zip (dfA .> selector) (dfB .> selector)
        where
          relChange (a, b)
            | m == 0    = 0
            | otherwise = (b - a) / m
            where m = max a b

-- | Check that the relative change is above the given threshold.
shouldBeAbove :: RelativeChange -> Double -> IO ()
shouldBeAbove dr threshold =
  check (threshold < maxRelativeChange dr)

shouldBeBelow :: RelativeChange -> Double -> IO ()
shouldBeBelow dr threshold =
  check (maxRelativeChange dr < threshold)

-- | Check that the relative change is above the given threshold.
check :: Bool -> IO ()
check b =
  unless b $ do
      -- Future work: Add an option to return an error at the end if the above condition is true.
      printStyled StyleWarning "Distance treshold exceeded!"

-- | Relative change per-slot. See 'relChangeDescending'.
--
-- INVARIANT:
--
-- - the vector is sorted in ascending order on its second component.
--
-- Future deliberation:
-- * Consider using a SlotNo type (the first component represents a slot)
-- * Use a smart constructor to ensure the invariant
newtype RelativeChange = RelativeChange { relativeChange :: Vector (Double, Double) }

maxRelativeChange :: RelativeChange -> Double
maxRelativeChange = snd . V.last . relativeChange

minRelativeChange :: RelativeChange -> Double
minRelativeChange = snd . (V.! 0) . relativeChange

-- | Keep only the slots that satisfy the given predicate on the second component.
filterSlots :: (Double -> Bool) -> RelativeChange -> Vector Double
filterSlots f RelativeChange { relativeChange } =
    V.map fst $ V.filter (f . snd) relativeChange

sortDescendingWithSlot :: Ord a => BeaconRun -> Vector a -> Vector (Double, a)
sortDescendingWithSlot df = V.zip (df .> selSlot)
                          >>> V.modify (sortBy (comparing (Down . snd)))

sortAscendingWithSlot :: Ord a => BeaconRun -> Vector a -> Vector (Double, a)
sortAscendingWithSlot df = V.zip (df .> selSlot)
                          >>> V.modify (sortBy (comparing snd))

--------------------------------------------------------------------------------
-- Output data plotting functions
--------------------------------------------------------------------------------

newtype ChartTitle = ChartTitle String

plotMeasurements ::
     ChartTitle
  -> Selector
  -> Maybe (Set Double)
     -- ^ Slots to exclude from the plot, e.g. outliers or a leading range
     -- ('Nothing' means exclude none, i.e. plot all slots).
  -> BeaconRun
  -> BeaconRun
  -> FilePath
  -> IO ()
plotMeasurements (ChartTitle title) selector mExcludedSlots runA runB outfile = do
    let slotXvalue run = V.toList
                       $ V.filter (notExcluded mExcludedSlots . fst)
                       $ V.zip (run .> selSlot) (run .> selector)
        slotXvalueA = slotXvalue runA
        slotXvalueB = slotXvalue runB
    Chart.Cairo.toFile Chart.def outfile $ do
      Chart.layout_title .= title
      Chart.setColors [Chart.opaque Chart.blue, Chart.opaque Chart.red]
      Chart.plot (Chart.points (toSlug $ rMeta runA) slotXvalueA)
      Chart.plot (Chart.points (toSlug $ rMeta runB) slotXvalueB)
  where
    notExcluded Nothing      _ = True
    notExcluded (Just slots) s = s `Set.notMember` slots

plotMeasurements' ::
     [BeaconRun]
  -> ChartTitle
  -> Selector
  -> Maybe (Set Double)
     -- ^ Slots to exclude from the plot, e.g. outliers or a leading range
     -- ('Nothing' means exclude none, i.e. plot all slots).
  -> FilePath
  -> IO ()
plotMeasurements' runs (ChartTitle title) selector mExcludedSlots outfile =
  Chart.Cairo.toFile Chart.def outfile $ do
    Chart.layout_title .= title
    Chart.setColors
      [ Chart.opaque Chart.blue
      , Chart.opaque Chart.red
      , Chart.opaque Chart.green
      , Chart.opaque Chart.magenta
      , Chart.opaque Chart.cyan
      ]
    mapM_ Chart.plot
      [ Chart.points name points
        | (run, ix) <- zip runs [1 :: Int ..]
          , let name    = "run " ++ show ix
          , let points  = valuesBySlot run
      ]
  where
    valuesBySlot run =
        V.toList
      $ V.filter (notExcluded mExcludedSlots . fst)
      $ V.zip (run .> selSlot) (run .> selector)

    notExcluded Nothing      _ = True
    notExcluded (Just slots) s = s `Set.notMember` slots

--------------------------------------------------------------------------------
-- Printing functions
--------------------------------------------------------------------------------

printPairs :: (Foldable t, Show a, Show b) => String -> String -> t (a, b) -> IO ()
printPairs fstHeader sndHeader xs = do
    printStyled StyleNone $ show fstHeader <> ", " <> show sndHeader
    mapM_ printPair xs
  where
    printPair (a, b) = printStyled StyleNone $ "" <> show a <> ", " <> show b <> ""

putStrLn :: String -> IO ()
putStrLn = printStyled StyleNone
