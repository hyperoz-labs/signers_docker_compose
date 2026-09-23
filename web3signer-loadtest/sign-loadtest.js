// Web3Signer eth2 signing load test (k6).
//
// Simulates the duty traffic that one or more consensus (validator) clients send to a Web3Signer
// running in eth2 mode with slashing protection. Every VU owns a disjoint stripe of the keys
// loaded in Web3Signer; VU i belongs to logical client `client-(i % CLIENTS)`, so each simulated
// client signs only its own subset of keys. Once per slot, every VU signs for its keys:
//
//   - RANDAO_REVEAL + BLOCK_V2 when one of its keys is the (pseudo-random) proposer of the slot,
//   - ATTESTATION + AGGREGATION_SLOT (selection proof) for keys whose attestation duty falls in
//     the slot; each key attests exactly once per epoch, with source = epoch - 1, target = epoch,
//   - SYNC_COMMITTEE_MESSAGE for keys in the simulated sync committee.
//
// A small fraction of attestations and proposals is followed by a deliberately slashable request
// (double vote / double proposal). Refusing to sign those is the correct behaviour: Web3Signer
// must answer HTTP 412, anything else is counted in `slashing_missing_refusal`.
//
// Payloads are deterministic per (slot, epoch), so signing the same duty twice (e.g. when keys
// move between VUs after a /reload) is idempotent and never trips slashing protection. Epochs
// start at the current unix time in seconds unless START_EPOCH is set, which keeps them
// increasing across runs against a persistent slashing protection database.
//
// Configuration (environment variables, all optional):
//   W3S_URL                   Web3Signer base URL (default http://localhost:9000)
//   SLOT_SECONDS              slot length; 12 is mainnet, lower values compress time (default 12)
//   CLIENTS                   number of simulated consensus clients (default 1)
//   MAX_KEYS                  sign with at most this many keys, 0 = all loaded keys (default 0)
//   NETWORK_VALIDATORS        network size used to derive proposal and sync committee odds (default 1000000)
//   PROPOSER_RATIO            per-slot probability that one of our keys proposes (default MAX_KEYS / NETWORK_VALIDATORS)
//   SYNC_COMMITTEE_KEYS       keys in the sync committee (default ceil(keys * 512 / NETWORK_VALIDATORS))
//   SLASHABLE_RATIO           fraction of duties followed by a slashable request (default 0.01)
//   ALLOW_UNKNOWN_KEYS        treat HTTP 404 (key removed by /reload) as expected (default false)
//   BATCH                     max parallel requests per VU (default 32)
//   ATTESTATION_P99_MS        threshold for attestation signing latency p99 (default 1000)
//   START_EPOCH               first epoch (default: unix time in seconds)
//   GENESIS_VALIDATORS_ROOT, PREVIOUS_FORK_VERSION, CURRENT_FORK_VERSION, BLOCK_VERSION
//
// Examples:
//   k6 run sign-loadtest.js                                           # mainnet timing, 4 VUs, 5m
//   SLOT_SECONDS=4 CLIENTS=2 k6 run --vus 8 --duration 10m sign-loadtest.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';

function env(name, def) {
  const value = __ENV[name];
  return value === undefined || value === '' ? def : value;
}

function num(name, def) {
  return Number(env(name, def));
}

const cfg = {
  url: env('W3S_URL', 'http://localhost:9000'),
  slotSeconds: num('SLOT_SECONDS', 12),
  clients: Math.max(1, num('CLIENTS', 1)),
  maxKeys: num('MAX_KEYS', 0),
  networkValidators: num('NETWORK_VALIDATORS', 1000000),
  proposerRatio: env('PROPOSER_RATIO', undefined),
  syncCommitteeKeys: env('SYNC_COMMITTEE_KEYS', undefined),
  slashableRatio: num('SLASHABLE_RATIO', 0.01),
  allowUnknownKeys: env('ALLOW_UNKNOWN_KEYS', 'false') === 'true',
  batch: num('BATCH', 32),
  attestationP99: num('ATTESTATION_P99_MS', 1000),
  startEpoch: env('START_EPOCH', undefined),
  gvr: env('GENESIS_VALIDATORS_ROOT', '0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95'),
  previousVersion: env('PREVIOUS_FORK_VERSION', '0x05000000'),
  currentVersion: env('CURRENT_FORK_VERSION', '0x06000000'),
  blockVersion: env('BLOCK_VERSION', 'FULU'),
};

export const options = {
  vus: 4,
  duration: '5m',
  batch: cfg.batch,
  batchPerHost: cfg.batch,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    sign_errors: ['count==0'],
    slashing_unexpected_refusal: ['count==0'],
    slashing_missing_refusal: ['count==0'],
    latency_attestation: [`p(99)<${cfg.attestationP99}`],
  },
};

const DUTIES = ['attestation', 'aggregation_slot', 'sync_committee', 'randao', 'block', 'slashable'];
const latency = Object.fromEntries(DUTIES.map((d) => [d, new Trend(`latency_${d}`, true)]));
const signatures = new Counter('signatures');
const signErrors = new Counter('sign_errors');
const unknownKey = new Counter('unknown_key');
const expectedRefusal = new Counter('slashing_expected_refusal');
const unexpectedRefusal = new Counter('slashing_unexpected_refusal');
const missingRefusal = new Counter('slashing_missing_refusal');
const missedSlots = new Counter('missed_slots');

