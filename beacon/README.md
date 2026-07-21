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
