
// Document Styling
//
#set page(paper: "a4", margin: 1.5cm)
#set text(size: 10pt)
#set par(leading: 0.6em, first-line-indent: 1.8em, justify: true)
#show heading: set block(above: 1.5em, below: 1.2em)
#show figure.caption: emph

#let frame(stroke) = (x, y) => (
  left: if x > 0 { 0pt } else { stroke },
  right: stroke,
  top: if y < 2 { stroke } else { 0pt },
  bottom: stroke,
)
#set table(
  stroke: frame(0.5pt),
  align:  (x, _) => if x == 0 { left } else { right },
)
#show table: set text(size: 0.96em)
#show table.cell.where(x: 0): set text(size: 0.9em)


= On-disk (LSM, no page cache) vs In-memory Ledger: Is Disk I/O a Block-Validation Bottleneck?

#set par(
    first-line-indent: 0pt,
)

*Concern*: an on-disk `LedgerDB` backend inevitably makes the ledger state's UTxO table
memory I/O instead of always-resident RAM. If that I/O sits on the block-validation critical
path, block application could become disk-bound instead of CPU-bound as the on-disk backend
sees more use. This report checks whether that is the case for the `LSM` backend when the OS
page cache is disabled (`--lsm-no-cache`), which is the worst case for that concern: every
UTxO-table read that isn't served by the bloom filter is a genuine, uncached disk read.

The package versions are those integrated in the current Node `10.7.1` release:
`cardano-ledger-core-1.20.0.0`, `ouroboros-consensus-3.0.1.0`.

#pad(top: 0.5em)[]
#block(stroke: 0.6pt, inset: 8pt, radius: 2pt)[
  *Verdict, up front*: yes, it is measurable, and it is *not* negligible. Every timing field
  `beacon` currently reports -- including wall-clock `totalTime`, not just mutator-only
  fields -- structurally excludes the one step that actually does the UTxO-table disk read
  (see “A critical measurement gap” below). Once that step is measured directly, it adds a median *~29μs/tx*, which
  is *~23%* of the true per-block cost in the steady state. This reverses this report's own
  first-draft conclusion, which had (incorrectly) called the impact negligible based on
  `totalTime` alone.
]
#pad(top: 0.5em)[]

== Methodology

Two `beacon` runs on the same host (`client-eu-01`) and the same chain fragment (`1071-praos`:
135 viable blocks, 236 value-moving txns each, `apply` = `ValidateAll`) are compared:

#align(center)[
#table(
  columns: 3,
  table.header([], [In-memory], [On-disk (LSM)]),
  [Backend],            [`V2InMem`],  [`V2LSM`],
  [`--lsm-no-cache`],   [n/a],        [yes -- forces every UTxO-table page read/write through disk I/O, bypassing the OS page cache (see below)],
  [Heap limit (`-M`)],  [none],       [`4G`],
  [Run slug],           [`48fce841-haskell96-1071praos-appl-inmem`], [`48fce841-haskell96-1071praos-appl-lsmnc-h4G`],
)
]
#pad(top: 1em)[]

`beacon` times a block's processing as 5 sub-phases (forecast, header tick, header apply,
ledger tick, block apply) plus a `totalTime` wall-clock figure spanning all 5. Wall-clock
`totalTime` additionally picks up GC pauses and is confounded by two known, sparse causes of
outliers, both surfaced by `beacon summary`'s breakdowns:
- a *major GC* occurring during a block's processing;
- the block being the first one processed after an *epoch boundary* (600 slots on this chain),
  whose ledger tick does real extra work (reward/stake-snapshot computation).

Excluding both isolates the "steady state" -- blocks affected by neither -- so that headline
figures aren't dominated by a handful of outliers. The two subsections below report the
picture *as originally measured* this way; “A critical measurement gap” below then shows why that picture is incomplete
regardless of which of these fields is used, and “Corrected results” gives the corrected numbers.

=== Subtask: what does `--lsm-no-cache` actually force?

