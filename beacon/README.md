# Benchmarks, exploration, and analysis of Consensus

`beacon` benchmarks a Cardano ledger + consensus integration by driving
[`db-analyser`](https://github.com/IntersectMBO/ouroboros-consensus/) against
a chain fragment, recording per-slot metrics (see
`app/Cardano/Beacon/SlotDataPoint.hs`), and comparing the results across runs,
Consensus versions, or GHC versions.

## Building and running

From within the flake's dev shell (`nix develop`):

```
cabal build beacon
cabal run beacon -- <options> <command> [<command> ...]
```

`beacon` also builds as a nix package (`nix build .#beacon`).

## Chain fragments

`beacon run` operates on a registered chain fragment: a synthetic chain or a
`cardano-node` chain, together with its `db-analyser` config. Chain fragments
are registered in a JSON file kept in the beacon data directory (`--data-dir`,
default `./beacon-data`); use `beacon list-chains` to see what's registered.

## Commands

- `build` — build and link a `db-analyser` binary for a given Consensus
  revision, without running it.
- `run` — perform a benchmark run against a registered chain fragment,
  producing a run file.
- `store` — store a produced run file under its slug, so it can later be
  summarized or compared.
- `summary` — show performance data for a stored slug.
- `compare` — compare two stored slugs.
- `variance` — run a variance analysis across all stored runs for a slug.
- `list-chains` — list the chain fragments registered in the data directory.

Run `cabal run beacon -- <command> --help` for a command's options.


Adds two alternative, independently-composable mechanisms to force the LSM backend to exercise real disk I/O during a beacon run, plus observability for both:

- `--heap-limit <SIZE>`: a GHC RTS heap cap (-M<SIZE>), applicable regardless of backend or the other two flags.
- `--mem-limit <SIZE>`: wraps `db-analyser` in a cgroup memory limit via `systemd-run --user --scope` (MemoryHigh, with a derived MemoryMax safety net), pressuring the OS page cache to force real disk I/O.
- `--lsm-no-cache`: passes a new `--lsm-no-cache` flag through to db-analyser (bypasses the OS page cache via O_DIRECT for the LSM backend), a more direct alternative to `--mem-limit` where the db-analyser build supports it.

Capability detection (db-analyser --help scrutiny, plus a functional probe that a `time -v` binary on `PATH` actually behaves like GNU time) now happens once per resolved install, stored as `EnvironmentCapabilities` in `RunEnvironment`, rather than re-probed or threaded as loose booleans.

Every `db-analyser` invocation is wrapped with `time -v` when available, recording peak RSS / block I/O counts as a new optional `ProcessStats` field on `BeaconRun`

The chosen limits themselves are recorded on `BeaconRunMeta` - `toSlug` encodes the new configuration:
* no limits at all:  slugs identically to before
* ` --lsm-no-cache`: folds into the backend segment ("lsm" / "lsmnc", as it's meaningless outside the LSM backend)
* heap/mem limits: get one shared slug segment

Also adds GNU time to the nix devShell, to guarantee a GNU `time` binary.