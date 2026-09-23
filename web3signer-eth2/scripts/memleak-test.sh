#!/usr/bin/env bash
# Verify Web3Signer memory and CPU behaviour under /reload churn and signing load.
# Originally written to reproduce / verify the /reload memory leak fixed by PR #1167.
#
# Four modes (set via MODE env var):
#   full    (default) — each cycle wipes the key dir and generates KEYS fresh keys.
#   partial           — each cycle removes REMOVE_PER_CYCLE random keys and adds
#                       ADD_PER_CYCLE new ones. Total key count grows over time,
#                       which better matches real-world rotation patterns. Leak
#                       shows as bimap_bientry_count rising faster than the
#                       expected_total column.
#   sign              — seed KEYS keys once, reload, then run the k6 signing load
#                       for SIGN_SECS per cycle against the loaded key set.
#                       Keys stay stable across cycles, isolating signing-path heap
#                       behaviour from reload churn.
#   sign-reload       — seed KEYS keys, start one k6 signing load that keeps running
#                       for the whole test, and every RELOAD_EVERY_SECS rotate keys
#                       (remove REMOVE_PER_CYCLE, add ADD_PER_CYCLE) and POST /reload
#                       while signing continues. k6 runs with ALLOW_UNKNOWN_KEYS=true:
#                       keys removed by a reload keep being requested until the
#                       simulated clients refresh their key list at the next epoch.
#
# The k6 script (SIGN_SCRIPT) simulates validator-client duties and is tuned through its
# own environment variables (SLOT_SECONDS, CLIENTS, SLASHABLE_RATIO, ...; see
# ../../web3signer-loadtest/README.md), which are passed through to k6 unchanged.
#
# Every run samples the container's cgroup CPU and memory counters every SAMPLE_SECS
# seconds into resources.tsv (SAMPLE_SECS=0 disables sampling), and each capture appends
# anon RSS, page cache, cumulative CPU, reload duration and failed k6 thresholds to
# summary.tsv. Summarise one or more runs with ./scripts/summarize.py OUTDIR [OUTDIR...].
#
# The image must ship a JDK: capture() runs jcmd / jstat inside the container.
#
# Usage:
#   ./scripts/memleak-test.sh IMAGE_TAG [CYCLES=5] [KEYS=5000]
#
# Examples:
#   ./scripts/memleak-test.sh web3signer:master-jdk           # full mode, 5 cycles
#   MODE=partial REMOVE_PER_CYCLE=2500 ADD_PER_CYCLE=5000 \
#       ./scripts/memleak-test.sh web3signer:master-jdk 5 5000
#   MODE=sign SIGN_SECS=128 SIGN_VUS=8 SLOT_SECONDS=4 CLIENTS=2 \
#       ./scripts/memleak-test.sh web3signer:develop-jdk 5 10000
#   MODE=sign-reload RELOAD_EVERY_SECS=120 REMOVE_PER_CYCLE=1000 ADD_PER_CYCLE=1000 \
#       SIGN_VUS=8 SLOT_SECONDS=4 CLIENTS=2 ./scripts/memleak-test.sh web3signer:develop-jdk 5 10000
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

IMAGE_TAG="${1:?IMAGE_TAG required (e.g. consensys/web3signer:26.4.0)}"
CYCLES="${2:-5}"
KEYS="${3:-5000}"
MODE="${MODE:-full}"
REMOVE_PER_CYCLE="${REMOVE_PER_CYCLE:-2500}"
ADD_PER_CYCLE="${ADD_PER_CYCLE:-5000}"
SIGN_SECS="${SIGN_SECS:-60}"
SIGN_VUS="${SIGN_VUS:-10}"
SIGN_SCRIPT="${SIGN_SCRIPT:-$ROOT_DIR/../web3signer-loadtest/sign-loadtest.js}"
RELOAD_EVERY_SECS="${RELOAD_EVERY_SECS:-120}"
SAMPLE_SECS="${SAMPLE_SECS:-2}"

W3S_DIR="$ROOT_DIR/web3signer"
KEYGEN_DIR="$ROOT_DIR/gen-keys"
KEYS_HOST_DIR="$W3S_DIR/config/keys"

