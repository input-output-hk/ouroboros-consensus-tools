# Beacon Changelog

## 0.5.0.0 -- 2026-08-28

* Added `mut` (total mutator time) and `mut_blockTick` (ledger-tick time) reporting to `beacon summary`/`compare`, plus an epoch-boundary-crossing breakdown of `mut_blockTick`/`totalTime` (mirroring the major-GC split): ledger ticks that cross an epoch boundary do real extra work (reward/stake-snapshot computation) and are usually the dominant source of `totalTime` outliers, distinct from major GC.
* Added a "neither major GC nor epoch boundary" steady-state breakdown, and per-tx mean/median alongside the existing per-block figures in both the major-GC and epoch-boundary breakdowns.
* Added `tableReadTime`/`mut_tableRead` reporting: the ledger-table fetch they measure -- where an on-disk backend's UTxO-table reads actually happen -- runs before the 5 ledger operations, and used to fall outside every per-block timer `db-analyser` reports. It is now part of `totalTime`/`mut`/`gc` for runs recorded by a `db-analyser` built from `ouroboros-consensus@0ebd397da` or later, which is what `beacon` assumes; a run from an older build excludes it there, and nothing in the run's JSON distinguishes the two.

## 0.4.0.0 -- 2026-08-18

* Removed Cairo-based plotting in favour of an internal fork of `easyplot` (a gnuplot wrapper), reducing build size and dependency footprint as well as improving portability.
* Fix `--heap-limit`/`--mem-limit` rejecting valid values >= 1000M

## 0.3.0.0 -- 2026-07-28

* Added a memory-limiting feature for `beacon run`, letting on-disk backend benchmarks be run under realistic memory pressure.
* Added `totalTime` (wall-clock) reporting alongside mutator time, including a derived ratio and a major-GC-affected/steady-state split.
* Documented the benchmarking methodology in a new `beacon/docs/METHODOLOGY.md`.

## 0.2.0.0 -- 2026-07-14

* Reworked `beacon` into a full CLI (`build`, `run`, `store`, `summary`, `compare`, `variance`, `list-chains`) with registered chain fragments and slug-based run storage, replacing the previous single-shot comparison script.
* Added variance and CDF-based statistical analysis across stored runs.
* Split the codebase into `Cardano.Beacon.*` modules.

## 0.1.0.0 -- 2023-08-15

* First version. Released on an unsuspecting world.


