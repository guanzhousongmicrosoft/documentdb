# DocumentDB local image integration tests

End-to-end tests that exercise a running `documentdb-local` container against
the wire-protocol API surface that the image promises. They complement two
neighboring suites:

| Suite | Lives in | Tests |
| --- | --- | --- |
| Entrypoint unit tests | `scripts/documentdb_local_tests/` | The `emulator_entrypoint.sh` shell logic in isolation |
| Upstream compatibility gate | `functional-tests/` | A pinned upstream pytest image against the running container |
| **Integration tests (this folder)** | `integration-tests/` | Image-level concerns: data-plane via mongosh, container config scenarios |

The integration tests are owned by `documentdb-local`. They give PR-time
feedback even when only image-level files change (entrypoint, init-data
scripts, Dockerfile, gateway packaging) and they keep the contract narrow
enough to remain green across PG 15 / 16 / 17 / 18.

## Layout

```text
integration-tests/
  README.md
  run.sh                   Local runner that orchestrates data-plane tests
  tests/                   mongosh JS files run via `mongosh --file`
    00-connectivity.js     ping / hello / buildInfo / listDatabases / serverStatus / dbStats / collStats
    01-crud.js             insert / find / count / distinct / update / delete + query operators
    02-update-operators.js field and array update operators, positional, upsert + $setOnInsert
    03-indexes.js          single / compound / unique / sparse / partial / TTL / multikey
    04-aggregation.js      stages, expressions, accumulators across the supported surface
    05-collection-and-database.js  createCollection / validators / views / rename / dropDatabase
    06-bson-types.js       every BSON type the gateway exposes through mongosh
    07-cursors-and-projection.js   projection forms, batchSize / getMore, sort+skip+limit
    08-error-handling.js   duplicate-key, validator rejection, invalid update operator, unknown command
  scenarios/               Bash scripts that each start their own container with a
                           specific configuration and verify behavior
    auth.sh                correct creds, wrong password, wrong user, missing creds, --create-user false
    init-data.sh           --init-data true, custom volume mount, --skip-init-data, invalid JS rejected
    persistence.sh         mount /data volume, write docs, restart container, verify data survives
```

TLS-mode behavior is covered by the existing
[`scripts/run_documentdb_local_tls_tests.sh`](../scripts/run_documentdb_local_tls_tests.sh)
and is wired into the same CI workflow.

## Test conventions

Each `tests/*.js` file is **self-contained**:

- Drops its own database (`it_<NN>_<name>`) at the start for idempotency.
- Defines small inline `assert` / `assertEq` / `check(name, fn)` helpers.
- Calls `quit(1)` if any check failed, so `mongosh --file` exits non-zero and
  the runner propagates failure.
- Prints `PASS` / `FAIL` per check and a summary line, so logs are easy to
  scan.

The runner mounts the `tests/` directory into the container read-only and
invokes each file in alphabetical order with `docker exec ... mongosh --file`.
A single container is reused across every JS test file in one run, which keeps
the data-plane suite fast.

## Run locally

Build the image and run all data-plane tests:

```bash
# from the repo root
./packaging/build_packages.sh --os deb13 --pg 17 --output-dir downloaded-artifacts
DEB_FILE=$(find downloaded-artifacts -maxdepth 1 -type f -name '*.deb' ! -name '*dbgsym*' | sort | head -1)
docker build \
  --build-arg BASE_IMAGE=debian:trixie-slim \
  --build-arg POSTGRES_VERSION=17 \
  --build-arg "DEB_PACKAGE_REL_PATH=${DEB_FILE}" \
  -t documentdb-local:dev \
  -f packaging/gateway/docker/Dockerfile_documentdb_local .

./documentdb-local/integration-tests/run.sh --image documentdb-local:dev
```

Run a single test file against an already-running container managed by the
runner:

```bash
./documentdb-local/integration-tests/run.sh \
  --image documentdb-local:dev \
  --only 03-indexes.js
```

Run the scenario scripts (each manages its own container):

```bash
./documentdb-local/integration-tests/scenarios/auth.sh        documentdb-local:dev
./documentdb-local/integration-tests/scenarios/init-data.sh   documentdb-local:dev
./documentdb-local/integration-tests/scenarios/persistence.sh documentdb-local:dev
```

## CI

`.github/workflows/documentdb_local_image_tests.yml` runs everything on every
non-draft pull request, every push to `main`, and on `workflow_dispatch`.
Layout:

1. `build-image` (matrix per PG) - builds the deb, builds the image,
   uploads it as an artifact named `documentdb-local-image-pg<N>`.
2. `data-plane-tests` (matrix per PG) - downloads the artifact and runs
   every `tests/*.js` via `run.sh`.
3. `auth-tests`, `tls-tests`, `init-data-tests`, `persistence-tests`
   (matrix per PG) - download the artifact and run the matching scenario
   script.

Each test job uploads per-PG logs and the container `docker logs` output on
failure under `image-tests-logs-<job>-pg<N>`.

## Adding a new test

- For a data-plane operator or command, add a `check(...)` to the most
  relevant `tests/*.js` file. Keep checks focused (one assertion per check
  is ideal, multiple are fine if they describe one behavior).
- For a new container-configuration scenario (a new entrypoint flag, a
  new env var), add a `scenarios/<name>.sh` script and wire it into the
  workflow with its own matrix job.
- Avoid features that the upstream `functional-tests` allowlist does not
  already cover (text search, 2dsphere, transactions): they would create
  PR-time flakes without adding stable value.
