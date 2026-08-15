-- | Scatter-plot rendering, disabled.
--
-- This is the @-plots@ flavour of "Cardano.Beacon.Plot", selected by turning
-- off the @plots@ cabal flag. It has the same interface as the Cairo
-- implementation in @plots\/@ and draws nothing.
--
-- Used for the distributable SPO build, where Chart-cairo would pull cairo,
-- glib, fontconfig, freetype, pixman and the X11 client libraries into the
-- closure -- 12 of the 28 shared libraries such a build would otherwise carry,
-- and an obstacle to linking it statically. A benchmark run draws no plots, so
-- nothing is lost.
--
-- It reports rather than silently skipping: a build that cannot plot should
-- say so when asked to, instead of leaving the user hunting for a PNG that was
-- never going to appear.
module Cardano.Beacon.Plot (
    plotSeries
  , plotsAvailable
  ) where

import           Cardano.Beacon.Console


-- | Whether this build can actually draw. Lets callers skip the work of
-- assembling series they are only going to throw away.
plotsAvailable :: Bool
plotsAvailable = False

-- | No-op counterpart of the Cairo implementation.
plotSeries :: String -> [(String, [(Double, Double)])] -> FilePath -> IO ()
plotSeries _title _series outfile =
  printStyled StyleWarning $
       "this build was compiled without plotting support (cabal flag "
    ++ "'plots'); not writing '" ++ outfile ++ "'"