const SLOTS_PER_EPOCH = 32;
const SIGNATURE = /^0x[0-9a-fA-F]{192}$/;
const HEADERS = { 'Content-Type': 'application/json' };
const FORK_INFO = {
  fork: { previous_version: cfg.previousVersion, current_version: cfg.currentVersion, epoch: '0' },
  genesis_validators_root: cfg.gvr,
};

// FNV-1a 32-bit hash with a murmur3 finalizer, so that inputs differing only in their last
// characters (consecutive slots / epochs) still map to uncorrelated values.
function hash32(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return h >>> 0;
}

// Deterministic, uniformly distributed value in [0, 1).
function unit(text) {
  return hash32(text) / 4294967296;
}

// Deterministic 32-byte root (mulberry32 stream seeded by the tag).
function root(tag) {
  let seed = hash32(tag);
  let out = '0x';
  for (let i = 0; i < 8; i++) {
    seed = (seed + 0x6d2b79f5) >>> 0;
    let t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    out += ((t ^ (t >>> 14)) >>> 0).toString(16).padStart(8, '0');
  }
  return out;
}

function attestation(slot, epoch, variant) {
  return {
    type: 'ATTESTATION',
    fork_info: FORK_INFO,
    attestation: {
      slot: String(slot),
      index: '0',
      beacon_block_root: root(`block:${slot}${variant}`),
      source: { epoch: String(epoch - 1), root: root(`checkpoint:${epoch - 1}`) },
      target: { epoch: String(epoch), root: root(`checkpoint:${epoch}${variant}`) },
    },
  };
}

function aggregationSlot(slot) {
  return { type: 'AGGREGATION_SLOT', fork_info: FORK_INFO, aggregation_slot: { slot: String(slot) } };
}

function syncCommitteeMessage(slot) {
  return {
    type: 'SYNC_COMMITTEE_MESSAGE',
    fork_info: FORK_INFO,
    sync_committee_message: { beacon_block_root: root(`block:${slot - 1}`), slot: String(slot) },
  };
}

function randaoReveal(epoch) {
  return { type: 'RANDAO_REVEAL', fork_info: FORK_INFO, randao_reveal: { epoch: String(epoch) } };
}

function block(slot, proposerIndex, variant) {
  return {
    type: 'BLOCK_V2',
    fork_info: FORK_INFO,
    beacon_block: {
      version: cfg.blockVersion,
      block_header: {
        slot: String(slot),
        proposer_index: String(proposerIndex),
        parent_root: root(`block:${slot - 1}`),
        state_root: root(`state:${slot}${variant}`),
        body_root: root(`body:${slot}${variant}`),
      },
    },
  };
}

// Per-VU state (the init context is instantiated once per VU).
let allKeys = [];
let myKeys = [];
let mySyncKeys = [];
let keysEpoch = -1;
let lastSlot = -1;

function vuCount() {
  const scenario = exec.test.options.scenarios[exec.scenario.name];
  return (scenario && (scenario.vus || scenario.maxVUs)) || 1;
}

function refreshKeys(epoch) {
  const res = http.get(`${cfg.url}/api/v1/eth2/publicKeys`, { tags: { duty: 'public_keys' } });
  if (res.status !== 200) {
    signErrors.add(1, { duty: 'public_keys', status: String(res.status) });
    return;
  }
  let keys = res.json();
  keys.sort();
  if (cfg.maxKeys > 0) {
    keys = keys.slice(0, cfg.maxKeys);
  }
  const vus = vuCount();
  const me = exec.vu.idInTest - 1;
  const syncCount =
    cfg.syncCommitteeKeys !== undefined
      ? Number(cfg.syncCommitteeKeys)
      : Math.ceil((keys.length * 512) / cfg.networkValidators);
  allKeys = keys;
  myKeys = [];
  for (let i = me; i < keys.length; i += vus) {
    myKeys.push(keys[i]);
  }
  mySyncKeys = [];
  for (let i = me; i < Math.min(syncCount, keys.length); i += vus) {
    mySyncKeys.push(keys[i]);
  }
  keysEpoch = epoch;
}

function proposerIndex(slot) {
  const ratio =
    cfg.proposerRatio !== undefined ? Number(cfg.proposerRatio) : allKeys.length / cfg.networkValidators;
  if (allKeys.length === 0 || unit(`proposer:${slot}`) >= ratio) {
    return -1;
  }
  return hash32(`proposer-index:${slot}`) % allKeys.length;
}

function sleepUntil(epochMillis) {
  const delay = epochMillis - Date.now();
  if (delay > 0) {
    sleep(delay / 1000);
  }
}

