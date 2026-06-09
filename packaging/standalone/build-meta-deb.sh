#!/bin/bash
# Build the documentdb meta DEB package per packaging-design.md §4.4.
# The meta package depends on the paved-road per-major package
# (documentdb-18 by default) and owns the public systemd alias
# documentdb-local.target → documentdb-local@${default_pg_major}.target.
#
# Usage:
#   build-meta-deb.sh --version <ver> [--default-pg-major 18] [--output-dir <dir>]

set -euo pipefail

VERSION=""
DEFAULT_PG_MAJOR="18"
OUTPUT_DIR="."

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-meta-deb.sh --version <ver> [--default-pg-major 18] [--output-dir <dir>]

Build the documentdb meta DEB package. The meta package pins to one
PostgreSQL major (paved-road default = 18) and installs the
documentdb-local.target alias on its postinst.

Required:
  --version VER          Package version (e.g., 0.114.0)

Optional:
  --default-pg-major N   PostgreSQL major to pin (default: 18)
  --output-dir DIR       Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --default-pg-major) DEFAULT_PG_MAJOR="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version is required"

ARCH="all"
DEB_PKG_NAME="documentdb"
FILE_PKG_NAME="documentdb"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb (pinned to documentdb-${DEFAULT_PG_MAJOR}) ..."

install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

cat > "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright" <<'EOF'
MIT License
EOF

INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

cat > "${PKG_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: documentdb-packaging-maintainers@microsoft.com
Installed-Size: ${INSTALLED_SIZE}
Depends: documentdb-${DEFAULT_PG_MAJOR} (>= ${VERSION})
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: DocumentDB stand-alone meta package
 The recommended install target for new users:
 .
   sudo apt install documentdb
 .
 Pulls the paved-road combination (PostgreSQL ${DEFAULT_PG_MAJOR} +
 documentdb-${DEFAULT_PG_MAJOR} + documentdb-gateway +
 documentdb-postgresql-tools) and installs the public systemd alias
 documentdb-local.target -> documentdb-local@${DEFAULT_PG_MAJOR}.target.
 .
 To fully uninstall, run:
 .
   sudo apt purge documentdb documentdb-${DEFAULT_PG_MAJOR} documentdb-gateway documentdb-postgresql-tools
 .
 'apt purge documentdb' alone only removes this meta package; the
 per-major stand-alone package, the gateway runtime, and the
 administrator tools remain installed.
CONTROL

# Postinst installs the public alias so `systemctl enable --now
# documentdb-local.target` Just Works (per design §1 "What done looks like").
#
# Reviewer-flagged (GPT-5 iter 7): a plain `Requires=` wrapper unit does
# NOT propagate stop/restart from the wrapper to the per-major target.
# `systemctl stop documentdb-local.target` would leave the appliance
# running. The fix is to install a drop-in on the per-major target
# itself that declares `PartOf=documentdb-local.target` — PartOf
# propagates stop/restart from a parent target to its child units.
# Combined with the wrapper's `Requires=` for start-time pull-in, this
# gives the alias the full start/stop/restart/status semantics the
# design promises.
cat > "${PKG_DIR}/DEBIAN/postinst" <<POSTINST
#!/bin/bash
set -e

DEFAULT_PG_MAJOR="${DEFAULT_PG_MAJOR}"

case "\$1" in
    configure)
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            install -d -m 0755 /etc/systemd/system

            # Wrapper unit: start of this pulls in the per-major target
            # via Requires=. PartOf= cannot live here because PartOf
            # propagates FROM the named unit TO this one (wrong
            # direction); the inverse direction lives in the per-major
            # drop-in below.
            cat > /etc/systemd/system/documentdb-local.target <<DROPIN
[Unit]
Description=DocumentDB Local Appliance (alias to documentdb-local@\${DEFAULT_PG_MAJOR}.target)
Requires=documentdb-local@\${DEFAULT_PG_MAJOR}.target
After=documentdb-local@\${DEFAULT_PG_MAJOR}.target

