{-# LANGUAGE DerivingVia #-}

module Cardano.Beacon.CDF (module Cardano.Beacon.CDF) where

import           Data.IntervalMap.FingerTree (Interval (..))
import           Data.List (transpose)
import           Data.Ratio
import qualified Data.Vector.Unboxed as VU
import           GHC.Real (Ratio ((:%)))
import           Numeric (readFloat)
import qualified Statistics.Function as Stat
import qualified Statistics.Quantile as Stat
import qualified Statistics.Sample as Stat
import           Statistics.Sample (Sample)


-- the Quantile type should be read shorthand as "the k_th q-quantile" for a Ratio of k % q
newtype Quantile = Q {unQ :: Ratio Int}
        deriving Show

-- "smart" constructor
mkQuantile :: String -> Quantile
mkQuantile x =
  case readFloat x of
    ((n, []) : _) -> Q n
    _             -> error "Invalid quantile"

briefQuantiles :: [Quantile]
briefQuantiles =
  map mkQuantile
    [ "0.5"
    , "0.9"
    , "1.0"
    ]

data CDF =
  CDF
  { cdfSize     :: Int
  , cdfAverage  :: Double
  , cdfMedian   :: Double
  , cdfStddev   :: Double
  , cdfMinMax   :: Interval Double
  , cdfRange    :: Double
  , cdfSamples  :: [(Quantile, Double)]
  , cdfSamples2 :: [(Quantile, Double)]
  }
  deriving Show

cdf :: Stat.ContParam -> [Quantile] -> Sample -> CDF
cdf contParam quantiles unsorted =
  CDF
  { cdfSize        = size
  , cdfAverage     = Stat.mean sorted
  , cdfMedian      = Stat.median contParam sorted
  , cdfStddev      = Stat.stdDev sorted
  , cdfMinMax      = Interval imin imax
  , cdfRange       = imax - imin
  , cdfSamples     = zip quantiles (Stat.quantiles contParam noms denom sorted)
  , cdfSamples2    = zip quantiles (map (sorted `elemClosestTo`) quantiles)
  }
  where
    (noms, denom) = expandToCommonDenom quantiles
    size          = VU.length sorted
    sorted        = Stat.sort unsorted
    imin          = VU.unsafeHead sorted
    imax          = VU.unsafeLast sorted

expandToCommonDenom :: [Quantile] -> ([Int], Int)
expandToCommonDenom qs =
  ( map expandNom qs, commonDenom )
  where
    expandNom (Q (n :% d))  = (commonDenom `div` d) * n
    commonDenom             = foldr1 lcm (map (denominator . unQ) qs)

-- | Given a sorted sample, produce population element closest to specified quantile
elemClosestTo :: Sample -> Quantile -> Double
elemClosestTo vec (Q (n :% d)) =
  vec `VU.unsafeIndex` closestIx
  where
    position :: Double
    position  = fromIntegral (size * n) / fromIntegral d
    closestIx = min (size - 1) $ floor position
    size      = VU.length vec

combineSamples :: [Sample] -> CDF
combineSamples =
  cdf Stat.medianUnbiased briefQuantiles . VU.concat

-- | Combines the summary statistics of several 'CDF's (e.g. one per stored
-- run of a slug) into one. 'cdfSize', 'cdfMinMax' and 'cdfRange' are exact.
-- The rest are only approximated, since the true combined distribution
-- can't be recovered from summary statistics alone without the underlying
-- samples (see 'combineSamples' for that): 'cdfAverage', 'cdfMedian',
-- 'cdfSamples' and 'cdfSamples2' use a size-weighted average across the
-- inputs, 'cdfStddev' takes their maximum. Assumes every input was built
-- from the same quantile list (true for all current callers, which all go
-- through 'briefQuantiles').
combineCDFs :: [CDF] -> CDF
combineCDFs cdfs =
  CDF
  { cdfSize     = totalSize
  , cdfAverage  = weightedAvg cdfAverage
  , cdfStddev   = maximum $ cdfStddev <$> cdfs    -- approximating
  , cdfMedian   = weightedAvg cdfMedian           -- approximating
  , cdfMinMax   = Interval imin imax
  , cdfRange    = imax - imin
  , cdfSamples  = weightedAvgQuantiles cdfSamples
  , cdfSamples2 = weightedAvgQuantiles cdfSamples2
  }
  where
    totalSize = sum $ cdfSize <$> cdfs

    weightedAvg f =
      Stat.meanWeighted $ VU.fromList [ (f c, fromIntegral (cdfSize c)) | c <- cdfs ]

    imin = minimum [lo | CDF{cdfMinMax = Interval lo _} <- cdfs]
    imax = maximum [hi | CDF{cdfMinMax = Interval _ hi} <- cdfs]

    -- approximating: a size-weighted average per matching quantile,
    -- assuming every 'CDF' carries the same quantiles in the same order
    weightedAvgQuantiles f =
      [ (q, weightedAvgOf (snd <$> column))
      | column@((q, _) : _) <- transpose (f <$> cdfs)
      ]

    weightedAvgOf vals =
      Stat.meanWeighted $ VU.fromList $ zip vals (fromIntegral . cdfSize <$> cdfs)
