# Benchmarking methodology

## Goal

`beacon` benchmarks how long it takes to *validate* blocks - and by proxy, transactions -
for a given Ledger + Consensus implementation.

`beacon` is the harness: it drives two benchmarkables — the `db-analyser`
binary (i.e. which Ledger + Consensus commit) and the chain fragment (the
workload) — replaying the fragment through the real validation code path
and recording timings for per-block validation work.

Every run separates a one-off *construction* phase (initial ledger
state construction from genesis) from the repeated, per-block *validation*
phase that follows it, and reports timing only for the latter.

With that principle fixed, the benchmarking approach varies three
independent axes to understand what drives validation time and by how much.

## Axis 1 — backing store

The ledger's UTxO set can be held in different backing stores. Three
configurations matter here, each answering a different question:

1. **In-memory — baseline.** The UTxO set lives entirely in RAM with no
   on-disk representation at all. This is how the current Cardano Node
   operates in production today, so this configuration is not a
   theoretical floor — it's a realistic baseline.
2. **On-disk, unconstrained.** The UTxO set lives in an on-disk store, but
   with enough memory available that its working set stays resident in the
   OS page cache — no actual disk I/O is needed to serve reads. This configuration
   isolates the backing store's own implementation/abstraction overhead (bookkeeping,
   indirection, whatever cost the on-disk data structure imposes) from the
   cost of real disk access, since here there isn't any yet.
3. **On-disk, constrained — the "sweet spot".** The same on-disk store, but
   configured so that validation genuinely has to hit disk rather than
   being served from page cache, representative of a node running under real
   memory pressure. This is the most realistic estimate of what impact an
   on-disk ledger state has on tx validation times, given real-world memory
   constraints.

### Reaching the on-disk "sweet spot"

Getting to configuration 3 above is less obvious than it sounds: the LSM
backend's disk reads are served through the OS page cache by default, so
simply running it with memory-constrains doesn't reliably force real disk I/O during
validation. If the working set happens to fit in cache, or the OS page cache is
already warm from a previous run, reads are served from RAM regardless of how
little memory is nominally available to the process.

The recommended incantation is:

```
beacon run -n <chain-fragment> --rev <consensus-rev> --lsm --lsm-no-cache --heap-limit <SIZE>
```

`--lsm-no-cache` makes `db-analyser` open the LSM backend's on-disk tables
with `O_DIRECT`, bypassing the page cache entirely — every read the
validation loop makes genuinely goes to disk, deterministically.

Scaling the `--heap-limit` is needed to force the loop to pay a real GC cost
it would otherwise avoid — confirmed (via repeated runs) to show up as
increased `totalTime`, potentially but not necessarily as a change in
disk-read volume. A sensible heap limit can only be found empirically for a
specific chain fragment (or groups of chain fragments having identically
sized ledger states in their geneses).

Adding a tight `--mem-limit` (which imposes an OS-level cgroup memory cap;
see below) on top of `--lsm-no-cache` was tried and
does *not* help: since the validation loop's memory ceiling is controlled
by the heap limit, and the loop is already disk-bound from `--lsm-no-cache`,
the extra constraint has essentially nothing left to do there — except
prolonging the construction phase significantly (in one measurement, this alone
stretched construction from about a minute to well over three, for no corresponding
benefit to the actual measurement).