TAG_SAFE="$(echo "$IMAGE_TAG" | tr '/:' '__')"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$ROOT_DIR/results/${TAG_SAFE}-${TS}}"
mkdir -p "$OUTDIR"

RUN_LOG="$OUTDIR/run.log"
SUMMARY="$OUTDIR/summary.tsv"
METRICS_URL="http://localhost:9001/metrics"
UPCHECK_URL="http://localhost:9000/upcheck"
RELOAD_URL="http://localhost:9000/reload"
PUBKEYS_URL="http://localhost:9000/api/v1/eth2/publicKeys"

SAMPLER_PID=""
K6_PID=""
LAST_RELOAD_SECS="NA"
LAST_K6_FAILED_THRESHOLDS="NA"

# Tee all stdout/stderr into the run log while still showing it live.
exec > >(tee -a "$RUN_LOG") 2>&1

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}

require docker
require curl
require jq
if [[ "$MODE" == sign || "$MODE" == sign-reload ]]; then
  require k6
  [[ -f "$SIGN_SCRIPT" ]] || { echo "sign script not found: $SIGN_SCRIPT"; exit 1; }
fi

cleanup() {
  [[ -n "$K6_PID" ]] && kill -INT "$K6_PID" >/dev/null 2>&1 || true
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" >/dev/null 2>&1 || true
  docker logs ws-develop > "$OUTDIR/web3signer.log" 2>&1 || true
  log "tearing down web3signer stack"
  (cd "$W3S_DIR" && docker compose down -v --remove-orphans >/dev/null 2>&1 || true)
  docker rm -f bls_keys_gen_config >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "image=$IMAGE_TAG cycles=$CYCLES keys=$KEYS outdir=$OUTDIR"

# 1. Pre-flight
log "pre-flight: ensuring docker network w3s_network exists"
docker network inspect w3s_network >/dev/null 2>&1 || docker network create w3s_network

log "pre-flight: clearing previous harness state"
"$SCRIPT_DIR/clean-all.sh" >/dev/null 2>&1 || true
# config.yaml points eth2 bulk loading at config/keystores/password.txt and clean-all.sh deletes
# it, which would make every reload report an error. No keystores are bulk loaded here.
[[ -f "$W3S_DIR/config/keystores/password.txt" ]] || printf 'password' > "$W3S_DIR/config/keystores/password.txt"

# 2. Start Web3Signer
log "starting web3signer stack"
(cd "$W3S_DIR" && WEB3SIGNER_IMAGE="$IMAGE_TAG" docker compose up -d)

log "waiting for /upcheck"
for _ in $(seq 1 60); do
  if curl -fsS "$UPCHECK_URL" >/dev/null 2>&1; then
    log "web3signer is up"
    break
  fi
  sleep 2
done
curl -fsS "$UPCHECK_URL" >/dev/null || { echo "web3signer never came up"; exit 1; }

# Helpers

# Print the requested keys from the container's cgroup cpu.stat / memory.stat as TSV (NA if absent).
cgroup_values() {
  docker exec ws-develop sh -c 'cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.stat; echo memory_current "$(cat /sys/fs/cgroup/memory.current)"' 2>/dev/null \
    | awk -v keys="$*" '
        BEGIN { n = split(keys, k, " ") }
        { v[$1] = $2 }
        END { for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "\t" : ""), ((k[i] in v) ? v[k[i]] : "NA"); print "" }'
}

# Background sampler. Its single `docker exec` per sample is charged to the container; the
# overhead is small and identical for every image, so runs stay comparable.
RESOURCE_COLUMNS="usage_usec memory_current anon file active_file inactive_file file_mapped shmem kernel sock"
sample_resources() {
  # Runs in a background subshell: never let a transient docker failure end sampling.
  set +e +o pipefail
  local out="$OUTDIR/resources.tsv" values
  printf 'epoch_s\t%s\n' "$(echo "$RESOURCE_COLUMNS" | tr ' ' '\t')" > "$out"
  while true; do
    values="$(cgroup_values $RESOURCE_COLUMNS)"
    if [[ -n "$values" && "$values" != NA* ]]; then
      printf '%s\t%s\n' "$(date +%s)" "$values" >> "$out"
    fi
    sleep "$SAMPLE_SECS"
  done
}