[Install]
WantedBy=multi-user.target
DROPIN

            # Stop-propagation drop-in on the per-major target. Without
            # this, `systemctl stop documentdb-local.target` leaves
            # documentdb-local@\${DEFAULT_PG_MAJOR}.target running. With
            # PartOf= on the per-major target, stopping the wrapper also
            # stops the appliance (the design's documented day-2
            # surface). The drop-in lives under /etc/systemd/system so
            # package upgrades don't overwrite it. See packaging-design.md §8.
            install -d -m 0755 /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d
            cat > /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d/wrapper-partof.conf <<DROPIN2
[Unit]
# Propagate stop/restart from the public documentdb-local.target alias
# down to this per-major instance. Installed by the documentdb meta
# package's postinst. Removed on purge.
PartOf=documentdb-local.target
DROPIN2

            systemctl daemon-reload 2>/dev/null || true
        fi
        echo "DocumentDB meta package installed (paved-road: PostgreSQL \${DEFAULT_PG_MAJOR})."
        echo ""
        # Real-user E2E flagged (Gap #2): the wizard now enables the
        # documentdb-local target at boot itself, so the "systemctl enable
        # --now documentdb-local.target" follow-up is redundant. Single
        # step ⇒ less confusion.
        echo "Next: sudo documentdb-setup --admin-user admin"
        echo "(The wizard prompts for the first admin password, runs initdb / CREATE EXTENSION /"
        echo "first-user bootstrap, and enables documentdb-local.target so the stack survives reboot."
        echo "Pass --no-enable to defer the start-at-boot step.)"
        echo ""
        echo "When the wizard finishes, connect via mongosh:"
        echo "  mongosh 'mongodb://admin@127.0.0.1:10260/mydb?tls=true&tlsAllowInvalidCertificates=true'"
        ;;
esac

exit 0
POSTINST
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

cat > "${PKG_DIR}/DEBIAN/postrm" <<POSTRM
#!/bin/bash
set -e

DEFAULT_PG_MAJOR="${DEFAULT_PG_MAJOR}"

case "\$1" in
    purge|remove)
        rm -f /etc/systemd/system/documentdb-local.target 2>/dev/null || true
        # Remove the stop-propagation drop-in too so the per-major
        # target's behavior reverts when the meta package is uninstalled.
        rm -f /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d/wrapper-partof.conf 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d 2>/dev/null || true
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi

        # Remind the operator that purging the meta only removes the
        # alias; the actual stand-alone stack, gateway, and tools are
        # separate packages and are still installed (or held in
        # "config-files" state) until purged explicitly. Without this,
        # an operator who runs \`apt purge documentdb\` assuming a full
        # wipe is surprised to find the gateway service still running.
        remaining_pkgs=""
        for pkg in "documentdb-\${DEFAULT_PG_MAJOR}" \\
                   "documentdb-gateway" \\
                   "documentdb-postgresql-tools"; do
            status=\$(dpkg-query -W -f='\${db:Status-Status}\\n' "\$pkg" 2>/dev/null || true)
            case "\$status" in
                installed|half-installed|unpacked|half-configured|triggers-awaited|triggers-pending|config-files)
                    remaining_pkgs="\${remaining_pkgs} \$pkg"
                    ;;
            esac
        done
        if [ -n "\${remaining_pkgs}" ]; then
            echo ""
            echo "Note: removing the 'documentdb' meta package only removed the"
            echo "public 'documentdb-local.target' alias. The following packages"
            echo "are still installed on this host:"
            for pkg in \${remaining_pkgs}; do
                echo "  - \${pkg}"
            done
            echo ""
            echo "To fully uninstall DocumentDB, run:"
            echo "  sudo apt purge\${remaining_pkgs}"
            echo ""
            echo "PostgreSQL data directories under /var/lib/documentdb-local/"
            echo "are preserved across purge; use documentdb-local-reset to wipe"
            echo "them when intended."
        fi
        ;;
esac

exit 0
POSTRM
chmod 0755 "${PKG_DIR}/DEBIAN/postrm"

mkdir -p "${OUTPUT_DIR}"
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"

echo "Built: ${DEB_FILE}"
echo "Depends: documentdb-${DEFAULT_PG_MAJOR} (>= ${VERSION})"
