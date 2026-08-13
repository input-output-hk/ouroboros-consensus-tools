# check-leios-analysis

Checks that `db-analyser` reports the transactions of a certified endorser block (EB).

A Leios ranking block (RB) that carries a certificate has an empty body on the wire.
Such a block is a certifying block, or cert-RB.
The transactions that it puts on the chain are those of the EB that it certifies, and those live in the node's Leios database, not in the ImmutableDB.
So every `db-analyser` pass has to read that database to report them.
This script runs several passes and checks that they agree.

The script lives here rather than in the consensus repository, because it is a manual test.
It needs a real Leios chain, and it does not run on CI.
It belongs to the Leios prototype, which lives on the `leios-prototype` branch of [ouroboros-consensus](https://github.com/IntersectMBO/ouroboros-consensus/).

## Running it

The script takes the data directory of a node that followed a Leios chain.
It derives every other path from that: `config.json`, `db/`, and `db/leios.db`.

```sh
export NODE_DIR="/path/to/cardano-node-data/db-leios"
```

The script runs `db-analyser` and it never builds one.
It reads the `--db-analyser` flag, then the `DB_ANALYSER` variable, then `PATH`.
Build `db-analyser` in the consensus repository and name the binary:

```sh
export DB_ANALYSER="$(cabal list-bin db-analyser)"   # in the consensus repo
check-leios-analysis $NODE_DIR
```

A full chain takes a few minutes.
`--num-blocks-to-process` shortens the run, at the risk of stopping before the first certifying block.

## What it checks

`--count-tx-outputs` and `--show-block-txs-size` read the Leios database by different paths.
One takes the transaction sizes from the `ebTxs` table.
The other joins `txs` and decodes every transaction.
The main check is that both name the same blocks as certifying an EB.

The script also fails if the chain holds no certifying block.
Without such a block every other check holds and nothing is proven.

It also runs `db-analyser` twice more, to check the two ways of failing on a Leios chain:

- With no `leios.db` under the `--db` path and no `--stubbed-leios-db`, the tool must refuse to start, name the flag, and write no `leios.db`.
- With `--stubbed-leios-db` on a chain that holds a certifying block, the tool must stop at that block and name the flag.

### --benchmark

`--benchmark` adds `--benchmark-ledger-ops` to the run. The script checks that:

- `--benchmark-ledger-ops` and `--show-block-txs-size` report the same number of rows
- `--benchmark-ledger-ops` and `--show-block-txs-size` name the same blocks as certifying an EB
- for each of those blocks, the `ebNumTxs` and `ebTxsBytes` of `--benchmark-ledger-ops` equal the EB tx count and the EB tx size of `--show-block-txs-size`
- `--benchmark-ledger-ops` reports a non-zero `ebBytes` for each of those blocks
- `--benchmark-ledger-ops` reports 0 in `ebBytes`, `ebTxsBytes`, `ebNumTxs`, `ebReadTime`, and `mut_ebRead` for every other block

`--show-block-txs-size` reads the rows of the EB body.
`--benchmark-ledger-ops` resolves the EB closure, which joins the `txs` table.
So a transaction that the `txs` table lacks breaks the third check above.

`--benchmark-ledger-ops` maintains a ledger state, so it applies every block from the start of the chain.
`--count-tx-outputs` and `--show-block-txs-size` only read blocks.
So `--benchmark` costs more time than every other check in the script.

```sh
check-leios-analysis $NODE_DIR --benchmark
```

### --repro

`--repro` adds `--repro-mempool-and-forge 1` to the run.
The script runs the same checks against `--repro-mempool-and-forge`, except the `ebBytes` one, and one more:

- `--repro-mempool-and-forge` reports 0 transactions of the block itself for every block that certifies an EB, because such a block has an empty body

`--repro-mempool-and-forge` also applies every block from the start of the chain, and it fills a mempool as well.

```sh
check-leios-analysis $NODE_DIR --repro
```

## What it does not check

The checks show that the passes agree, and that each one is consistent with itself.
They do not show that the numbers are right.
Nothing here gives an independent count of the outputs in an EB.
