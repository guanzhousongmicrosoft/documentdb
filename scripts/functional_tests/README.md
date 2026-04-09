# Local functional tests

This directory contains the local Docker Compose flow for running DocumentDB functional tests outside GitHub Actions. The CI workflow also reuses `run_with_compose.sh`, so local runs and workflow runs follow the same path.

## Prerequisites

- Docker with the Compose plugin (`docker compose`)
- A functional test image to run, provided either as a registry reference or a local image ID
- A Bash-capable shell. On Windows, use WSL or another environment that can run the Bash helper scripts in this directory.

## Quick start

Run the smoke suite:

```bash
./scripts/functional_tests/run_with_compose.sh run \
  --test-image ghcr.io/documentdb/functional-tests:latest
```

Run the full suite:

```bash
./scripts/functional_tests/run_with_compose.sh run \
  --test-image ghcr.io/documentdb/functional-tests:latest \
  --scope full
```

`--test-image` accepts any Docker image reference or a local image ID. If you omit it, the script falls back to `ghcr.io/documentdb/functional-tests:latest`.

## Outputs

- Test results are written to `functional-test-results/` in the repository root.
- The local stack is defined in `docker-compose.yml`.
- Temporary deselections live in `deselect.list`.

## Useful commands

Show stack logs:

```bash
./scripts/functional_tests/run_with_compose.sh logs
```

Tear down the local stack:

```bash
./scripts/functional_tests/run_with_compose.sh down
```

Build the local `documentdb-local` image without running tests:

```bash
./scripts/functional_tests/run_with_compose.sh build \
  --test-image ghcr.io/documentdb/functional-tests:latest
```
