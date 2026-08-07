# Beacon Changelog

##next

* Added `mut` (total mutator time) and `mut_blockTick` (ledger-tick time) reporting to `beacon summary`/`compare`, plus an epoch-boundary-crossing breakdown of `mut_blockTick`/`totalTime` (mirroring the major-GC split): ledger ticks that cross an epoch boundary do real extra work (reward/stake-snapshot computation) and are usually the dominant source of `totalTime` outliers, distinct from major GC.
* Added a "neither major GC nor epoch boundary" steady-state breakdown, and per-tx mean/median alongside the existing per-block figures in both the major-GC and epoch-boundary breakdowns.
* Added `tableReadTime`/`mut_tableRead` reporting, and folded the ledger-table fetch they measure into `totalTime` (requires a `db-analyser` build with matching instrumentation): that fetch -- where an on-disk backend's UTxO-table reads actually happen -- previously fell outside every per-block timer `db-analyser` reports, `totalTime` included.
* Fixed `--heap-limit`/`--mem-limit` rejecting valid explicit-suffix sizes of 1000 or more (e.g. `4608M`).

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