if [[ "$SAMPLE_SECS" != "0" ]]; then
  sample_resources &
  SAMPLER_PID=$!
  log "sampling container cgroup CPU/memory every ${SAMPLE_SECS}s into resources.tsv"
fi

pubkey_count() {
  curl -fsS "$PUBKEYS_URL" 2>/dev/null | jq 'length' 2>/dev/null || echo -1
}

# Wait until publicKeys == expected, stable across 2 consecutive polls.
wait_for_keys() {
  local expected="$1" prev=-2 cur=-1 tries=0
  while (( tries < 180 )); do
    cur="$(pubkey_count)"
    if [[ "$cur" == "$expected" && "$prev" == "$expected" ]]; then
      log "publicKeys count stable at $cur"
      return 0
    fi
    prev="$cur"
    tries=$((tries+1))
    sleep 2
  done
  log "ERROR: timed out waiting for publicKeys == $expected (last=$cur)"
  return 1
}

# POST /reload, wait for GET /reload to leave "running", then for the key count to settle.
# Records the elapsed time in LAST_RELOAD_SECS.
reload_and_wait() {
  local expected="$1" start status="unknown" tries=0
  start=$(date +%s)
  curl -fsS -X POST "$RELOAD_URL" >/dev/null
  while (( tries < 600 )); do
    status="$(curl -fsS "$RELOAD_URL" 2>/dev/null | jq -r '.status' 2>/dev/null || echo unknown)"
    [[ "$status" != "running" ]] && break
    tries=$((tries+1))
    sleep 1
  done
  wait_for_keys "$expected"
  LAST_RELOAD_SECS=$(( $(date +%s) - start ))
  log "reload finished with status=$status in ${LAST_RELOAD_SECS}s"
}

gen_keys() {
  local count="${1:-$KEYS}"
  log "generating $count keys into $KEYS_HOST_DIR"
  docker rm -f bls_keys_gen_config >/dev/null 2>&1 || true
  (cd "$KEYGEN_DIR" && KEYS_COUNT="$count" docker compose -f ./compose.bls.config.yml up --abort-on-container-exit)
}

wipe_keys() {
  log "wiping $KEYS_HOST_DIR (preserving .gitignore)"
  find "$KEYS_HOST_DIR" -mindepth 1 ! -name ".gitignore" -exec rm -rf {} +
}

