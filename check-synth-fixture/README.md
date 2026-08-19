# check-synth-fixture

Checks that a hand-built node configuration makes `db-synthesizer` forge a Dijkstra chain.

`db-synthesizer` needs three things: a node configuration, a genesis whose staking delegates to a pool, and the credentials of that pool.
A configuration that misses any of them still runs.
It reports zero forgers, or it forges a chain in an earlier era.
Neither outcome fails loudly, so this script drives the whole pipeline and reads what each tool wrote.

The script lives here rather than in the consensus repository, because it is a manual test.
It needs binaries from three repositories and a fixture directory that no CI job builds.
It belongs to the Leios prototype, which lives on the `leios-prototype` branch of [ouroboros-consensus](https://github.com/IntersectMBO/ouroboros-consensus/).

## Running it

The fixture sits in [`fixture/`](fixture/) next to the script, so no path is needed.
That directory holds `config.json` and the five genesis files it names.
Pass a directory as the one positional argument to check a different fixture.

The repository keeps no signing key, so a checkout has no credentials.
[`make-fixture`](make-fixture) writes them, and it rewrites the parts of `shelley-genesis.json` that are derived from them.
Run it once:

```sh
export CARDANO_CLI=/path/to/cardano-cli
./check-synth-fixture/make-fixture
```

The script runs the tools and it never builds one.
For each tool it reads the flag, then the environment variable, then `PATH`.
Build the three consensus tools on the `leios-prototype` branch:

```sh
# in the consensus repository, inside `nix develop`
export DB_SYNTHESIZER="$(cabal list-bin db-synthesizer)"
export DB_IMMUTALISER="$(cabal list-bin db-immutaliser)"
export DB_ANALYSER="$(cabal list-bin db-analyser)"
```

`cardano-cli` is optional and only the key checks use it.
It must come from the `leios-prototype` branch of [cardano-cli](https://github.com/IntersectMBO/cardano-cli/), which is the branch that has the Dijkstra era commands.

```sh
export CARDANO_CLI=/path/to/cardano-cli
check-synth-fixture
```

Without a `cardano-cli`, the script says so and skips those checks.
`--skip-key-checks` skips them without looking for the binary.

`--blocks N` sets how many blocks to forge, and defaults to 200.
That takes about half a minute, because each block holds a few hundred transactions.
`--work-dir DIR` chooses where the ChainDB and the tool logs go, instead of a fresh directory under `/tmp`.

## What it checks

`check_fixture` reads the configuration and the genesis before any tool runs.

- The configuration names a genesis file for every era, and each file exists.
- `TestDijkstraHardForkAtEpoch` is 0.
  Without it Dijkstra keeps its default-version trigger, which needs an on-chain protocol version of 12, and a chain from genesis stops in Conway.
- The genesis protocol version is 12.
  Each era's `createInitialState` enforces `eraProtVerLow <= curProtVer`, and Dijkstra's low version is 12.
- The genesis registers exactly one pool, that pool's map key matches its own `poolId`, and every stake credential delegates to it.
- The pool carries a `leiosKey` of two even-length hex strings.
  The ledger reads that field as optional, so a wrong shape gives a keyless committee seat and no error.

`check_keys` compares the genesis against the credentials.
The checks above are self-consistent, so they hold even when the genesis names a pool whose keys nobody holds.
These do not.

- `stake-pool id` of the cold verification key equals the genesis `poolId`.
- `key-hash-VRF` of the VRF verification key equals the genesis `vrf`.
- The three credential files carry the envelope types that `db-synthesizer` parses.

`check_synthesis` forges the chain.

- `db-synthesizer` reports at least one forger, which means the credentials loaded.
- It forges and adopts every block that `--blocks` asked for.

`check_immutalisation` copies the chain out of the VolatileDB.
`db-analyser` reads the ImmutableDB, so without this step it counts nothing.

- The VolatileDB holds exactly one candidate chain.
- `db-immutaliser` reports a new ImmutableDB tip.

`check_analysis` re-applies the chain.

- `db-analyser --count-blocks` with `--db-validation validate-all-blocks` agrees with the number forged.
  This is the strongest check here.
  Full validation replays every block from genesis, so it proves the genesis is coherent and not merely well formed.

It also reports the `--count-tx-outputs` totals as a note rather than a check.
Today `db-synthesizer` passes no transactions and no certificate, so every column reads 0.
Those totals start to move when the forge loop produces endorser blocks.

`check_era` reads the era tag of every block that reached the ImmutableDB.
A forged block proves nothing about the era on its own, because forging also succeeds in Conway.

- Every block carries the Dijkstra era tag.

A Cardano block is stored as a CBOR 2-list, `[eraTag, block]`.
`encodeDiskHfcBlock` in `Ouroboros/Consensus/Cardano/Node.hs` prepends the tag, and `decodeDiskHfcBlock` reads it back, so tag 8 means Dijkstra by definition.
The script finds each block by walking the ImmutableDB secondary index, whose entry layout is in `Ouroboros/Consensus/Storage/ImmutableDB/Impl/Index/Secondary.hs`.

This check earns its place.
Drop the two Dijkstra edits from a working fixture and the run still forges 50 blocks that all validate.
They are Conway blocks.

## Building the fixture

The script checks a fixture, and it does not build one.
Start from the configuration of a node that followed a Leios chain, and copy `config.json` plus the five genesis files into a new directory.
The devnet stake is delegated to a pool whose cold key we do not hold, so the pool has to be replaced.

Generate the credentials with a `cardano-cli` from the `leios-prototype` branch:

```sh
K="$FIXTURE/keys"; mkdir -p "$K"
cardano-cli dijkstra node key-gen \
  --cold-verification-key-file "$K/cold.vkey" \
  --cold-signing-key-file "$K/cold.skey" \
  --operational-certificate-issue-counter-file "$K/opcert.counter"
cardano-cli dijkstra node key-gen-VRF --verification-key-file "$K/vrf.vkey" --signing-key-file "$K/vrf.skey"
cardano-cli dijkstra node key-gen-KES --verification-key-file "$K/kes.vkey" --signing-key-file "$K/kes.skey"
cardano-cli dijkstra node key-gen-BLS --verification-key-file "$K/bls.vkey" --signing-key-file "$K/bls.skey"
cardano-cli dijkstra node issue-op-cert \
  --kes-verification-key-file "$K/kes.vkey" \
  --cold-signing-key-file "$K/cold.skey" \
  --operational-certificate-issue-counter-file "$K/opcert.counter" \
  --kes-period 0 --out-file "$K/opcert.json"
cardano-cli dijkstra node issue-pop-BLS --bls-signing-key-file "$K/bls.skey" --out-file "$K/bls.pop"
```

`--kes-period 0` covers a whole epoch on the devnet genesis, which sets `slotsPerKESPeriod` to 129600 against an `epochLength` of 86400.

Then edit two files.
In `config.json`, add `"TestDijkstraHardForkAtEpoch": 0` and drop `ShelleyGenesisHash`, which goes stale.
In `shelley-genesis.json`, set `protocolParams.protocolVersion.major` to 12, then replace the single `staking.pools` entry and re-point `staking.stake` at it:

- `poolId` is the output of `cardano-cli dijkstra stake-pool id --cold-verification-key-file cold.vkey --output-hex`.
- `vrf` is the output of `cardano-cli dijkstra node key-hash-VRF --verification-key-file vrf.vkey`.
- `leiosKey` holds `leiosPubKey` and `leiosPossessionProof` as raw hex.
  `cardano-cli` writes those two keys as text envelopes, so strip the CBOR byte-string header off each `cborHex` field.
  The public key is 96 bytes and the proof is 48.

Nothing reads `leiosKey` yet.
The forge loop passes `fbEbTxs = []` and `fbMayLeiosCert = Nothing`, so it produces no endorser block to vote on.
The field is in the fixture so that the committee seat is keyed once the forge loop can vote.

Last, make the fixture spendable.
`db-synthesizer` fills each block with transactions that respend one output, and it needs a key that owns that output:

```sh
cardano-cli address key-gen --verification-key-file "$K/payment.vkey" --signing-key-file "$K/payment.skey"
cardano-cli address key-hash --payment-verification-key-file "$K/payment.vkey"
```

Add an `initialFunds` entry for that key in `shelley-genesis.json`.
The key of the entry is the raw address in base16: header byte `60`, which is an enterprise address on the testnet, and then the 28-byte key hash.
Give it enough lovelace to pay one ada of fee for every transaction of the run, and keep the `initialFunds` total under `maxLovelaceSupply`.
`config.json` pins no `ShelleyGenesisHash`, so this edit needs no hash update, and the pseudo-`TxIn` of each existing entry is derived from its own address and does not move.

Without that entry, `db-synthesizer` stops on the first slot it leads.
