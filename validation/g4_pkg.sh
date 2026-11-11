#!/usr/bin/env bash
# G4.1/4.2/4.4/4.5: in-place package upgrade old -> new under systemd, with data.
# Usage: g4_pkg.sh <deb|rpm> <pg major>
. "$(dirname "$0")/lib.sh"
KIND=$1; PG=$2; T="$KIND-pg$PG"; C=g4pkg-$KIND-$PG; W=$(mktemp -d); SEED_N=${SEED_N:-100000}
fetch_old_pkgs "$W/old"; fetch_new_pkgs "$W/new"
mkdir -p "$W/ctx/old" "$W/ctx/new"
pick() { # src dst: packages for this major and arch; the meta package only fits the default major (18)
    local s=$1 dst=$2
    if [ "$KIND" = deb ]; then
        cp "$s"/ubuntu24.04-postgresql-"$PG"-documentdb_*_"$ARCH".deb "$s"/ubuntu24.04-documentdb-gateway_*_"$ARCH".deb \
           "$s"/ubuntu24.04-documentdb-postgresql-tools_*.deb "$s"/ubuntu24.04-documentdb-common_*.deb "$s"/ubuntu24.04-documentdb-"$PG"_*.deb "$dst/"
        [ "$PG" = 18 ] && cp "$s"/ubuntu24.04-documentdb_*.deb "$dst/"
    else
        cp "$s"/rhel9-postgresql"$PG"-documentdb-*."$RARCH".rpm "$s"/documentdb-gateway-*."$RARCH".rpm \
           "$s"/documentdb-postgresql-tools-*.rpm "$s"/documentdb-common-*.rpm "$s"/documentdb-"$PG"-*.noarch.rpm "$dst/"
        [ "$PG" = 18 ] && cp "$s"/documentdb-1.*.noarch.rpm "$dst/"
    fi; true
}
pick "$W/old" "$W/ctx/old"; pick "$W/new" "$W/ctx/new"; ls "$W/ctx/old" "$W/ctx/new"
cp "$VAL"/js/*.js "$W/ctx/"
if [ "$KIND" = deb ]; then
    mkdir "$W/ctx/pkgs"; cp "$ROOT/packaging/test_packages/systemd/test-systemd-lifecycle.sh" "$W/ctx/"
    { cat "$ROOT/packaging/test_packages/systemd/Dockerfile-systemd-deb-test"; } > "$W/ctx/Dockerfile"
else
    cat > "$W/ctx/Dockerfile" <<'DF'
FROM rockylinux/rockylinux:9
ARG POSTGRES_VERSION
RUN dnf install -y dnf-plugins-core epel-release && dnf config-manager --set-enabled crb && \
    dnf -y install glibc-langpack-en systemd procps-ng iproute sudo jq openssl python3 util-linux
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
RUN A=$(uname -m) && dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$A/pgdg-redhat-repo-latest.noarch.rpm && \
    . /etc/os-release && { [ "$(curl -sS -o /dev/null -w '%{http_code}' -I https://download.postgresql.org/pub/repos/yum/${POSTGRES_VERSION}/redhat/rhel-${VERSION_ID}-$A/repodata/repomd.xml)" != 404 ] || \
      sed -i 's/rhel-\$releasever_major\.\$releasever_minor-/rhel-\$releasever_major-/g' /etc/yum.repos.d/pgdg-redhat-all.repo; } && \
    dnf -qy module disable postgresql && \
    printf '[mongodb-org-8.0]\nname=MongoDB\nbaseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/8.0/%s/\ngpgcheck=1\nenabled=1\ngpgkey=https://pgp.mongodb.com/server-8.0.asc\n' "$A" > /etc/yum.repos.d/mongodb-org-8.0.repo && \
    dnf install -y mongodb-mongosh
RUN systemctl mask systemd-udevd.service systemd-udev-trigger.service systemd-modules-load.service sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount || true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DF
fi
printf 'COPY old/ /opt/old/\nCOPY new/ /opt/new/\nCOPY *.js /opt/js/\n' >> "$W/ctx/Dockerfile"
# COPY lines appended after CMD are fine; keep CMD effective.
chk 4.1.0 P0 "$T" "systemd test image builds" $D build -q --build-arg POSTGRES_VERSION="$PG" -t "g4pkg-$KIND:$PG" "$W/ctx" || { tail -30 "$OUT/chk.log"; exit 1; }
$D rm -f "$C" >/dev/null 2>&1
$D run -d --name "$C" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "g4pkg-$KIND:$PG" >/dev/null
wait_systemd() { for _ in $(seq 1 60); do case "$($D exec "$C" systemctl is-system-running 2>&1)" in running|degraded) return 0 ;; esac; sleep 2; done; return 1; }
chk 4.1.1 P0 "$T" "systemd boots" wait_systemd || exit 1
x() { $D exec -e DEBIAN_FRONTEND=noninteractive "$C" bash -c "$1"; }
if [ "$KIND" = deb ]; then INSTALL='apt-get update -qq && apt-get install -y -o Dpkg::Use-Pty=0'; QV="dpkg-query -W -f='\${Package}=\${Version}\n' 'documentdb*' 'postgresql-$PG-documentdb'"; PGBIN=/usr/lib/postgresql/$PG/bin
else INSTALL='dnf install -y'; QV="rpm -qa --qf '%{NAME}=%{VERSION}-%{RELEASE}\n' | grep -i documentdb | sort"; PGBIN=/usr/pgsql-$PG/bin; fi
EXT=$([ "$KIND" = deb ] && echo deb || echo rpm)
pgq() { x "DD=/var/lib/documentdb-local/$PG/data; port=\$(sed -n 4p \$DD/postmaster.pid); sock=\$(sed -n 5p \$DD/postmaster.pid); u=\$(stat -c %U \$DD); runuser -u \$u -- $PGBIN/psql -h \"\$sock\" -p \$port -d postgres -XAtc \"$1\"" 2>&1; }
exts() { pgq "select string_agg(extname||'='||extversion, ' ' order by extname) from pg_extension where extname ~ 'documentdb'"; }
URI="mongodb://$USR:$PW@127.0.0.1:10260/?$TLSQ"
js() { x "FP_OUT=/tmp/fp.json SEED_N=$SEED_N mongosh '$URI' --quiet --file /opt/js/$1" 2>&1; }
fp() { js fp.js > "$OUT/$T-fp-$1.log" && $D cp "$C:/tmp/fp.json" "$OUT/$T-fp-$1.json"; }
active() { x "systemctl is-active documentdb-postgresql@$PG.service documentdb-gateway-local@$PG.service" | tr '\n' ' '; }
setup() { x "printf '%s' '$PW' > /root/pw && chmod 600 /root/pw && documentdb-setup --admin-user $USR --admin-password-file /root/pw --pg-version $PG --yes --skip-init-data --verbose" > "$OUT/$T-setup-$1.log" 2>&1 && grep -Fq 'SUCCESS: DocumentDB is ready.' "$OUT/$T-setup-$1.log"; }

x "$INSTALL /opt/old/*.$EXT" > "$OUT/$T-install-old.log" 2>&1
chk 4.1.2 P0 "$T" "old packages install" x "command -v documentdb-setup" || { tail -30 "$OUT/$T-install-old.log"; exit 1; }
rec 4.1.2 INFO INFO "$T" "old: $(x "$QV" | tr '\n' ' ')"
chk 4.1.3 P0 "$T" "documentdb-setup on old" setup old || { tail -40 "$OUT/$T-setup-old.log"; exit 1; }
rec 4.1.3 INFO INFO "$T" "old: $(exts)"
js seed.js > "$OUT/$T-seed.log"; chk 4.1.4 P0 "$T" "dataset loads on old ($SEED_N items)" grep -q SEED_DONE "$OUT/$T-seed.log" || { tail -5 "$OUT/$T-seed.log"; exit 1; }
chk 4.1.5 P0 "$T" "fingerprint taken on old" fp old
# 4.4: mark every conffile, expect the marks to survive.
if [ "$KIND" = deb ]; then CF=$(x "dpkg-query -W -f='\${Conffiles}\n' 'documentdb*' 'postgresql-$PG-documentdb' 2>/dev/null | awk 'NF>=2{print \$1}' | sort -u")
else CF=$(x "for p in \$(rpm -qa | grep -i documentdb); do rpm -qc \$p; done | grep -v '^(contains' | sort -u"); fi
echo "conffiles: $CF" | tr '\n' ' '; echo
for f in $CF; do x "[ -f '$f' ] && echo '# g4-marker-keep' >> '$f'"; done
x "ls /etc/documentdb -R 2>/dev/null | head -40" > "$OUT/$T-etc-before.txt"
pid0=$(x "systemctl show -p MainPID --value documentdb-gateway-local@$PG.service")

x "$INSTALL /opt/new/*.$EXT" > "$OUT/$T-upgrade.log" 2>&1; rc=$?
chk 4.1.6 P0 "$T" "upgrade transaction succeeds (rc=$rc)" eq "$rc" 0 || tail -40 "$OUT/$T-upgrade.log"
v=$(x "$QV" | tr '\n' ' '); rec 4.1.6 INFO INFO "$T" "new: $v"
chk 4.1.7 P0 "$T" "every documentdb package moved to 1.2" bash -c "! grep -qE '=1\.0' <<<'$v' && grep -q '=1\.2' <<<'$v'"
sleep 8; a=$(active); chk 4.1.8 P0 "$T" "services active after upgrade ($a)" eq "$a" "active active "
pid1=$(x "systemctl show -p MainPID --value documentdb-gateway-local@$PG.service")
chk 4.1.9 P0 "$T" "gateway restarted onto the new binary (pid $pid0 -> $pid1)" bash -c "[ -n '$pid1' ] && [ '$pid1' != 0 ] && [ '$pid0' != '$pid1' ]"
miss=""; for f in $CF; do x "[ ! -f '$f' ] || grep -q g4-marker-keep '$f'" || miss="$miss $f"; done
chk 4.4 P0 "$T" "edited conffiles kept ($(wc -w <<<"$CF") files; lost:${miss:- none})" eq "$miss" ""
e=$(exts); rec 4.5.0 INFO INFO "$T" "after package upgrade, before setup re-run: $e binary=$(pgq 'select documentdb_api.binary_version()')"
if ! grep -q "documentdb=$NEW_EXT" <<<"$e"; then
    pgver=$(pgq "show server_version"); rec 4.5.0 INFO INFO "$T" "postgres $pgver; postmaster restarted by upgrade: $(pgq "select pg_postmaster_start_time() > now() - interval '5 minutes'")"
    chk 4.5.1 P0 "$T" "mixed state: fingerprint taken" fp mixed
    chk 4.5.2 P0 "$T" "mixed state: reads identical to old" python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-mixed.json"
    js write.js > "$OUT/$T-write-mixed.log"; chk 4.5.3 P0 "$T" "mixed state: writes and new index builds ($(grep -c ^PASS "$OUT/$T-write-mixed.log") pass)" grep -q 'WRITE_DONE failed=0' "$OUT/$T-write-mixed.log"
    chk 4.1.10 P0 "$T" "documentdb-setup re-run after upgrade (documented step)" setup new || tail -40 "$OUT/$T-setup-new.log"
    e=$(exts)
fi
chk 4.1.11 P0 "$T" "extensions at $NEW_EXT ($e)" bash -c "grep -q 'documentdb=$NEW_EXT' <<<'$e' && grep -q 'documentdb_core=$NEW_EXT' <<<'$e'"
chk 4.1.12 P0 "$T" "upgraded: fingerprint taken" fp new
chk 4.1.13 P0 "$T" "upgraded: reads identical to old" python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-new.json"
python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-new.json" soft > "$OUT/$T-soft-new.txt" 2>&1 || rec 4.1.13 P1 INFO "$T" "soft diffs after upgrade: $(grep ^DIFF "$OUT/$T-soft-new.txt" | cut -d: -f1 | tr '\n' ' ')"
js write.js > "$OUT/$T-write-new.log"; chk 4.1.14 P0 "$T" "upgraded: writes and new index builds ($(grep -c ^PASS "$OUT/$T-write-new.log") pass)" grep -q 'WRITE_DONE failed=0' "$OUT/$T-write-new.log"
$D restart -t 60 "$C" >/dev/null; wait_systemd
ok=no; for _ in $(seq 1 60); do [ "$(active)" = "active active " ] && x "mongosh '$URI' --quiet --eval 'db.runCommand({ping:1}).ok'" 2>/dev/null | grep -q 1 && { ok=yes; break; }; sleep 3; done
chk 4.1.15 P0 "$T" "stack returns after reboot" eq "$ok" yes
fp reboot; chk 4.1.16 P0 "$T" "after reboot: reads identical to old" python3 "$VAL/fpdiff.py" "$OUT/$T-fp-old.json" "$OUT/$T-fp-reboot.json"
x "journalctl --no-pager -u documentdb-postgresql@$PG.service -u documentdb-gateway-local@$PG.service" > "$OUT/$T-journal.log" 2>&1
rec 4.1.17 INFO INFO "$T" "journal lines with ERROR/FATAL/PANIC: $(grep -cE 'ERROR|FATAL|PANIC' "$OUT/$T-journal.log")"
$D rm -f "$C" >/dev/null 2>&1
! grep -qP '\tP0\tFAIL\t' "$OUT/results.tsv"
