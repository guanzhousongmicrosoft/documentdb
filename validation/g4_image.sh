#!/usr/bin/env bash
# G4.3/4.5/4.7: a data volume created by the old image, started with the new one, then back.
# Usage: g4_image.sh <pg major> [old repo:tag override]
. "$(dirname "$0")/lib.sh"
PG=$1; OLD=${2:-$(img old "$PG")}; NEW=$(img new "$PG"); T="pg$PG"
VOL=g4vol-$PG; C=g4-$PG; SEED_N=${SEED_N:-300000}
$D rm -f "$C" >/dev/null 2>&1; $D volume rm -f "$VOL" >/dev/null 2>&1; $D volume create "$VOL" >/dev/null
run_js() { # file [env...]  -> copies the script in and runs it
    local f=$1; shift; $D cp "$VAL/js/$f" "$C:/tmp/$f" && $D exec "$@" "$C" mongosh "$(uri)" --quiet --file "/tmp/$f" 2>&1; }
fp() { run_js fp.js > "$OUT/$T-fp-$1.log" && $D cp "$C:/tmp/fp.json" "$OUT/$T-fp-$1.json"; }
exts() { psqlc "$C" "select string_agg(extname||'='||extversion, ' ' order by extname) from pg_extension where extname ~ 'documentdb'"; }
boot() { # image -> ready?
    $D rm -f "$C" >/dev/null 2>&1
    $D run -d --name "$C" -v "$VOL:/data" -e DOCUMENTDB_USAGE_TELEMETRY=false "$1" --username "$USR" --password "$PW" >/dev/null && wait_ready "$C" 420; }
stop() { $D stop -t 120 "$C" >/dev/null 2>&1; echo "exit=$($D inspect -f '{{.State.ExitCode}}' "$C")"; }

$D pull -q "$OLD" >/dev/null; $D pull -q "$NEW" >/dev/null
chk 4.3.0 P0 "$T" "old image $OLD boots on a fresh volume" boot "$OLD" || { dumplogs "$C"; exit 1; }
rec 4.3.0 INFO INFO "$T" "old: $(exts) binary=$(psqlc "$C" 'select documentdb_api.binary_version()')"
run_js seed.js -e SEED_N="$SEED_N" > "$OUT/$T-seed.log"; tail -1 "$OUT/$T-seed.log"
chk 4.3.1 P0 "$T" "dataset loads on old ($SEED_N items)" grep -q SEED_DONE "$OUT/$T-seed.log" || { dumplogs "$C"; exit 1; }
chk 4.3.2 P0 "$T" "fingerprint taken on old" fp old
rec 4.3.2 INFO INFO "$T" "$(tail -1 "$OUT/$T-fp-old.log")"
s=$(stop); chk 4.3.3 P0 "$T" "old stops cleanly ($s)" eq "$s" "exit=0"

