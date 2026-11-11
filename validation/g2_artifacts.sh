#!/usr/bin/env bash
# G2: artifact integrity. Packages and images of the new release against the old one.
. "$(dirname "$0")/lib.sh"
W=$(mktemp -d); fetch_new_pkgs "$W/new"; fetch_old_pkgs "$W/old"
sudo apt-get update -qq >/dev/null 2>&1; sudo apt-get install -y -qq rpm lintian rpmlint binutils cpio skopeo jq >/dev/null 2>&1
T=bundle
chk 2.1 P0 $T "SHA256SUMS verifies ($(grep -c . "$W/new/SHA256SUMS") entries)" bash -c "cd $W/new && sha256sum -c --quiet SHA256SUMS"
chk 2.1b P0 $T "25 files, same set of package names as 1.0.0" bash -c "
  n() { ls \$1 | sed -E 's/1\.2[-~]rc1|1\.0[.-]0/VER/g' | sort; }; diff <(n $W/old) <(n $W/new) && [ \$(ls $W/new | wc -l) = 25 ]"
norm() { sed -E 's/1\.2[-~]rc1|1\.0[.-]0|1\.2\.0|1\.2-0/VER/g'; }
flist() { case "$1" in *.deb) dpkg-deb -c "$1" | awk '{print $1, $6}' ;; *.rpm) rpm -qplv "$1" 2>/dev/null | awk '{print $1, $NF}' ;; esac | sed -E 's#^(.)[^ ]* \./#\1 /#; s#^(.)[^ ]* /#\1 /#' | sort -u; }
meta() { case "$1" in *.deb) dpkg-deb -f "$1" Package Version Architecture Depends Pre-Depends Recommends Conflicts Replaces Provides License Maintainer ;; *.rpm) rpm -qp --qf 'Name: %{NAME}\nVersion: %{VERSION}-%{RELEASE}\nArch: %{ARCH}\nLicense: %{LICENSE}\n' "$1" 2>/dev/null; rpm -qpR "$1" 2>/dev/null | grep -v '^rpmlib' | sort | sed 's/^/Requires: /' ;; esac; }
: > "$OUT/pkg-removed.txt"; : > "$OUT/pkg-added.txt"; : > "$OUT/pkg-meta-diff.txt"; pairs=0
for o in "$W"/old/*.deb "$W"/old/*.rpm; do
    key=$(basename "$o" | norm); n=$(for f in "$W"/new/*; do [ "$(basename "$f" | norm)" = "$key" ] && echo "$f"; done | head -1)
    [ -n "$n" ] || { echo "NO NEW COUNTERPART $o" >> "$OUT/pkg-removed.txt"; continue; }
    pairs=$((pairs + 1))
    comm -23 <(flist "$o" | norm) <(flist "$n" | norm) | sed "s|^|$key: |" >> "$OUT/pkg-removed.txt"
    comm -13 <(flist "$o" | norm) <(flist "$n" | norm) | sed "s|^|$key: |" >> "$OUT/pkg-added.txt"
    diff <(meta "$o" | grep -v '^Version' | norm) <(meta "$n" | grep -v '^Version' | norm) | grep '^[<>]' | sed "s|^|$key: |" >> "$OUT/pkg-meta-diff.txt"
    v=$(meta "$n" | grep '^Version'); echo "$key $v" >> "$OUT/pkg-versions.txt"
done
chk 2.3a P0 $T "no file of a 1.0.0 package is missing from its 1.2 counterpart ($pairs pairs; removed: $(grep -c . "$OUT/pkg-removed.txt"))" test ! -s "$OUT/pkg-removed.txt" || head -40 "$OUT/pkg-removed.txt"
rec 2.3b INFO INFO $T "files added since 1.0.0: $(grep -c . "$OUT/pkg-added.txt") (pkg-added.txt)"
rec 2.3c INFO INFO $T "dependency/metadata lines changed since 1.0.0: $(grep -c . "$OUT/pkg-meta-diff.txt") (pkg-meta-diff.txt)"; head -40 "$OUT/pkg-meta-diff.txt"
chk 2.3d P0 $T "every package carries version 1.2~rc1 (or 1.2-0~rc1 form)" bash -c "! grep -vE 'Version: 1\.2[~.-]' $OUT/pkg-versions.txt"; sort -u "$OUT/pkg-versions.txt" | head -30
# 2.4: ELF checks on unpacked payloads.
unpack() { mkdir -p "$2"; case "$1" in *.deb) dpkg-deb -x "$1" "$2" ;; *.rpm) (cd "$2" && rpm2cpio "$1" | cpio -idm --quiet 2>/dev/null) ;; esac; }
elfs() { find "$1" -type f \( -name '*.so' -o -perm -u+x \) -exec sh -c 'file -b "$1" | grep -q ELF && echo "$1"' _ {} \; ; }
: > "$OUT/elf-rpath.txt"; : > "$OUT/elf-needed-new.txt"
for n in "$W"/new/*.deb "$W"/new/*.rpm; do
    key=$(basename "$n" | norm); o=$(for f in "$W"/old/*; do [ "$(basename "$f" | norm)" = "$key" ] && echo "$f"; done | head -1)
    unpack "$n" "$W/x/new/$key"; [ -n "$o" ] && unpack "$o" "$W/x/old/$key"
    for e in $(elfs "$W/x/new/$key"); do
        rel=${e#"$W/x/new/$key"}
        readelf -d "$e" 2>/dev/null | grep -E 'RPATH|RUNPATH' | grep -E '/home|/build|/tmp|/root|/usr/src' | sed "s|^|$key$rel: |" >> "$OUT/elf-rpath.txt"
        [ -f "$W/x/old/$key$rel" ] && comm -13 <(readelf -d "$W/x/old/$key$rel" | grep NEEDED | awk '{print $NF}' | sort) <(readelf -d "$e" | grep NEEDED | awk '{print $NF}' | sort) | sed "s|^|$key$rel: |" >> "$OUT/elf-needed-new.txt"
        echo "$key$rel $(readelf -n "$e" 2>/dev/null | awk '/Build ID/{print $3}')" >> "$OUT/elf-buildids.txt"
    done
done
chk 2.4a P1 $T "no build-directory RPATH/RUNPATH in $(wc -l < "$OUT/elf-buildids.txt") ELF files" test ! -s "$OUT/elf-rpath.txt" || head "$OUT/elf-rpath.txt"
chk 2.4b P1 $T "no new shared-library dependency against 1.0.0 (new: $(sort -u "$OUT/elf-needed-new.txt" | grep -c .))" test ! -s "$OUT/elf-needed-new.txt" || sort -u "$OUT/elf-needed-new.txt" | head -20
chk 2.4c P1 $T "every ELF file has a build-id" bash -c "! awk 'NF<2' $OUT/elf-buildids.txt | grep -q ."
# 2.5: lint, new error tags only.
lint_tags() { for f in "$1"/*.deb; do lintian --no-tag-display-limit "$f" 2>/dev/null | grep '^E:' | sed -E 's/^E: ([^:]+): ([^ ]+).*/\1 \2/'; done | sort -u; for f in "$1"/*.rpm; do rpmlint "$f" 2>/dev/null | grep ' E: ' | sed -E 's/^([^:]+): E: ([^ ]+).*/\1 \2/' | sed -E 's/\.(x86_64|aarch64|noarch)//'; done | norm | sort -u; }
lint_tags "$W/old" > "$OUT/lint-old.txt"; lint_tags "$W/new" > "$OUT/lint-new.txt"
comm -13 "$OUT/lint-old.txt" "$OUT/lint-new.txt" > "$OUT/lint-new-errors.txt"
chk 2.5 P1 $T "no new lintian/rpmlint error tag (old $(wc -l < "$OUT/lint-old.txt"), new $(wc -l < "$OUT/lint-new.txt"))" test ! -s "$OUT/lint-new-errors.txt" || cat "$OUT/lint-new-errors.txt"
# 2.6 / 2.7: images.
for pg in 15 16 17 18; do
    N=$(img new $pg); O=$(img old $pg)
    for a in amd64 arm64; do
        jn=$(skopeo inspect --override-arch $a --override-os linux "docker://$N"); jo=$(skopeo inspect --override-arch $a --override-os linux "docker://$O")
        sn=$(jq '[.LayersData[].Size]|add' <<<"$jn"); so=$(jq '[.LayersData[].Size]|add' <<<"$jo")
        chk 2.6a P1 "pg$pg/$a" "compressed size within 10% of 1.0.0 ($((so / 1048576)) MB -> $((sn / 1048576)) MB)" bash -c "[ $sn -le $((so * 110 / 100)) ]"
        chk 2.2b P0 "pg$pg/$a" "labels: version $(jq -r '.Labels["org.opencontainers.image.version"]' <<<"$jn"), arch $(jq -r .Architecture <<<"$jn")" bash -c "[ '$(jq -r '.Labels["org.opencontainers.image.version"]' <<<"$jn")' = '$NEW_TAG' ] && [ '$(jq -r .Architecture <<<"$jn")' = $a ]"
        cfg=$(skopeo inspect --config --override-arch $a --override-os linux "docker://$N")
        u=$(jq -r '.config.User' <<<"$cfg"); chk 2.6b P1 "pg$pg/$a" "runs as non-root user ($u)" bash -c "[ -n '$u' ] && [ '$u' != root ] && [ '$u' != 0 ]"
        jq -r '.history[].created_by' <<<"$cfg" > "$OUT/history-pg$pg-$a.txt"; jq -r '.config.Env[]' <<<"$cfg" >> "$OUT/history-pg$pg-$a.txt"
        chk 2.6c P0 "pg$pg/$a" "no credential in image history or env" bash -c "! grep -iE '(password|passwd|secret|token|api[_-]?key)[a-z_]*[=:][^ \$]{6,}' $OUT/history-pg$pg-$a.txt | grep -viE 'DEFAULT_PASSWORD|ALLOW_DEFAULT|example|changeme|<' | grep -q ."
    done
    for which in new old; do I=$(img $which $pg)
        for try in 1 2 3; do docker run --rm -v "$W/trivy:/root/.cache" aquasec/trivy:latest image -q --scanners vuln --severity CRITICAL,HIGH --format json "$I" > "$OUT/trivy-$which-pg$pg.json" 2>"$OUT/trivy-$which-pg$pg.err" && break; sleep 20; done
        jq -r '[.Results[]?.Vulnerabilities[]? | "\(.Severity) \(.VulnerabilityID) \(.PkgName)"] | unique[]' "$OUT/trivy-$which-pg$pg.json" > "$OUT/trivy-$which-pg$pg.txt" 2>/dev/null || echo SCAN_FAILED > "$OUT/trivy-$which-pg$pg.txt"
    done
    comm -13 "$OUT/trivy-old-pg$pg.txt" "$OUT/trivy-new-pg$pg.txt" > "$OUT/trivy-newonly-pg$pg.txt"
    chk 2.7a P0 "pg$pg/amd64" "no Critical/High CVE that 1.0.0 does not have (old $(grep -c . "$OUT/trivy-old-pg$pg.txt"), new $(grep -c . "$OUT/trivy-new-pg$pg.txt"), new-only $(grep -c . "$OUT/trivy-newonly-pg$pg.txt"), critical in new $(grep -c ^CRITICAL "$OUT/trivy-new-pg$pg.txt"))" bash -c "! grep -q . $OUT/trivy-newonly-pg$pg.txt && ! grep -q SCAN_FAILED $OUT/trivy-new-pg$pg.txt" || head -15 "$OUT/trivy-newonly-pg$pg.txt"
