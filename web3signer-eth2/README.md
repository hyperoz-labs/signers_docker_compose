# Web3Signer/Hashicorp/PostgreSQL docker compose

Docker compose example showcasing Web3Signer and Hashicorp Vault integration with TLS enabled.

## Prerequisites
1. Ensure Docker is running
2. A custom docker network named `w3s_network` exists or created:
   ```sh
   docker network create w3s_network
   ```
3. For profiling: Linux host or Docker Desktop with 4GB+ memory allocated

---

## 1. Start Hashicorp Vault

Using a different terminal window, bring Hashicorp Vault up. See [README](./vault/README.md) for more details.

```sh

cd ./vault
docker compose up
```
---

## 2. Generate and Load Keys.

The `gen-keys` [docker compose](./gen-keys/README.md) can be used to set up BLS keys that will be loaded into
Web3Signer. Based on your testing needs, you can generate the following configurations:

- Generate and insert BLS Keys into Hashicorp Vault to be loaded via yaml config files. Generated in
  `./web3signer/config/keys` directory.
- Generate and insert BLS Keys into Hashicorp Proxy to be loaded via yaml config files. Generated in
  `./web3signer/config/keys` directory.
- Generate (Light) BLS keystores and password files to be loaded via yaml config files. Generated in
  `./web3signer/config/keys` directory.
- Generate (Light) BLS Keystores and password files to be bulkloaded. Generated in `./web3signer/config/keystores`
  directory.

You can mix and match the above configurations based on your testing needs.

The Keys can either be generated before starting Web3Signer or after it is running.


## 3. Run Web3Signer

```sh
cd ./web3signer
docker compose up
```
Or with custom web3siger image (and/or config file):
```sh
WEB3SIGNER_IMAGE=web3signer:keymanager_pr CONFIG_FILE_NAME=config-km.yaml docker compose up
```

[!NOTE] If you are modifying SQL files and want to rebuild sql-copier image, run:

```shell
docker compose build --no-cache && docker compose up
```

Reload the Web3Signer configuration to load the keys (if generated after starting Web3Signer):
```sh
curl -X POST http://localhost:9000/reload
```

To test Key Manager API:

```sh
CONFIG_FILE_NAME=config-km.yaml docker compose up
```
Followed by running `import_keystores.sh` which will upload keystores from `./config/keystores` directory. They should 
be uploaded to `config/km/ks` directory or skip storage on disk depending on the setting in `config-km.yaml`.


---

## 4. Monitoring (Optional)

Bring up Prometheus + Grafana alongside a running Web3Signer. Both attach to the same `w3s_network` and
Prometheus scrapes Web3Signer metrics from `ws-develop:9001`.

```sh
cd ./web3signer
docker compose -f compose.monitoring.yml up -d
```

Access:
- Grafana: http://localhost:3000 (anonymous `Viewer` enabled; login `admin` / `admin` for edit access)
- Prometheus: http://localhost:9090

The Web3Signer dashboard is auto-provisioned from `./monitoring/grafana/dashboards/`. `clean-all.sh` tears
down the monitoring stack along with the rest.

---

## 5. Profiling (Optional)

The `ws-develop` image ships a JRE only, so `jcmd`/`jmap` aren't inside the
container. Attach from a throwaway JDK sidecar that shares the signer's PID
namespace — `jcmd 1` then targets the web3signer JVM:

```shell
# Sanity check that attach works
docker run --rm --pid=container:ws-develop --cap-add=SYS_PTRACE --user root \
  eclipse-temurin:25-jdk jcmd 1 VM.version

# Force a Full GC (useful before reading retained-heap metrics in Grafana)
docker run --rm --pid=container:ws-develop --cap-add=SYS_PTRACE --user root \
  eclipse-temurin:25-jdk jcmd 1 GC.run

# Class histogram — grep for e.g. BlsArtifactSigner, HashBiMap$BiEntry
docker run --rm --pid=container:ws-develop --cap-add=SYS_PTRACE --user root \
  eclipse-temurin:25-jdk jcmd 1 GC.class_histogram | head -40

# Heap dump — JVM writes to ws-develop's /heapdumps (bind-mounted to ./heapdumps on host)
docker run --rm --pid=container:ws-develop --cap-add=SYS_PTRACE --user root \
  eclipse-temurin:25-jdk jcmd 1 GC.heap_dump /heapdumps/w3s_heapdump.hprof
```

