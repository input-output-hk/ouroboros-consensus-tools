# Beacon Changelog

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


