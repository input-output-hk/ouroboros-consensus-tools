-- | Scatter-plot rendering, Cairo backend.
--
-- This is the @plots@ flavour of "Cardano.Beacon.Plot", selected by the
-- @plots@ cabal flag (on by default). The alternative implementation in
-- @no-plots\/@ has the same interface and draws nothing.
--
-- The flag exists because Chart-cairo drags cairo, glib, fontconfig,
-- freetype, pixman and the X11 client libraries into the closure -- 12 of the
-- 28 shared libraries a distributable beacon would otherwise have to carry,
-- and a serious obstacle to linking one statically. A benchmark run never
-- draws a plot, so the SPO-facing build has no use for any of it.
--
-- Deliberately free of beacon domain types: it takes plain named series, so
-- that selecting the data stays in "Cardano.Beacon.Compare" (pure, always
-- compiled) and only the drawing is conditional.
module Cardano.Beacon.Plot (
    plotSeries
  , plotsAvailable
  ) where

import           Graphics.Rendering.Chart.Backend.Cairo as Chart.Cairo (toFile)
import           Graphics.Rendering.Chart.Easy ((.=))
import qualified Graphics.Rendering.Chart.Easy as Chart


-- | Whether this build can actually draw. Lets callers skip the work of
-- assembling series they are only going to throw away.
plotsAvailable :: Bool
plotsAvailable = True

-- | Render named @(x, y)@ series as a scatter plot to a PNG file.
plotSeries ::
     String
     -- ^ Chart title.
  -> [(String, [(Double, Double)])]
     -- ^ Series, as (legend name, points).
  -> FilePath
     -- ^ Output file.
  -> IO ()
plotSeries title series outfile =
  Chart.Cairo.toFile Chart.def outfile $ do
    Chart.layout_title .= title
    Chart.setColors $ map Chart.opaque
      [ Chart.blue
      , Chart.red
      , Chart.green
      , Chart.magenta
      , Chart.cyan
      ]
    mapM_ (\(name, points) -> Chart.plot (Chart.points name points)) series