done
# Gateway dependency advisories, new lockfile against the 1.0.0 one.
mkdir -p "$W/lock/new" "$W/lock/old"; cp "$ROOT/pg_documentdb_gw/Cargo.lock" "$W/lock/new/"; curl -fsSL https://raw.githubusercontent.com/documentdb/documentdb/v1.0-0/pg_documentdb_gw/Cargo.lock -o "$W/lock/old/Cargo.lock"
for which in new old; do docker run --rm -v "$W/trivy:/root/.cache" -v "$W/lock/$which:/src:ro" aquasec/trivy:latest fs -q --scanners vuln --severity CRITICAL,HIGH --format json /src 2>/dev/null | jq -r '[.Results[]?.Vulnerabilities[]? | "\(.Severity) \(.VulnerabilityID) \(.PkgName)"] | unique[]' > "$OUT/cargo-$which.txt"; done
comm -13 "$OUT/cargo-old.txt" "$OUT/cargo-new.txt" > "$OUT/cargo-newonly.txt"
chk 2.7b P0 gateway "no new Critical/High advisory in Cargo.lock (old $(grep -c . "$OUT/cargo-old.txt"), new $(grep -c . "$OUT/cargo-new.txt"))" test ! -s "$OUT/cargo-newonly.txt" || cat "$OUT/cargo-newonly.txt"
# 0.5 secrets in the tree.
docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:latest dir /repo --no-banner --redact --report-format json --report-path /dev/stdout 2>/dev/null > "$OUT/gitleaks.json" || true
n=$(jq 'length' "$OUT/gitleaks.json" 2>/dev/null || echo "?"); rec 0.5 P1 INFO tree "gitleaks findings in the working tree: $n (gitleaks.json; test fixtures expected)"
jq -r '.[] | "\(.RuleID) \(.File):\(.StartLine)"' "$OUT/gitleaks.json" 2>/dev/null | sort | uniq -c | sort -rn | head -25
! grep -qP '\tP0\tFAIL\t' "$OUT/results.tsv"