# Remove N random .yaml files (and their matching .json keystores) from the
# keys dir. Used by MODE=partial / sign-reload to simulate partial rotation.
# Fisher-Yates shuffle in awk (single process, no SIGPIPE risk).
remove_random_keys() {
  local n="$1"
  local picked
  picked=$(cd "$KEYS_HOST_DIR" && ls -1 2>/dev/null | grep '\.yaml$' || true)
  [[ -z "$picked" ]] && { log "no yaml keys to remove"; return 0; }
  local selected
  selected=$(printf '%s\n' "$picked" | awk -v n="$n" '
    BEGIN { srand() }
    { a[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        r = int(rand() * (NR - i + 1)) + i
        t = a[i]; a[i] = a[r]; a[r] = t
      }
      for (i = 1; i <= n && i <= NR; i++) print a[i]
    }')
  local removed=0
  while IFS= read -r yf; do
    [[ -z "$yf" ]] && continue
    local base="${yf%.yaml}"
    rm -f "$KEYS_HOST_DIR/$yf" "$KEYS_HOST_DIR/$base.json"
    removed=$((removed + 1))
  done <<< "$selected"
  log "removed $removed random yaml/json pairs"
}

force_gc() {
  docker exec ws-develop jcmd 1 GC.run >/dev/null
}

# Number of k6 thresholds that failed in a --summary-export file ("true" means crossed).
k6_failed_thresholds() {
  jq '[.metrics[] | (.thresholds // {}) | to_entries[] | select(.value == true)] | length' "$1" 2>/dev/null || echo NA
}

# k6 exits 99 when thresholds are crossed and 105 when interrupted; both still write the
# summary export. Anything else means the load itself could not run.
check_k6() {
  local rc="$1" summary="$2" k6log="$3"
  if [[ "$rc" != 0 && "$rc" != 99 && "$rc" != 105 ]]; then
    echo "k6 run failed (exit $rc); see $k6log"
    exit 1
  fi
  LAST_K6_FAILED_THRESHOLDS="$(k6_failed_thresholds "$summary")"
  if [[ "$LAST_K6_FAILED_THRESHOLDS" != 0 ]]; then
    log "WARNING: $LAST_K6_FAILED_THRESHOLDS k6 threshold(s) crossed; see $k6log"
  fi
}

capture() {
  local cycle="$1"
  local expected_total="$2"
  local metrics_file="$OUTDIR/cycle-$cycle.metrics"
  local hist_file="$OUTDIR/cycle-$cycle.histogram"
  local jstat_file="$OUTDIR/cycle-$cycle.jstat"
  local heapinfo_file="$OUTDIR/cycle-$cycle.heapinfo"

  curl -fsS "$METRICS_URL" \
    | grep -E '^jvm_memory_|^jvm_gc_collection_seconds|^jvm_gc_memory|^process_|^http_vertx_worker_' \
    > "$metrics_file" || true
  docker exec ws-develop jcmd 1 GC.class_histogram > "$hist_file"
  docker exec ws-develop jstat -gc 1 > "$jstat_file" 2>/dev/null || true
  docker exec ws-develop jcmd 1 GC.heap_info > "$heapinfo_file" 2>/dev/null || true

  # Heap dump on first + last cycle only (costly, ~500MB+ each).
  if [[ "$cycle" -eq 0 || "$cycle" -eq "$CYCLES" ]]; then
    local dump_name="cycle-$cycle.hprof"
    log "cycle=$cycle: taking heap dump /heapdumps/$dump_name"
    docker exec ws-develop jcmd 1 GC.heap_dump "/heapdumps/$dump_name" >/dev/null 2>&1 || true
    # `./heapdumps` is mounted to /heapdumps; copy into results dir so it travels with the run.
    if [[ -f "$W3S_DIR/heapdumps/$dump_name" ]]; then
      mv "$W3S_DIR/heapdumps/$dump_name" "$OUTDIR/"
    fi
  fi

  local heap oldgen bimap sig anon file cpu
  # Heap used — match either the simpleclient `jvm_memory_bytes_used{area="heap"}` or
  # the Micrometer `jvm_memory_used_bytes{area="heap"}` naming.
  heap=$(grep -E '^jvm_memory_(bytes_used|used_bytes)\{[^}]*area="heap"' "$metrics_file" | awk '{print $NF}' | head -1)
  oldgen=$(grep -E '^jvm_memory_(pool_bytes_used|pool_used_bytes|used_bytes)\{[^}]*(pool|id)="G1 Old Gen"' "$metrics_file" | awk '{print $NF}' | head -1)
  bimap=$(grep 'com.google.common.collect.HashBiMap\$BiEntry$' "$hist_file" | awk '{print $2}' || true)
  sig=$(grep 'tech.pegasys.web3signer.signing.BlsArtifactSigner$' "$hist_file" | awk '{print $2}' || true)
  bimap="${bimap:-0}"
  sig="${sig:-0}"
  IFS=$'\t' read -r anon file cpu <<< "$(cgroup_values anon file usage_usec)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cycle" "$expected_total" "${heap:-NA}" "${oldgen:-NA}" "$bimap" "$sig" \
    "${anon:-NA}" "${file:-NA}" "${cpu:-NA}" "$LAST_RELOAD_SECS" "$LAST_K6_FAILED_THRESHOLDS" >> "$SUMMARY"
  log "cycle=$cycle expected_total=$expected_total heap=${heap:-NA} old_gen=${oldgen:-NA} bimap_bientry=$bimap artifact_signer=$sig rss_anon=${anon:-NA} page_cache=${file:-NA} reload_secs=$LAST_RELOAD_SECS k6_failed_thresholds=$LAST_K6_FAILED_THRESHOLDS"
}

# Summary header
printf 'cycle\texpected_total\theap_used_bytes\told_gen_bytes\tbimap_bientry_count\tartifact_signer_count\trss_anon_bytes\tpage_cache_bytes\tcpu_usage_usec\treload_secs\tk6_failed_thresholds\n' > "$SUMMARY"

log "mode=$MODE keys=$KEYS remove_per_cycle=$REMOVE_PER_CYCLE add_per_cycle=$ADD_PER_CYCLE"

# 3. Seed initial KEYS
gen_keys "$KEYS"
current_total="$KEYS"

# 4. Cycle 0 (initial load)
log "cycle 0: initial reload"
reload_and_wait "$current_total"
force_gc
capture 0 "$current_total"

if [[ "$MODE" == sign-reload ]]; then
  # One load for the whole test; stopped with SIGINT after the last cycle.
  log "starting background k6 signing load (vus=${SIGN_VUS}) for the whole test"
  ALLOW_UNKNOWN_KEYS=true k6 run --quiet --duration 24h --vus "$SIGN_VUS" \
    --summary-export "$OUTDIR/k6-sign-reload.json" \
    "$SIGN_SCRIPT" > "$OUTDIR/k6-sign-reload.log" 2>&1 &
  K6_PID=$!
fi

# 5. Cycle loop
for i in $(seq 1 "$CYCLES"); do
  case "$MODE" in
    full)
      log "cycle $i: full replace — wipe all + gen $KEYS"
      wipe_keys
      gen_keys "$KEYS"
      current_total="$KEYS"
      reload_and_wait "$current_total"
      ;;
    partial)
      log "cycle $i: partial rotation — remove $REMOVE_PER_CYCLE + add $ADD_PER_CYCLE"
      remove_random_keys "$REMOVE_PER_CYCLE"
      gen_keys "$ADD_PER_CYCLE"
      current_total=$((current_total - REMOVE_PER_CYCLE + ADD_PER_CYCLE))
      reload_and_wait "$current_total"
      ;;
    sign)
      # Keys stay stable across cycles — k6 always signs with loaded validators.
      # Run the k6 sign load test against the live endpoint for SIGN_SECS.
      log "cycle $i: k6 signing load — duration=${SIGN_SECS}s vus=${SIGN_VUS}"
      set +e
      k6 run --quiet --duration "${SIGN_SECS}s" --vus "$SIGN_VUS" \
        --summary-export "$OUTDIR/cycle-$i.k6.json" \
        "$SIGN_SCRIPT" > "$OUTDIR/cycle-$i.k6.log" 2>&1
      rc=$?
      set -e
      check_k6 "$rc" "$OUTDIR/cycle-$i.k6.json" "$OUTDIR/cycle-$i.k6.log"
      ;;
    sign-reload)
      log "cycle $i: signing for ${RELOAD_EVERY_SECS}s, then rotate (remove $REMOVE_PER_CYCLE + add $ADD_PER_CYCLE) and reload under load"
      sleep "$RELOAD_EVERY_SECS"
      kill -0 "$K6_PID" 2>/dev/null || { echo "k6 exited early; see $OUTDIR/k6-sign-reload.log"; exit 1; }
      remove_random_keys "$REMOVE_PER_CYCLE"
      gen_keys "$ADD_PER_CYCLE"
      current_total=$((current_total - REMOVE_PER_CYCLE + ADD_PER_CYCLE))
      reload_and_wait "$current_total"
      ;;
    *)
      echo "ERROR: unknown MODE=$MODE (use 'full', 'partial', 'sign' or 'sign-reload')"; exit 1 ;;
  esac
  force_gc
  capture "$i" "$current_total"
done

if [[ -n "$K6_PID" ]]; then
  log "stopping background k6 signing load"
  kill -INT "$K6_PID" 2>/dev/null || true
  set +e
  wait "$K6_PID"
  rc=$?
  set -e
  K6_PID=""
  check_k6 "$rc" "$OUTDIR/k6-sign-reload.json" "$OUTDIR/k6-sign-reload.log"
  log "k6 failed thresholds over the whole run: $LAST_K6_FAILED_THRESHOLDS"
fi

log "done. summary:"
cat "$SUMMARY"
log "artifacts in $OUTDIR"