chk 4.3.4 P0 "$T" "new image $NEW boots on the old volume" boot "$NEW" || { dumplogs "$C"; exit 1; }
e=$(exts); rec 4.3.5 INFO INFO "$T" "after image swap, before any manual step: $e binary=$(psqlc "$C" 'select documentdb_api.binary_version()')"
auto=no; grep -q "documentdb=$NEW_EXT" <<<"$e" && auto=yes
rec 4.3.5 INFO INFO "$T" "extension catalog updated automatically by the image: $auto"
chk 0.3 P0 "$T" "update path to $NEW_EXT from 1.0-0 and 0.117-0 (documentdb, core)" bash -c "
  n=\$($D exec $C psql -p 9712 -d postgres -XAtc \"select count(*) from (select * from pg_extension_update_paths('documentdb') union all select * from pg_extension_update_paths('documentdb_core')) p where target='$NEW_EXT' and source in ('1.0-0','0.117-0') and path is not null\"); [ \"\$n\" = 4 ]"
if [ "$auto" = no ]; then
    chk 4.5.1 P0 "$T" "mixed state (new binaries, $OLD_EXT catalog): fingerprint taken" fp mixed
    chk 4.5.2 P0 "$T" "mixed state: reads identical to old" python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-mixed.json"
    python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-mixed.json" soft > "$OUT/$T-soft-mixed.txt" 2>&1 || rec 4.5.2 P1 INFO "$T" "soft diffs in mixed state: $(grep -c ^DIFF "$OUT/$T-soft-mixed.txt")"
    run_js write.js > "$OUT/$T-write-mixed.log"; chk 4.5.3 P0 "$T" "mixed state: writes and new index builds ($(grep -c ^PASS "$OUT/$T-write-mixed.log") pass)" grep -q 'WRITE_DONE failed=0' "$OUT/$T-write-mixed.log"
    psqlc "$C" "ALTER EXTENSION documentdb_core UPDATE; ALTER EXTENSION documentdb UPDATE;" > "$OUT/$T-alter.log" 2>&1
    psqlc "$C" "ALTER EXTENSION documentdb_extended_rum UPDATE;" >> "$OUT/$T-alter.log" 2>&1
    e=$(exts); chk 4.3.6 P0 "$T" "ALTER EXTENSION UPDATE reaches $NEW_EXT ($e)" bash -c "grep -q 'documentdb=$NEW_EXT' <<<'$e' && grep -q 'documentdb_core=$NEW_EXT' <<<'$e'"
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1; $D restart -t 120 "$C" >/dev/null
    chk 4.3.7 P0 "$T" "restart after catalog update" wait_ready "$C" 300 "$since"
fi
chk 4.3.8 P0 "$T" "upgraded: fingerprint taken" fp new
chk 4.3.9 P0 "$T" "upgraded: reads identical to old" python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-new.json"
python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-new.json" soft > "$OUT/$T-soft-new.txt" 2>&1 || rec 4.3.9 P1 INFO "$T" "soft diffs after upgrade: $(grep ^DIFF "$OUT/$T-soft-new.txt" | cut -d: -f1 | tr '\n' ' ')"
run_js write.js > "$OUT/$T-write-new.log"; chk 4.3.10 P0 "$T" "upgraded: writes and new index builds ($(grep -c ^PASS "$OUT/$T-write-new.log") pass)" grep -q 'WRITE_DONE failed=0' "$OUT/$T-write-new.log"
r=$(msh "$C" 'const d=db.getSiblingDB("upg_w"); d.c.drop(); d.c.insertMany([{_id:1,s:"a"},{_id:2,s:"A"}]); const r=d.runCommand({findAndModify:"c",query:{s:"A"},sort:{_id:1},update:{$set:{hit:1}},collation:{locale:"en",strength:2}}); print(r.ok===1 && r.value && r.value._id===1 ? "OK" : EJSON.stringify(r))' | tail -1)
chk 4.3.11 P1 "$T" "1.2 feature after upgrade: findAndModify with collation ($r)" eq "$r" OK
fp newfinal
s=$(stop); chk 4.3.12 P0 "$T" "upgraded stops cleanly ($s)" eq "$s" "exit=0"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1; $D start "$C" >/dev/null
chk 4.3.13 P0 "$T" "second start on upgraded volume" wait_ready "$C" 300 "$since"
chk 4.3.14 P0 "$T" "no crash recovery on second start" bash -c "! $D logs --since $since $C 2>&1 | grep -qE 'not properly shut down|automatic recovery in progress'"
dumplogs "$C"; cp "$OUT/$C.log" "$OUT/$T-new-container.log"
rec 4.3.15 INFO INFO "$T" "new container log lines with ERROR/FATAL/PANIC: $(grep -cE 'ERROR|FATAL|PANIC' "$OUT/$T-new-container.log")"
stop >/dev/null

# 4.7 downgrade: the old image on the upgraded volume must either refuse clearly or serve identical data.
if boot "$OLD"; then
    if fp down && python3 "$VAL/fpdiff.py" "$OUT/$T-fp-newfinal.json" "$OUT/$T-fp-down.json" > "$OUT/$T-down-diff.txt" 2>&1; then
        run_js write.js > "$OUT/$T-write-down.log"
        if grep -q 'WRITE_DONE failed=0' "$OUT/$T-write-down.log"; then rec 4.7 P1 PASS "$T" "downgrade: old image serves the upgraded volume, reads identical, writes work ($(exts))"
        else rec 4.7 P1 FAIL "$T" "downgrade: old image boots, reads identical, but writes fail: $(grep ^FAIL "$OUT/$T-write-down.log" | head -3 | tr '\n' ';')"; fi
    else rec 4.7 P1 FAIL "$T" "downgrade: old image boots but data differs or errors: $(head -3 "$OUT/$T-down-diff.txt" | tr '\n' ';')"; fi
else
    $D logs "$C" > "$OUT/$T-down-container.log" 2>&1
    rec 4.7 P1 INFO "$T" "downgrade: old image does not become ready on the upgraded volume; last log: $(grep -iE 'error|fatal|refus' "$OUT/$T-down-container.log" | tail -2 | tr '\n' ';' | cut -c1-300)"
fi
$D rm -f "$C" >/dev/null 2>&1; $D volume rm -f "$VOL" >/dev/null 2>&1
! grep -qP '\tP0\tFAIL\t' "$OUT/results.tsv"