Tracing `--lsm-no-cache` through `db-analyser` and into the `lsm-tree` library it depends on:

- The flag only sets `LSM.DiskCachePolicy` to `DiskCacheNone` for the *UTxO table*'s on-disk
  run files specifically. It does not touch the ImmutableDB/VolatileDB (raw block storage) or
  ledger snapshots -- those keep the OS's normal page-cache behavior regardless of this flag.
- Per run file, `lsm-tree` calls `hSetNoCache ... True` on the file handle (an OS-level
  don't-cache directive on the fd, e.g. macOS `F_NOCACHE`), so every read of that run's data
  goes to disk -- not just skipping readahead, but preventing the OS from reusing a page even
  if it was very recently read. On top of that, once a reader of such a run closes,
  `lsm-tree` additionally calls `hDropCacheAll` to actively evict any of that run's pages that
  might still be resident, so nothing lingers cached even transiently.
- What still stays in memory regardless of this policy: the *write buffer* (the most recent,
  not-yet-flushed updates) is a pure in-memory structure; and each run's *bloom filter* and
  *fence-pointer index* are always kept resident, regardless of `DiskCachePolicy`. So a lookup
  for a key that isn't present in a given run is typically answered by an in-memory bloom-filter
  check, without touching disk at all -- only a lookup for a key that *is* present in a given
  run forces a genuine, uncached page read under this policy.
- Net effect: this is a worst case for on-disk read cost (no benefit from repeatedly reading
  the same page), but not a worst case for *total* I/O volume, since bloom filters still filter
  out most per-run negative lookups before they'd ever reach disk.

The `Process stats` block of the on-disk run's `beacon summary` output confirms real disk I/O
is actually happening (i.e. the flag is doing what it says, not silently no-op'd), rather than
just asserting it:

```
fs blocks in: 2179136
fs blocks out: 3778360
```

(vs. `fs blocks in: 1618720`, `fs blocks out: 128` for the in-memory run -- the difference is
almost entirely the LSM backend's own table I/O and its "no cache" re-reads, not the shared
ImmutableDB replay cost both runs pay.)

== Results, as originally measured

=== Block application (`mut_blockApply`)

#align(center)[
#table(
  columns: 3,
  table.header([], [In-memory], [On-disk (LSM), no cache]),
  [Mean, μs/block],          [36050.93],  [36125.15],
  [Median, μs/block],        [36005.00],  [36081.00],
  [Min .. Max, μs/block],    [35836.00 .. 36946.00], [35815.00 .. 37272.00],
  [*Mean, μs/tx*],           [*152.76*],  [*153.07*],
  [*Median, μs/tx*],         [*152.56*],  [*152.89*],
)
]
#pad(top: 1em)[]

The difference is $<0.3%$ on every figure above. But per “A critical measurement gap” below, this is not evidence of
"no I/O cost" -- `mut_blockApply` is timed as a dedicated phase that starts only *after* this
block's UTxO-table entries have already been fetched, so it was never going to see that cost
regardless of backend. This figure is retained here for completeness (and because it's still
true that block-application CPU work itself doesn't change), but it is *not* used as the basis
for this report's conclusion.

=== Wall-clock time (`totalTime`), unfiltered

#align(center)[
#table(
  columns: 3,
  table.header([], [In-memory], [On-disk (LSM), no cache]),
  [Mean, μs/block],          [203041.86],   [346377.47],
  [Median, μs/block],        [48579.00],    [48454.00],
  [Max, μs/block],           [3256521.00],  [8027982.00],
  [Major-GC-affected blocks],   [1 / 135],  [2 / 135],
  [Epoch-boundary blocks],      [5 / 135],  [5 / 135],
)
]
#pad(top: 1em)[]

Unfiltered, the on-disk run's mean is $~$70% higher and its worst block over 2$times$ slower --
but the median is essentially unchanged, so this gap is carried by a handful of outliers, not a
shift of the whole distribution. Crossing an epoch boundary means ticking the ledger state
forward, which touches far more of the UTxO table than a single block's own txns do, so a
no-cache backend pays for many more uncached reads at once, right when the (unrelated) GC
pressure from that same tick is also highest.