**If the `db-analyser` build in use doesn't support `--lsm-no-cache`**
(it's a recent addition) use the fallback `--mem-limit` instead:

```
beacon run -n <chain-fragment> --rev <consensus-rev> --lsm --mem-limit <SIZE>
```

This wraps `db-analyser` in a cgroup memory limit, pressuring the OS page
cache into evicting data so that reads have to come from disk. It works,
but with real drawbacks compared to `--lsm-no-cache`:

- **No safe default size.** The limit has to sit below the process's
  natural memory footprint to have any effect at all — set too loose, it
  produces zero forced disk I/O. Same considerations as for the
  heap limit above apply: The right `<SIZE>` has to be found empirically for
  each chain fragment rather than assumed.
- **It's probabilistic, not deterministic, for the phase that matters.**
  Whether cgroup memory pressure happens to
  evict exactly the blocks the loop is about to read isn't guaranteed
  the way `O_DIRECT` does. The same `--mem-limit` can behave differently between runs.


`--heap-limit <SIZE>` can be layered on top of `--mem-limit` and is sometimes useful
for constraining the process's own memory growth independently; but note it might work against the goal here:
capping the heap frees up room in the cgroup's budget for page cache,
which can *reduce* how much disk I/O `--mem-limit` manages to force.

## Axis 2 — transaction content

`beacon` benchmarks against pre-built, synthetic chain fragments, and each fragment is
symmetrical: every block in a given fragment contains the same type and number of
transaction (simple value transfers, block sizes, a particular Plutus script, a particular
inputs/outputs count) — never a mix. This is deliberate: it
keeps every sampled block within a fragment comparable to every other, so
that variance in validation time can be attributed to the backend or to
noise rather than to which block happened to be sampled.

Varying this axis therefore means benchmarking against a *different* chain
fragment, not varying the content within one. A fragment of simple value
transfers exercises different code paths than a fragment dominated by
script execution, and different transaction or block shapes stress the
ledger/backing-store interaction differently. Comparing validation time across
fragments can show which kinds of transactions are sensitive to
backend choice and which are dominated by CPU-bound validation work.

## Axis 3 — application vs. reapplication

A block can be validated two ways:

- **Application**: uses `ValidateAll` validation mode (possibly renamed in ledger)
- **Reapplication**: uses `ValidateNone` validation mode (possibly renamed in ledger)

Measuring both, across the same backend and transaction-content
combinations, quantifies how much time reapplication actually saves. That
number matters beyond the benchmark itself: it's a direct estimate of the
benefit available to the real Node from facilitating or expanding the use
of the reapplication control-flow path specifically.

## Measuring validation time: mutator time vs. wall-clock time

`beacon` records, per block, both the mutator time spent on the block's
ledger operations (`mut`/`mut_blockApply`, the figures used above) and the
true wall-clock time for the same operations (`totalTime`). These are not
two views of the same number: GHC's runtime accounts elapsed time into
exactly two buckets, mutator and GC, with nothing left over — confirmed
directly against `GHC.Stats.RTSStats` (`mutator_elapsed_ns`/`gc_elapsed_ns`,
summing to `elapsed_ns`; there is no third, OS-wait bucket for time blocked
on I/O) — so `totalTime` is (to rounding) `mut + gc`, and mutator time by
construction excludes GC pauses. It also, empirically, excludes most of the
cost of a disk read forced by the "sweet spot" configuration above: on real
measurements, a block whose LSM read was forced from disk via `--lsm-no-cache`
showed `mut` largely unchanged from the same block served out of page
cache, while the GC time for that block increased sharply instead. So
`mut_blockApply` answers "how expensive is the validation logic", and
`totalTime` is the only field that can answer "how expensive was this
block, including GC and any disk I/O it triggered."

*Open question:* why the cost lands specifically in `gc` rather than `mut`
isn't fully pinned down. Checking `blockio-uring` (the LSM backend's I/O
layer) rules out a couple of tempting explanations: its read/write buffers
must be pinned, but that's true for every read regardless of cache mode,
so it can't be what distinguishes a forced-disk read from a cached one;
and waiting for a completion is a plain, cooperative `MVar` block on the
calling thread — the actual blocking OS call runs on a separate, dedicated
completion thread — so the wait itself doesn't obviously cost either
bucket by construction. The likeliest explanation is that a GC already due
from ordinary heap growth lands inside the slow block rather than an
adjacent fast one, and is itself longer there — but confirming that would
need an eventlog trace correlating GC pauses against read completions,
which hasn't been done.

That gap doesn't undermine using `totalTime` here, though: it's an
exhaustive account of wall-clock time by construction, so it's already the
right number for "how expensive was this block" regardless of *why* the
RTS attributes the cost the way it does. The `majGcCount` split below
doesn't depend on the mechanism either — it separates blocks by whether a
major GC actually occurred, the causally relevant fact for this benchmark
independent of the deeper reason that GC ran long.

That makes `totalTime` the metric of interest whenever the backend axis's
I/O cost specifically is the question — but it is a much noisier metric
than `mut_blockApply`. GC pauses land on a small, semi-random subset of
blocks, and a single such block can be an order of magnitude more expensive
than a typical one. A plain mean over few samples is dominated by whichever
outliers happened to land in that particular run, which is visible
directly in repeated runs of the same configuration: the *set* of
GC-affected blocks and their rough magnitude reproduce across runs, but
the noise floor around them does not, so a raw per-run mean of `totalTime`
is not a number worth trusting on its own.

Two things follow from this:

- **Aggregate with the median alongside the mean**, and separately, split
  the sample by whether a major GC occurred during that block's operations
  (`majGcCount > 0`, already recorded per block) rather than discarding
  "outlier" blocks by eye. Filtering by eye invites exactly the kind of
  cherry-picking that would make a report untrustworthy. 
  Splitting on `majGcCount` instead uses a
  causal fact that was already recorded, not a statistical judgement call:
  it reports the steady-state cost and the GC-affected cost side by side,
  with a count of how often the latter occurs, rather than picking one
  number and hiding the other.
- **When relating `totalTime` to `mut` (e.g. as a ratio, to see how much
  wall-clock overhead a backend adds on top of pure validation logic),
  aggregate the per-block ratio, not the ratio of aggregates.** These
  diverge substantially once outliers are involved — on real measurement,
  `mean(totalTime) / mean(mut)` for one backend/fragment combination was
  1.70, while `mean(totalTime / mut)` for the same data was 1.10, because
  the ratio-of-means lets the single largest `totalTime` outlier dominate
  the numerator without the corresponding block's own (also elevated)
  `mut` value moderating it the way the per-block ratio does.

## Putting the axes together

The three axes are independent by design, so results from one axis should
be read holding the other two fixed: e.g. compare the three backend
configurations against a *fixed* chain fragment and application mode,
rather than mixing conclusions across axes. The full space is the product
of all three, but not every combination needs equal attention — the
backend axis in particular has an expected ordering (in-memory fastest,
unconstrained on-disk close behind, constrained on-disk slowest), so most
of the analytical interest is in *how much* each axis moves validation
time and whether that movement depends on the other two, not in
re-deriving the ordering itself.