function record(request, res) {
  latency[request.duty].add(res.timings.duration);
  if (res.status === 404 && cfg.allowUnknownKeys) {
    unknownKey.add(1, { duty: request.duty });
    return false;
  }
  if (request.expectRefusal) {
    const refused = res.status === 412;
    if (refused) {
      expectedRefusal.add(1, { duty: request.duty });
    } else {
      missingRefusal.add(1, { duty: request.duty, status: String(res.status) });
    }
    check(res, { 'slashable request refused with 412': () => refused });
    return refused;
  }
  const ok = res.status === 200 && SIGNATURE.test(String(res.body).trim());
  if (ok) {
    signatures.add(1, { duty: request.duty });
  } else if (res.status === 412) {
    unexpectedRefusal.add(1, { duty: request.duty });
  } else {
    signErrors.add(1, { duty: request.duty, status: String(res.status) });
  }
  check(res, { 'signed with a BLS signature': () => ok });
  return ok;
}

function send(requests, client) {
  if (requests.length === 0) {
    return [];
  }
  const responses = http.batch(
    requests.map((r) => [
      'POST',
      `${cfg.url}/api/v1/eth2/sign/${r.pubkey}`,
      JSON.stringify(r.body),
      { headers: HEADERS, tags: { duty: r.duty, client } },
    ])
  );
  return responses.map((res, i) => record(requests[i], res));
}

export function setup() {
  const res = http.get(`${cfg.url}/api/v1/eth2/publicKeys`);
  const keys = res.status === 200 ? res.json() : [];
  if (!Array.isArray(keys) || keys.length === 0) {
    throw new Error(`No public keys loaded in Web3Signer at ${cfg.url} (status ${res.status})`);
  }
  const startEpoch = cfg.startEpoch !== undefined ? Number(cfg.startEpoch) : Math.floor(Date.now() / 1000);
  console.log(
    `keys=${keys.length} clients=${cfg.clients} slotSeconds=${cfg.slotSeconds} startEpoch=${startEpoch} ` +
      `slashableRatio=${cfg.slashableRatio} allowUnknownKeys=${cfg.allowUnknownKeys}`
  );
  // Emit a zero sample so thresholds and the summary always include these counters.
  [signErrors, unknownKey, expectedRefusal, unexpectedRefusal, missingRefusal, missedSlots].forEach((c) => c.add(0));
  return { t0: Date.now(), baseSlot: startEpoch * SLOTS_PER_EPOCH };
}

// One iteration per slot.
export default function (data) {
  const slotMillis = cfg.slotSeconds * 1000;
  let slot = data.baseSlot + Math.floor((Date.now() - data.t0) / slotMillis);
  if (slot <= lastSlot) {
    slot = lastSlot + 1;
    sleepUntil(data.t0 + (slot - data.baseSlot) * slotMillis);
  } else if (lastSlot >= 0 && slot > lastSlot + 1) {
    missedSlots.add(slot - lastSlot - 1);
  }
  lastSlot = slot;

  const epoch = Math.floor(slot / SLOTS_PER_EPOCH);
  if (epoch !== keysEpoch) {
    refreshKeys(epoch);
  }
  if (allKeys.length === 0) {
    return;
  }
  const vus = vuCount();
  const me = exec.vu.idInTest - 1;
  const client = `client-${me % cfg.clients}`;
  const slotStart = data.t0 + (slot - data.baseSlot) * slotMillis;

  // Block proposal at the start of the slot.
  const proposer = proposerIndex(slot);
  if (proposer >= 0 && proposer % vus === me) {
    const pubkey = allKeys[proposer];
    const [randaoSigned] = send([{ pubkey, duty: 'randao', body: randaoReveal(epoch) }], client);
    if (randaoSigned) {
      const [blockSigned] = send([{ pubkey, duty: 'block', body: block(slot, proposer, '') }], client);
      if (blockSigned && unit(`slash-block:${slot}`) < cfg.slashableRatio) {
        send([{ pubkey, duty: 'slashable', expectRefusal: true, body: block(slot, proposer, ':conflict') }], client);
      }
    }
  }

  // Attestations, selection proofs and sync committee messages one third into the slot.
  sleepUntil(slotStart + slotMillis / 3);
  const slotInEpoch = slot % SLOTS_PER_EPOCH;
  const attesters = myKeys.filter((pubkey) => hash32(`${pubkey}:${epoch}`) % SLOTS_PER_EPOCH === slotInEpoch);
  const requests = [];
  for (const pubkey of attesters) {
    requests.push({ pubkey, duty: 'attestation', body: attestation(slot, epoch, '') });
  }
  for (const pubkey of attesters) {
    requests.push({ pubkey, duty: 'aggregation_slot', body: aggregationSlot(slot) });
  }
  for (const pubkey of mySyncKeys) {
    requests.push({ pubkey, duty: 'sync_committee', body: syncCommitteeMessage(slot) });
  }
  const results = send(requests, client);

  // Double votes for a fraction of the attestations that were just signed.
  const doubleVotes = [];
  attesters.forEach((pubkey, i) => {
    if (results[i] && unit(`slash-attestation:${pubkey}:${epoch}`) < cfg.slashableRatio) {
      doubleVotes.push({ pubkey, duty: 'slashable', expectRefusal: true, body: attestation(slot, epoch, ':conflict') });
    }
  });
  send(doubleVotes, client);
}