=== Wall-clock time (`totalTime`), steady state (excludes major GC #sym.and epoch boundary)

#align(center)[
#table(
  columns: 3,
  table.header([], [In-memory], [On-disk (LSM), no cache]),
  [Sample size, blocks],     [130 / 135], [128 / 135],
  [Mean, μs/block],          [143511.84], [157633.15],
  [Median, μs/block],        [48498.00],  [48337.00],
  [*Mean, μs/tx*],           [*608.10*],  [*667.94*],
  [*Median, μs/tx*],         [*205.50*],  [*204.82*],
)
]
#pad(top: 1em)[]

With both known outlier causes excluded, the *median* looks effectively identical between
backends ($<0.4%$), and the *mean* carries only a residual $~$10% gap. Read at face value, this
would say the on-disk backend is basically free once GC/tick outliers are set aside -- *this is
exactly the reading that the next section shows is wrong*, because `totalTime`'s own timing window is
subject to the same exclusion as `mut_blockApply`.

== A critical measurement gap: the table read happens outside every timed field

Tracing `beacon summary`'s numbers back to where `db-analyser` produces them
(`Cardano.Tools.DBAnalyser.Analysis.benchmarkLedgerOps`, exact commit `48fce8410ca...` used for
the runs above) surfaces a structural problem with *all* of the figures in the previous
section, `totalTime` included:

```haskell
process ledgerDB intLedgerDB outFileHandle outFormat _ (blk, sz) = do
  (prevLedgerState, tables) <- LedgerDB.withTipForker ledgerDB $ \frk -> do
    st  <- IOLike.atomically $ LedgerDB.forkerGetLedgerState frk
    tbs <- LedgerDB.forkerReadTables frk (getBlockKeySets blk)   -- the actual UTxO-table read
    pure (st, tbs)
  prevRtsStats <- GC.getRTSStats                                  -- totalTime's window starts HERE
  ...
  (tkLdgrSt, tBlkTick)  <- time $ tickTheLedgerState ...
  (!newLedger, tBlkApp) <- time $ applyTheBlock ...
  currentRtsStats <- GC.getRTSStats                                -- ...and ends here
```

`forkerReadTables` is exactly where the on-disk backend performs `LSM.lookups` -- the
synchronous disk read for the block's own UTxO inputs, i.e. precisely the read
`--lsm-no-cache` forces to bypass the page cache. That call completes *before* `prevRtsStats`
is captured. `totalTime` (`currentMinusPrevious GC.elapsed_ns`) is a diff against
`prevRtsStats`, so it doesn't include this read either -- not just the mutator-only fields.
The 5-phase design deliberately separates "fetch the tables this block needs" (impure, IO, done
up front) from "tick/apply" (pure, operating on already-materialized values), and nothing
inside the timed window re-touches disk for the block's own reads. So: *no field `beacon`
reports is capable of seeing this cost, regardless of which one the conclusion is based on.*

=== The fix

A local, uncommitted patch to `Cardano.Tools.DBAnalyser.Analysis` (on the exact
`mkarg/db-analyser-lsmnocache` branch/commit used for these runs) adds two fields, timed the
same way the other 5 phases already are, bracketing `withTipForker`/`forkerReadTables` instead
of what comes after it:

- `tableReadTime` -- elapsed (`GC.elapsed_ns`) time to fetch this block's ledger tables.
- `mut_tableRead` -- the mutator-only companion (`GC.mutator_elapsed_ns`), mirroring `mut` vs
  `totalTime`.

The true, complete per-block wall-clock cost is then `trueTotalTime = totalTime + tableReadTime`.
`beacon` was extended to parse and report both new fields, plus `trueTotalTime`, including
through the existing major-GC/epoch-boundary/steady-state breakdowns.

