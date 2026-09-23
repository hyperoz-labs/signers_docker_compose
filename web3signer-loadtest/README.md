# Web3Signer eth2 signing load test (k6)

[`sign-loadtest.js`](sign-loadtest.js) simulates the signing traffic that consensus (validator) clients send to a
Web3Signer running in eth2 mode. Use it to check latency, CPU and memory behaviour with realistic key counts (e.g. 10K
keys) and a slashing protection database.

## What it sends

Each VU owns a disjoint stripe of the keys loaded in Web3Signer. VUs are grouped into `CLIENTS` simulated consensus
clients (VU *i* belongs to `client-(i % CLIENTS)`), mirroring one Web3Signer serving several clients that each own a
subset of the keys. Every slot, each VU signs for its own keys:

| Duty | Request type | When |
|---|---|---|
| Block proposal | `RANDAO_REVEAL`, then `BLOCK_V2` (block header) | start of the slot, when one of its keys is the pseudo-random proposer |
| Attestation | `ATTESTATION` (source = epoch − 1, target = epoch) | one third into the slot; every key attests once per epoch |
| Aggregation selection proof | `AGGREGATION_SLOT` | alongside each attestation |
| Sync committee | `SYNC_COMMITTEE_MESSAGE` | every slot, for the sync committee keys |
| Slashing protection probe | conflicting `ATTESTATION` / `BLOCK_V2` for a duty that was just signed | after `SLASHABLE_RATIO` of the attestations and proposals |

Refusing to sign is the correct outcome for the slashing protection probes: Web3Signer must answer HTTP 412. Payloads
are deterministic per slot and epoch, so a duty signed twice (for example after a `/reload` moves keys between VUs) is
idempotent and never trips slashing protection. Epochs start at the current unix time in seconds unless `START_EPOCH`
is set, so they keep increasing across runs against a persistent slashing protection database.

At mainnet timing, 10K keys generate about 52 signing requests per second on average (attestations plus selection
proofs), arriving in bursts one third into each slot. `SLOT_SECONDS=4` triples that rate.

## Configuration

All settings are environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `W3S_URL` | `http://localhost:9000` | Web3Signer base URL |
| `SLOT_SECONDS` | `12` | slot length; 12 is mainnet, lower values compress time |
| `CLIENTS` | `1` | number of simulated consensus clients |
| `MAX_KEYS` | `0` | sign with at most this many keys (0 = all loaded keys) |
| `NETWORK_VALIDATORS` | `1000000` | network size used for the default proposal and sync committee odds |
| `PROPOSER_RATIO` | keys / `NETWORK_VALIDATORS` | per-slot probability that one of the keys proposes |
| `SYNC_COMMITTEE_KEYS` | ⌈keys × 512 / `NETWORK_VALIDATORS`⌉ | keys in the sync committee |
| `SLASHABLE_RATIO` | `0.01` | fraction of duties followed by a slashable probe |
| `ALLOW_UNKNOWN_KEYS` | `false` | count HTTP 404 (key removed by `/reload`) as expected instead of as an error |
| `BATCH` | `32` | maximum parallel requests per VU |
| `ATTESTATION_P99_MS` | `1000` | threshold on the attestation signing latency p99 |
| `START_EPOCH` | unix time in seconds | first epoch |
| `GENESIS_VALIDATORS_ROOT`, `PREVIOUS_FORK_VERSION`, `CURRENT_FORK_VERSION`, `BLOCK_VERSION` | mainnet / Fulu | fork data used in every request |

Keys are re-read from `/api/v1/eth2/publicKeys` at every epoch, so keys added or removed by `/reload` are picked up.

## Results

On top of the standard k6 metrics the script reports:

- `signatures`: successfully signed duties; `latency_<duty>` trends for `attestation`, `aggregation_slot`,
  `sync_committee`, `randao`, `block` and `slashable`.
- `slashing_expected_refusal`: slashable probes refused with 412.
- Threshold counters, which must stay at 0: `sign_errors` (unexpected status), `slashing_unexpected_refusal` (412 on a
  legitimate duty) and `slashing_missing_refusal` (a slashable probe that was not refused).
- `unknown_key` (404 responses) and `missed_slots` (slots a VU skipped because it fell behind).

k6 exits with code 99 when a threshold is crossed.

## Prerequisites

- A running Web3Signer eth2 instance on `http://localhost:9000` with at least one key loaded. See
  [`../web3signer-eth2/README.md`](../web3signer-eth2/README.md).
- k6 installed:
  - macOS: `brew install k6`
  - Debian/Ubuntu: see the apt repo steps at <https://k6.io/docs/get-started/installation/>
  - Other platforms: <https://k6.io/docs/get-started/installation/>

## Run

```sh
# mainnet timing, 4 VUs, 5 minutes
k6 run sign-loadtest.js

# two consensus clients, 3x mainnet signing rate
SLOT_SECONDS=4 CLIENTS=2 k6 run --vus 8 --duration 10m sign-loadtest.js
```

For memory-leak checks and `/reload` under load, drive the script through
[`../web3signer-eth2/scripts/memleak-test.sh`](../web3signer-eth2/scripts/memleak-test.sh) (`MODE=sign` or
`MODE=sign-reload`), which also captures heap, RSS and CPU per cycle.