Notes:
- `--cap-add=SYS_PTRACE` and `--user root` are required for the HotSpot attach
  handshake across containers.
- The heap-dump path is resolved inside the **target JVM's** filesystem, so the
  `./heapdumps:/heapdumps` mount already declared in `web3signer/compose.yml`
  delivers the file to the host without any extra sidecar mount.

---

## 6. Memory and load harness (Optional)

[`scripts/memleak-test.sh`](scripts/memleak-test.sh) brings the stack up with a given image, generates keys and,
after every cycle, forces a GC and captures heap usage, a class histogram, `jstat`, container anon RSS, page cache
and cumulative CPU. It also samples the container's cgroup CPU and memory every 2 seconds into `resources.tsv`.
It needs `docker`, `curl`, `jq`, `k6` (signing modes) and an image that contains a JDK, because `jcmd`/`jstat` run
inside the container.

| `MODE` | Each cycle |
|---|---|
| `full` | wipe all keys, generate `KEYS` new ones, `/reload` |
| `partial` | remove `REMOVE_PER_CYCLE` random keys, add `ADD_PER_CYCLE`, `/reload` |
| `sign` | run the k6 signing load for `SIGN_SECS` with `SIGN_VUS` VUs; keys stay stable |
| `sign-reload` | one k6 signing load runs for the whole test; every `RELOAD_EVERY_SECS` keys are rotated and reloaded under load |

The k6 script's own variables (`SLOT_SECONDS`, `CLIENTS`, `SLASHABLE_RATIO`, ...) are passed through; see
[`../web3signer-loadtest/README.md`](../web3signer-loadtest/README.md).

```sh
# 10K keys, two consensus clients, 3x mainnet signing rate, 5 cycles of one epoch each
MODE=sign SIGN_SECS=128 SIGN_VUS=8 SLOT_SECONDS=4 CLIENTS=2 \
  ./scripts/memleak-test.sh web3signer:develop-jdk 5 10000

# the same load while 1000 keys are rotated and reloaded every 2 minutes
MODE=sign-reload RELOAD_EVERY_SECS=120 REMOVE_PER_CYCLE=1000 ADD_PER_CYCLE=1000 \
  SIGN_VUS=8 SLOT_SECONDS=4 CLIENTS=2 ./scripts/memleak-test.sh web3signer:develop-jdk 5 10000

# Markdown summary: per-cycle table, heap / RSS slope and CPU; several runs add a comparison table
./scripts/summarize.py results/<run> [results/<other-run> ...]
```

Results are written to `results/<image>-<timestamp>/`: `summary.tsv`, `resources.tsv`, `cycle-N.*`, the k6 JSON
summaries and logs, and `web3signer.log`. A leak shows as a live-heap (class histogram total) or anon RSS slope
that stays positive across cycles; a healthy run plateaus after the first cycle. In `sign-reload` mode the heap
metric in `summary.tsv` is read while the load continues, so prefer the class histogram total that
`summarize.py` reports.

To build a JDK image from a Web3Signer checkout, swap the JRE for the JDK in `docker/Dockerfile`:

```sh
./gradlew distTar
sed -E 's/(eclipse-temurin:[^ @]+)-jre@sha256:[0-9a-f]+/\1-jdk/' docker/Dockerfile > /tmp/Dockerfile.jdk
docker build --build-arg TAR_FILE=./build/distributions/web3signer-develop.tar.gz \
  -f /tmp/Dockerfile.jdk -t web3signer:develop-jdk .
```

## Clean up
```shell
# From another terminal window
docker compose down

# Full cleanup
./scripts/clean-all.sh
```

---