*This patch has not been pushed anywhere* (the branch belongs to another engineer, on the
upstream `IntersectMBO/ouroboros-consensus` repo) -- it was built and run purely locally to
produce the corrected numbers below. Getting these fields into the real, CI-hardware benchmark
runs (`client-eu-01`, with the `4G` heap cap) requires that patch to be reviewed and merged
upstream, then those 3 runs redone with the patched binary.

== Corrected results (local re-measurement)

The comparison below was redone with the patched `db-analyser`, on the same local machine for
both backends (*not* `client-eu-01` -- absolute μs figures are therefore not comparable to the
tables above; only the *relative* in-memory-vs-on-disk comparison, run back-to-back on identical
hardware, is meaningful here). The `4G` heap cap immediately exhausted the heap in this
environment (this machine differs from the benchmarking host in available memory/prior state),
so this run is uncapped -- a difference from the original setup worth re-checking once this
runs on `client-eu-01`. Same chain fragment, same 135/236 sample.

=== `tableReadTime`: the cost that was invisible before

#align(center)[
#table(
  columns: 3,
  table.header([], [In-memory], [On-disk (LSM), no cache]),
  [Mean, μs/block],   [11.31],   [7081.70],
  [Median, μs/block], [11.00],   [6846.00],
  [Max, μs/block],    [36.00],   [16179.00],
  [*Mean, μs/tx*],    [*0.05*],  [*30.01*],
  [*Median, μs/tx*],  [*0.05*],  [*29.01*],
)
]
#pad(top: 1em)[]

In-memory: negligible, as expected (an in-process map lookup). On-disk, no-cache: a median
*6846μs per block* (*29μs/tx*) that was completely absent from every previous table in this
report.

=== `trueTotalTime` (`totalTime` + `tableReadTime`), steady state

#align(center)[
#table(
  columns: 3,
  table.header([], [In-memory], [On-disk (LSM), no cache]),
  [Sample size, blocks],  [130 / 135], [129 / 135],
  [Mean, μs/block],       [62239.08],  [73390.38],
  [Median, μs/block],     [18354.50],  [30205.00],
  [*Mean, μs/tx*],        [*263.72*],  [*310.98*],
  [*Median, μs/tx*],      [*77.77*],   [*127.99*],
)
]
#pad(top: 1em)[]

Once the table read is included, the steady-state *median* per-tx cost rises from *77.77μs* to
*127.99μs* -- *+65%*. The mean rises *+17.9%*. Almost all of this gap is the direct table-read
cost itself: `tableReadTime`'s median of 29μs/tx is *~23%* of the corrected 127.99μs/tx total --
this is not a rounding effect or a redistribution of existing cost, it's cost that was never
being measured. A smaller, second-order gap remains even in `totalTime` alone in this
steady-state slice ($~$8% at the median) -- consistent with the small residual gap seen in the
original (uncorrected) measurement's mean, now visible at the median too on this run.

== Revised observations

- *The on-disk (no-cache) LSM backend's disk I/O is a real, non-negligible cost to per-block
  processing* -- roughly *+65%* median wall-clock time per tx in the steady state, once
  measured correctly. The earlier "negligible impact" conclusion in this report's first draft
  was an artifact of every measured field excluding the one step that actually does the read.
- This is *not* the same claim as "block validation/tx-validation CPU work changes": it
  doesn't -- `mut_blockApply` genuinely is flat between backends, because block application
  operates on already-fetched, in-memory table values by design. The cost sits in *fetching*
  those values beforehand, which is real wall-clock time on the path from "block arrives" to
  "block validated", even though it's not *validation* work per se.
- The mechanism is exactly what `--lsm-no-cache` promises (the subtask above, and the `fs blocks
  in/out` counts): every UTxO-table read that survives the (always-resident) bloom-filter check
  is a genuine, uncached disk read, and there's no free lunch from OS caching to hide it.
- Follow-up needed for a fully confident, production-representative number: get this patch
  reviewed/merged upstream, and rerun all 3 original CI-hardware (`client-eu-01`) benchmarks
  with it, including the `4G`-heap-capped LSM variant that couldn't be reproduced locally.
