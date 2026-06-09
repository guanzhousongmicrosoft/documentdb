#!/bin/bash
# Build the documentdb-N DEB package — the per-major stand-alone
# package per packaging-design.md §4.4. Ships the systemd template
# units, the documentdb-setup wizard, documentdb-local-reset, the
# private PG service helper, and sample data. Hard-Depends on
# documentdb-postgresql-tools and on documentdb-gateway (exact-match)
# so apt pulls the full Workflow C stack.
#
# Usage:
#   build-standalone-deb.sh --version <ver> --pg-version <N> [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VERSION=""
PG_VERSION=""
OUTPUT_DIR="."

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-standalone-deb.sh --version <ver> --pg-version <N> [--output-dir <dir>]

Build the documentdb-N stand-alone DEB package.

Required:
  --version VER       Package version (e.g., 0.114.0)
  --pg-version N      PostgreSQL major version this stand-alone targets (e.g., 18)

Optional:
  --output-dir DIR    Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --pg-version) PG_VERSION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version is required"
[[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg-version must be a number (e.g., 18)"

ARCH="all"
DEB_PKG_NAME="documentdb-${PG_VERSION}"
FILE_PKG_NAME="documentdb-${PG_VERSION}"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb ..."

# ── Directory structure ─────────────────────────────────────────────
install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/bin"
install -d "${PKG_DIR}/lib/systemd/system"
install -d "${PKG_DIR}/usr/lib/sysusers.d"
install -d "${PKG_DIR}/usr/lib/tmpfiles.d"
install -d "${PKG_DIR}/usr/share/documentdb/scripts"
install -d "${PKG_DIR}/usr/share/documentdb/sample-data"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

# ── CLIs ────────────────────────────────────────────────────────────
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-setup.sh" \
    "${PKG_DIR}/usr/bin/documentdb-setup"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-local-reset.sh" \
    "${PKG_DIR}/usr/bin/documentdb-local-reset"

# ── Systemd template units + sysusers/tmpfiles ──────────────────────
install -m 0644 "${REPO_ROOT}/packaging/appliance/systemd/documentdb-local@.target" \
    "${PKG_DIR}/lib/systemd/system/documentdb-local@.target"
install -m 0644 "${REPO_ROOT}/packaging/appliance/systemd/documentdb-postgresql@.service" \
    "${PKG_DIR}/lib/systemd/system/documentdb-postgresql@.service"
install -m 0644 "${REPO_ROOT}/packaging/appliance/systemd/documentdb-gateway-local@.service" \
    "${PKG_DIR}/lib/systemd/system/documentdb-gateway-local@.service"
install -m 0644 "${REPO_ROOT}/packaging/appliance/sysusers/documentdb-local.conf" \
    "${PKG_DIR}/usr/lib/sysusers.d/documentdb-local.conf"
install -m 0644 "${REPO_ROOT}/packaging/appliance/tmpfiles/documentdb-local.conf" \
    "${PKG_DIR}/usr/lib/tmpfiles.d/documentdb-local.conf"

# ── Helper scripts (consumed by the systemd template units) ─────────
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb_postgresql_service.sh" \
    "${PKG_DIR}/usr/share/documentdb/scripts/documentdb_postgresql_service.sh"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/init_documentdb_data.sh" \
    "${PKG_DIR}/usr/share/documentdb/scripts/init_documentdb_data.sh"

# ── Sample data ─────────────────────────────────────────────────────
for sd in "${REPO_ROOT}/documentdb-local/sample-data/"*; do
    [[ -f "${sd}" ]] || continue
    install -m 0644 "${sd}" "${PKG_DIR}/usr/share/documentdb/sample-data/"
done

# ── Copyright ───────────────────────────────────────────────────────
if [[ -f "${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT" ]]; then
    cp "${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT" "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
else
    echo "MIT License" > "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"
fi

# ── Control file ────────────────────────────────────────────────────
INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

# The extension package's apt-version uses the DASHED form (e.g.
# "0.114-0", where 0.114 is the upstream version and 0 is the Debian
# revision) because debian/changelog uses that form. The standalone +
# gateway + tools DEBs use the DOTTED form (e.g. "0.114.0", a flat
# three-part version with no Debian revision).
#
# dpkg's version comparator treats these as DIFFERENT:
#     dpkg --compare-versions 0.114-0 ge 0.114.0   →   FALSE
# because the upstream parts compare as 0.114 < 0.114.0.
#
# So `Depends: postgresql-N-documentdb (>= ${VERSION})` written with
# the dotted form REJECTS an installed extension at 0.114-0 with the
# infuriating "Some packages could not be installed ... requested an
# impossible situation" apt error.
#
# Fix: convert the dotted form to the dashed form when referencing
# the extension, leaving the dotted form for the standalone-owned
# gateway/tools peers (which all use the dotted form themselves).
# This script accepts either form on --version and normalizes here.
EXT_DEP_VERSION="${VERSION}"
if [[ "${VERSION}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    EXT_DEP_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
fi

# Hard Depends:
#   - postgresql-N + postgresql-N-documentdb: the underlying PG + extension
#     (extension is referenced in its DASHED apt version — see above)
#   - documentdb-gateway (>= ${VERSION}): lockstep with the gateway runtime
#     per design §4.4. Real-user E2E flagged (Gap #11): an exact
#     `(= ${VERSION})` pin breaks point-release upgrades where one DEB
#     ships before the others (apt refuses to install documentdb-N
#     0.114.1 while documentdb-gateway is still 0.114.0). Relaxing to
#     `>= ${VERSION}` preserves the design intent (the four packages
#     are released together) without blocking incremental upgrades.
#   - documentdb-postgresql-tools: documentdb-setup invokes documentdb-tune
#     and documentdb-register-gateway so this is hard, not Suggests
cat > "${PKG_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: documentdb-packaging-maintainers@microsoft.com
Installed-Size: ${INSTALLED_SIZE}
Depends: postgresql-${PG_VERSION}, postgresql-${PG_VERSION}-documentdb (>= ${EXT_DEP_VERSION}), documentdb-gateway (>= ${VERSION}), documentdb-postgresql-tools (>= ${VERSION}), jq
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: DocumentDB stand-alone package for PostgreSQL ${PG_VERSION}
 Makes DocumentDB work on this machine with a single command. The
 stand-alone package owns the per-major systemd templated units
 (documentdb-postgresql@${PG_VERSION}.service +
 documentdb-gateway-local@${PG_VERSION}.service, wired via
 documentdb-local@${PG_VERSION}.target) and ships documentdb-setup, the
 setup wizard that creates a fresh private PostgreSQL instance (greenfield)
 or adopts an existing one (brownfield) with backup-and-rollback safety
 around each invasive change.
Replaces: documentdb-15, documentdb-16, documentdb-17, documentdb-18, documentdb-19
CONTROL

# ── Postinst (sysusers/tmpfiles bootstrap; per design no PG mutation) ─
cat > "${PKG_DIR}/DEBIAN/postinst" <<POSTINST
#!/bin/bash
set -e

case "\$1" in
    configure)
        if command -v systemd-sysusers >/dev/null 2>&1; then
            if ! systemd-sysusers /usr/lib/sysusers.d/documentdb-local.conf 2>/dev/null; then
                if ! getent group documentdb-local >/dev/null 2>&1; then
                    groupadd --system documentdb-local
                fi
                if ! id -u documentdb-local >/dev/null 2>&1; then
                    NOLOGIN=\$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
                    useradd --system --home-dir /var/lib/documentdb-local --shell "\${NOLOGIN}" --gid documentdb-local documentdb-local
                fi
            fi
        else
            if ! getent group documentdb-local >/dev/null 2>&1; then
                groupadd --system documentdb-local
            fi
            if ! id -u documentdb-local >/dev/null 2>&1; then
                NOLOGIN=\$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
                useradd --system --home-dir /var/lib/documentdb-local --shell "\${NOLOGIN}" --gid documentdb-local documentdb-local
            fi
        fi
        if command -v systemd-tmpfiles >/dev/null 2>&1; then
            if ! systemd-tmpfiles --create /usr/lib/tmpfiles.d/documentdb-local.conf 2>/dev/null; then
                install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
                install -d -m 0755 -o documentdb-local -g documentdb-local /run/documentdb-local
                install -d -m 0755 -o documentdb-local -g documentdb-local /var/log/documentdb-local
            fi
        else
            install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
            install -d -m 0755 -o documentdb-local -g documentdb-local /run/documentdb-local
            install -d -m 0755 -o documentdb-local -g documentdb-local /var/log/documentdb-local
        fi
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi

        # Per packaging-design.md §6 "Restart active gateway service on
        # upgrade: documentdb-N install: Yes (gateway side only)": on an
        # upgrade (\$2 is the previously-installed version, empty on a
        # fresh install) restart only the per-major templated gateway-
        # local instance, not the per-major target, so we never restart
        # the underlying PostgreSQL service as a side effect of upgrading
        # the stand-alone wrapper. Maintainer scripts MUST NOT restart
        # PG per §7. If the gateway service isn't currently active we
        # leave the state untouched (matches Citus/pgvector convention).
        if [ -n "\${2:-}" ] && { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            gw_unit="documentdb-gateway-local@${PG_VERSION}.service"
            if systemctl is-active --quiet "\${gw_unit}" 2>/dev/null; then
                systemctl restart "\${gw_unit}" 2>/dev/null || \\
                    echo "WARNING: failed to restart \${gw_unit} after upgrade." >&2
            fi
        fi

        if [ -z "\${2:-}" ]; then
            # On a fresh install, advertise the next steps for this
            # per-major standalone — BUT suppress when the documentdb
            # meta package is also being installed in the same dpkg
            # transaction (it will print its own "Next steps" right
            # after us, and its advice uses the public alias target,
            # which is the recommended user-facing form). Without this
            # suppression, \`apt install documentdb\` prints two near-
            # identical "Next steps" banners.
            meta_in_transaction=false
            if command -v dpkg-query >/dev/null 2>&1; then
                meta_status=\$(dpkg-query -W -f='\${db:Status-Status}\\n' documentdb 2>/dev/null || true)
                case "\${meta_status}" in
                    installed|half-installed|unpacked|half-configured|triggers-awaited|triggers-pending)
                        meta_in_transaction=true
                        ;;
                esac
            fi

            if [ "\${meta_in_transaction}" = "true" ]; then
                echo "DocumentDB stand-alone package for PostgreSQL ${PG_VERSION} installed."
                echo "(The 'documentdb' meta package will print the recommended setup steps.)"
            else
                echo "DocumentDB stand-alone package for PostgreSQL ${PG_VERSION} installed."
                echo ""
                # Real-user E2E flagged (Gap #2): wizard auto-enables the
                # target — second command was redundant. Single step.
                echo "Next: sudo documentdb-setup --admin-user admin --pg-version ${PG_VERSION}"
                echo "(The wizard prompts for the first admin password, runs initdb / CREATE EXTENSION /"
                echo "first-user bootstrap, and enables documentdb-local@${PG_VERSION}.target so the stack survives reboot.)"
            fi
        fi
        ;;
esac

exit 0
POSTINST
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

# ── Prerm: stop and disable the per-major target before file removal ─
#
# Reviewer-flagged (external review iter 18): the RPM spec already has
# a %preun block that stops + disables documentdb-local@N.target on
# remove (but NOT on upgrade). The DEB equivalent was missing —
# `apt remove`/`apt purge` would unlink the unit files and config
# while the per-major target and its child services were still
# running. systemd then has stale active units pointing at deleted
# unit files. Mirror the RPM behavior: stop + disable on the actual
# remove invocation (Debian prerm $1 is "remove" / "upgrade" /
# "deconfigure" / "failed-upgrade"; skip the upgrade-side branches
# so package upgrades do not flap services).
cat > "${PKG_DIR}/DEBIAN/prerm" <<PRERM
#!/bin/bash
set -e

case "\$1" in
    remove)
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl stop "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
            systemctl disable "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
        fi
        ;;
esac

exit 0
PRERM
chmod 0755 "${PKG_DIR}/DEBIAN/prerm"

# ── Postrm: strip the wizard's per-major managed blocks on purge ────
#
# Reviewer-flagged (GPT-5 iter 3): the original implementation walked
# /etc/documentdb/local/*/ across all majors, so purging one
# documentdb-N package would clean state for ALL co-installed majors.
# The design (§4.4 "Co-installable across majors") explicitly supports
# documentdb-18 and documentdb-19 side-by-side. The postrm is now scoped
# to this package's own ${PG_VERSION} by substituting a placeholder
# after the heredoc.
cat > "${PKG_DIR}/DEBIAN/postrm" <<'POSTRM'
#!/bin/bash
set -e

# This is the documentdb-__PG_VERSION__ postrm. Scope all cleanup to PG
# major __PG_VERSION__ so a side-by-side documentdb-N install for a
# different major is not disturbed by purging this one.
PKG_PG_VERSION='__PG_VERSION__'

# Per packaging-design.md §4.3: the stand-alone package is the owner
# of the per-major DocumentDB integration on this host. On purge we
# strip the documentdb-setup managed blocks from the underlying
# PostgreSQL instance's config files (greenfield + brownfield),
# remove the per-major state and gateway env fragment, and clear the
# connection URL file from tmpfs. PostgreSQL data, in-database
# content, and the system PostgreSQL service config are preserved.

documentdb_strip_managed_block() {
    target_file="$1"
    block_start="$2"
    block_end="$3"
    [ -f "${target_file}" ] || return 0
    grep -Fqx "${block_start}" "${target_file}" 2>/dev/null || return 0
    if ! grep -Fqx "${block_end}" "${target_file}" 2>/dev/null; then
        echo "documentdb postrm: refusing to strip managed block in ${target_file}: end marker missing." >&2
        return 0
    fi
    temp_file="$(mktemp "${target_file}.documentdb-cleanup.XXXXXX")" || return 0
    if ! awk -v start="${block_start}" -v end="${block_end}" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "${target_file}" > "${temp_file}"; then
        rm -f "${temp_file}"
        return 0
    fi
    chown --reference="${target_file}" "${temp_file}" 2>/dev/null || true
    chmod --reference="${target_file}" "${temp_file}" 2>/dev/null || true
    mv "${temp_file}" "${target_file}"
}

case "$1" in
    purge)
        for sf in "/etc/documentdb/local/${PKG_PG_VERSION}/setup.conf" \
                  "/etc/documentdb/local/${PKG_PG_VERSION}/brownfield.conf" \
                  "/etc/documentdb/local/${PKG_PG_VERSION}/gateway-setup.state"; do
            [ -r "${sf}" ] || continue
            hba_file="$(grep -E '^HBA_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
            ident_file="$(grep -E '^IDENT_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
            config_file="$(grep -E '^CONFIG_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
            [ -n "${hba_file}" ] && documentdb_strip_managed_block "${hba_file}" \
                "# >>> documentdb-setup managed hba >>>" \
                "# <<< documentdb-setup managed hba <<<"
            [ -n "${ident_file}" ] && documentdb_strip_managed_block "${ident_file}" \
                "# >>> documentdb-setup managed pg_ident >>>" \
                "# <<< documentdb-setup managed pg_ident <<<"
            [ -n "${config_file}" ] && documentdb_strip_managed_block "${config_file}" \
                "# >>> documentdb-setup managed configuration >>>" \
                "# <<< documentdb-setup managed configuration <<<"
            [ -n "${config_file}" ] && documentdb_strip_managed_block "${config_file}" \
                "# >>> documentdb-setup managed listen >>>" \
                "# <<< documentdb-setup managed listen <<<"
            state_dir="$(dirname "${sf}")"
            env_file="${state_dir}/gateway.env"
            if [ -f "${env_file}" ]; then
                documentdb_strip_managed_block "${env_file}" \
                    "# >>> documentdb-register-gateway managed env >>>" \
                    "# <<< documentdb-register-gateway managed env <<<"
                grep -q '[^[:space:]]' "${env_file}" 2>/dev/null || rm -f "${env_file}" 2>/dev/null || true
            fi
            rm -f "${sf}"
            rmdir --ignore-fail-on-non-empty "${state_dir}" 2>/dev/null || true
        done

        # Per-major orphan sweep (scoped to this package's PG major).
        # Catches files left behind by an earlier --restore that removed
        # the state-file pointer. Side-by-side installs for other majors
        # are NOT touched.
        dropin_dir="/etc/systemd/system/documentdb-gateway-local@${PKG_PG_VERSION}.service.d"
        if [ -d "${dropin_dir}" ]; then
            brownfield_file="${dropin_dir}/brownfield.conf"
            if [ -f "${brownfield_file}" ] && \
                    grep -Fq "# Generated by documentdb-setup --target-postgres-instance" \
                    "${brownfield_file}" 2>/dev/null; then
                rm -f "${brownfield_file}"
            fi
            rmdir --ignore-fail-on-non-empty "${dropin_dir}" 2>/dev/null || true
        fi
        per_major_env="/etc/documentdb/local/${PKG_PG_VERSION}/gateway.env"
        if [ -f "${per_major_env}" ]; then
            documentdb_strip_managed_block "${per_major_env}" \
                "# >>> documentdb-register-gateway managed env >>>" \
                "# <<< documentdb-register-gateway managed env <<<"
            grep -q '[^[:space:]]' "${per_major_env}" 2>/dev/null || rm -f "${per_major_env}" 2>/dev/null || true
        fi
        rmdir --ignore-fail-on-non-empty "/etc/documentdb/local/${PKG_PG_VERSION}" 2>/dev/null || true
        # Reviewer-flagged (GPT-5.5 iter 11): pg-url moved from tmpfs /run
        # to persistent /var/lib so it survives reboot. Clean BOTH paths
        # so upgrades from pre-iter11 installs don't leak the legacy file.
        rm -f "/run/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url" 2>/dev/null || true
        rm -f "/var/lib/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url" 2>/dev/null || true

        # Reviewer-flagged (GPT-5 iter 4): the legacy host-level state file
        # /etc/documentdb/documentdb-postgresql.env (written by
        # documentdb-setup's read_persisted_managed_data_dir() flow) was
        # never cleaned by purge. It's shared across all majors, so we
        # only remove it when no other documentdb-N is still installed
        # (detected by checking whether any other per-major state file
        # remains under /etc/documentdb/local/*/).
        if [ -f "/etc/documentdb/documentdb-postgresql.env" ]; then
            other_majors_remain=false
            for other_state in /etc/documentdb/local/*/setup.conf \
                               /etc/documentdb/local/*/brownfield.conf; do
                if [ -r "${other_state}" ]; then
                    other_majors_remain=true
                    break
                fi
            done
            if [ "${other_majors_remain}" = "false" ]; then
                rm -f /etc/documentdb/documentdb-postgresql.env
            fi
        fi

        # Only collapse the top-level /etc/documentdb/local and /etc/documentdb
        # dirs if THIS package was the last per-major install on the host —
        # rmdir --ignore-fail-on-non-empty does that safely (succeeds only
        # when empty), so side-by-side majors keep their state intact.
        rmdir --ignore-fail-on-non-empty /etc/documentdb/local 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty /etc/documentdb 2>/dev/null || true
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
    remove|disappear|upgrade|failed-upgrade|abort-install|abort-upgrade)
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
esac

exit 0
POSTRM
# Now substitute the placeholder with the package's PG major. Use a
# delimiter that can't appear in version strings.
sed -i "s|__PG_VERSION__|${PG_VERSION}|g" "${PKG_DIR}/DEBIAN/postrm"
chmod 0755 "${PKG_DIR}/DEBIAN/postrm"

# ── Build ───────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"

echo "Built: ${DEB_FILE}"
echo "Contents:"
dpkg-deb -c "${DEB_FILE}" | awk '{print "  " $NF}' | grep -v '/$'
