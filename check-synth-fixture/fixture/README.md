# The fixture that `check-synth-fixture` reads

A node configuration, five genesis files, and the credentials of the one pool
that the genesis registers. `db-synthesizer` forges a Dijkstra chain from it.
`db-immutaliser` and `db-analyser` then read that chain.

Run the check from a checkout, with no argument:

    ./check-synth-fixture/check-synth-fixture

## The keys hold nothing

Every key here is a test key of a synthetic chain that no network ever carried.
The chain starts at the genesis in this directory and it forges in one process.
The keys sign nothing outside this directory and they hold no funds.

| File | Purpose |
|---|---|
| `keys/cold.skey`, `keys/cold.vkey` | the cold key of the pool that the genesis registers |
| `keys/vrf.skey`, `keys/vrf.vkey` | the VRF key of that pool |
| `keys/kes.skey`, `keys/kes.vkey` | the KES key, at period 0 |
| `keys/opcert.json`, `keys/opcert.counter` | the operational certificate of that pool |
| `keys/bls.skey`, `keys/bls.vkey`, `keys/bls.pop` | the Leios key of that pool, and its proof of possession |
| `keys/payment.skey`, `keys/payment.vkey` | the key whose output the generated transactions spend |

## What makes the chain reach Dijkstra

Two settings, and both are needed. `config.json` sets
`TestDijkstraHardForkAtEpoch` to 0. `shelley-genesis.json` sets the protocol
version to 12, which is the lowest version that Dijkstra accepts. Without both,
the tool forges 50 Conway blocks that validate cleanly, and nothing complains.

## What makes the blocks carry transactions

`keys/payment.skey` and its entry in `initialFunds`. The address is the enterprise
form: header byte `60`, then the 28-byte hash of `keys/payment.vkey`.
`db-synthesizer` spends that output, and then it spends the output that its own
transaction made, until the block is full.

If the entry is absent, `db-synthesizer` stops on the first slot it leads.
