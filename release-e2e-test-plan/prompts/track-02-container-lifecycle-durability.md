# Track 02 — Container lifecycle & data durability

**You are** a reliability engineer trying to lose someone's data or wedge their
container. Restarts, crashes, `docker stop`, power-loss simulation, concurrent
containers on one volume, and volume persistence are your weapons.

**Read first:** `ENVIRONMENT-SETUP.md` (§2 image, §7 fixed behaviors) and
`REPORT-TEMPLATE.md`. **Write** to `reports/track-02-container-lifecycle-durability.md`.

## SUT
`documentdb-local:pg17-0.116.0` (repeat key cases on `pg18-0.116.0`). Always pin a
**named volume** or host bind for `/data` so you can reason about persistence.

## What to test (checklist)

1. **Clean start/stop.** Start with a named volume, write data, `docker stop`
   (SIGTERM). Confirm the entrypoint does a **graceful PG fast-stop** (logs show a
   clean shutdown, not "database system was interrupted"). Restart the container on
   the same volume; confirm the data is present and **no WAL recovery** was needed
   (a clean stop must not force recovery). Recovery-on-every-restart is S2.
2. **Data persistence across `docker rm`.** Stop + `docker rm` the container (keep
   the volume). Start a **new** container on the same volume. Data must survive.
   Then confirm an **anonymous** volume (no `-v`) does **not** persist across
   `docker rm` (that's expected — verify the docs say so).
3. **Hard kill / crash recovery.** `docker kill` (SIGKILL) mid-write. Restart.
   Confirm PG recovers, the extension loads, and previously-acked writes are
   present. Data that was acknowledged and then lost after SIGKILL is **S1**.
4. **SIGTERM propagation (PID 1).** Confirm `docker stop` returns promptly (within
   its grace period) and does not rely on the 10s SIGKILL fallback — i.e. the trap
   fires. A container that always takes the full grace period to stop is S3.
5. **Concurrent-container lock — #43 / #62 (finding-seed, §7).** Start container A
   on volume V. While A runs, start container B on the **same** volume V. **B must
   refuse to start and name the conflict**, and **A must stay up and healthy** (its
   data intact). The old bug deleted A's live lock and took both down while both
   still reported `Running=true`. Verify:
   - B exits non-zero with a clear "data directory in use" style message.
   - A is still `Running=true` **and** still serves queries after B's attempt.
   - The `flock` is released when A dies: kill A, then B (or a fresh container) can
     now take the volume. A leftover `postmaster.pid` must **not** block it.
   Any way to get two live postmasters on one volume, or to make A lose data via a
   B start, is **S1**.
6. **Stale lock file.** Pre-seed the volume with a stale `postmaster.pid` (simulate
   an unclean prior boot), then start a container. It must start cleanly (the
   flock, not the pid file, is authoritative). A refusal to start on a *stale* (not
   live) lock is S3.
7. **Restart policy & long-run.** Run with `--restart=on-failure`, kill the gateway
   process inside, confirm the container exits and Docker restarts it, and that it
   comes back serving. Let one container run for an extended period under light
   load; confirm no PID leak, no unbounded log growth, no fd leak.
8. **Disk-full behavior.** Constrain the volume (e.g. small tmpfs/quota), fill it
   during writes. Confirm the failure is *safe* (writes rejected, clear error, no
   corruption on restart once space is freed). Silent corruption is S1.
9. **Init hooks lifecycle.** With `--init-data-path` mounting a JS dir, confirm
   scripts run **once per fresh volume**, in alphabetical order, and are **not**
   re-run on restart. Confirm a failing init script does not get silently retried
   (matches the documented "runs once, not retried" contract). Also test
   `--init-data true` sample-data seeding once per volume.
10. **Readiness signal usability (ties to C1).** Since there's no HEALTHCHECK,
    document exactly what an operator must grep/poll for readiness
    (`=== DocumentDB is ready ===`) and how long it takes cold vs warm. Measure it.

## Expected results
Clean stop ⇒ no recovery on restart; data survives rm+recreate on a named volume;
SIGKILL recovers acked writes; concurrent B refuses while A survives; stale pid
ignored; disk-full is safe. Report timings for readiness.

## Report
`REPORT-TEMPLATE.md`. Capture container logs for the concurrency and crash cases
under `reports/artifacts/track-02-*`. Give explicit verdicts on the #43/#62 lock
behavior. Any acked-write loss is an immediate S1 with full repro.
