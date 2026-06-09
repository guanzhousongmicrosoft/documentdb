%define debug_package %{nil}

Name:           documentdb-gateway
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB Gateway - wire protocol daemon

License:        MIT
URL:            https://github.com/documentdb/documentdb

# Reviewer-flagged (Sonnet iter 7): jq is NOT a gateway runtime dep —
# only documentdb-gateway-admin uses it, and that ships in
# documentdb-postgresql-tools. Per packaging-design.md §4.3 the gateway
# package has "no product-specific runtime dependency beyond the OS/
# runtime libraries that the binary links to". openssl stays because
# the gateway's TLS auto-gen flow shells out to it when
# DOCUMENTDB_TLS_AUTO_GENERATE=true.
Requires:       openssl
# Reviewer-flagged (Sonnet iter 9): the gateway binary is PG-major-agnostic,
# but the previous Suggests: postgresql18-documentdb misled operators on
# PG 15/16/17 hosts (dnf would suggest the wrong package). The %post
# message below points the operator at the right per-major extension
# explicitly. Suggest only the PG-agnostic tools package so dnf's
# behavior is correct across all majors. Matches the iter-8 fix that
# removed the same pattern from documentdb-postgresql-tools.
Suggests:       documentdb-postgresql-tools

%description
The DocumentDB Gateway provides wire-protocol compatibility for DocumentDB,
enabling connections from compatible clients and drivers. This is a lean
runtime package; install documentdb (or documentdb-N for a specific
PostgreSQL major) for the full stand-alone experience.

%pre
getent group documentdb-gateway >/dev/null || groupadd -r documentdb-gateway
NOLOGIN=$(command -v nologin 2>/dev/null || echo /sbin/nologin)
getent passwd documentdb-gateway >/dev/null || useradd -r -g documentdb-gateway -d /nonexistent -s "$NOLOGIN" documentdb-gateway
install -d -m 0750 -o documentdb-gateway -g documentdb-gateway /var/lib/documentdb-gateway
install -d -m 0755 -o documentdb-gateway -g documentdb-gateway /run/documentdb-gateway

%install
install -Dpm 0644 %{_sourcedir}/LICENSE_Apache-2.0 %{buildroot}%{_licensedir}/%{name}/LICENSE_Apache-2.0
install -Dpm 0644 %{_sourcedir}/LICENSE_MIT %{buildroot}%{_licensedir}/%{name}/LICENSE_MIT
# Real-user E2E flagged (Gap #5 from cross-platform coverage round):
# DEB ships the daemon at /usr/lib/documentdb-gateway/documentdb-gateway-daemon
# with a thin wrapper at /usr/bin/documentdb-gateway that auto-loads
# the per-major or global gateway.env and runuser-downgrades to the
# documentdb-gateway OS user when invoked from a root shell outside
# systemd. RPM previously installed the raw ELF directly at /usr/bin/
# meaning `documentdb-gateway --check` from a root shell on RHEL had
# the JSON-only behavior (no env file, no peer-auth user downgrade).
# Mirror the DEB layout so manual CLI parity holds across both
# packaging families.
install -Dpm 0755 %{_sourcedir}/documentdb_gateway %{buildroot}/usr/lib/documentdb-gateway/documentdb-gateway-daemon
install -d %{buildroot}/usr/bin
cat > %{buildroot}/usr/bin/documentdb-gateway <<'WRAPPER'
#!/bin/bash
# documentdb-gateway — thin wrapper that sources per-major or global
# gateway.env before exec'ing the daemon. Mirrors the DEB build.

set -e
DAEMON="/usr/lib/documentdb-gateway/documentdb-gateway-daemon"
GW_OS_USER="documentdb-gateway"

_source_env_if_present() {
    local f="$1"
    if [[ -r "${f}" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "${f}"
        set +a
        return 0
    fi
    return 1
}

_load_env() {
    # Caller (e.g. documentdb-setup) may already have set up the env
    # for a specific major; trust them and don't pick a different
    # per-major env file via the alphabetic glob.
    if [[ -n "${DOCUMENTDB_PG_URL_FILE:-}" || -n "${DOCUMENTDB_PG_URL:-}" ]]; then
        return 0
    fi
    local env_file
    for env_file in /etc/documentdb/local/*/gateway.env; do
        [[ -f "${env_file}" ]] || continue
        _source_env_if_present "${env_file}" && return 0
    done
    _source_env_if_present /etc/documentdb/gateway/gateway.env && return 0
    return 1
}

_under_systemd() {
    [[ "${INVOCATION_ID:-}" != "" ]]
}

_maybe_runuser_down() {
    if [[ "$(id -u)" -eq 0 ]] \
            && id -u "${GW_OS_USER}" >/dev/null 2>&1 \
            && ! _under_systemd; then
        exec runuser -u "${GW_OS_USER}" \
            --whitelist-environment=DOCUMENTDB_PG_URL_FILE,DOCUMENTDB_PG_URL,DOCUMENTDB_LISTEN_ADDR,DOCUMENTDB_TLS_CERT_FILE,DOCUMENTDB_TLS_KEY_FILE,DOCUMENTDB_TLS_AUTO_GENERATE,DOCUMENTDB_TLS_STATE_DIR,DOCUMENTDB_LOG_LEVEL \
            -- "${DAEMON}" "$@"
    fi
    exec "${DAEMON}" "$@"
}

case "${1:-}" in
    run)
        _load_env >/dev/null 2>&1 || true
        shift
        _maybe_runuser_down run "$@"
        ;;
    --check|--version)
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down "$@"
        ;;
    "")
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down
        ;;
    *)
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down "$@"
        ;;
esac
WRAPPER
chmod 0755 %{buildroot}/usr/bin/documentdb-gateway
install -Dpm 0644 %{_sourcedir}/documentdb-gateway.service %{buildroot}/lib/systemd/system/documentdb-gateway.service
install -Dpm 0644 %{_sourcedir}/documentdb-gateway-sysusers.conf %{buildroot}/usr/lib/sysusers.d/documentdb-gateway.conf
install -Dpm 0644 %{_sourcedir}/documentdb-gateway-tmpfiles.conf %{buildroot}/usr/lib/tmpfiles.d/documentdb-gateway.conf
# Per packaging-design.md §4.3, ship the env sample under /usr/share/doc/...
# (PostgreSQL convention); EnvironmentFile=- in the unit makes the live
# /etc/documentdb/gateway/gateway.env optional. SetupConfiguration.json
# is still shipped at the historical /etc/documentdb/gateway/ path for
# back-compat with pre-Phase-3 deployments.
install -Dpm 0644 %{_sourcedir}/gateway.env %{buildroot}/usr/share/doc/%{name}/examples/gateway.env.sample
# Reviewer-flagged (external review iter 18): strip dev-tree
# PostgresPort/GatewayListenPort/PostgresDataUserPassword fields so the
# packaged JSON does not contradict the per-major port promise or the
# Track 1 passwordless policy. Use jq when available (RHEL 9 / Fedora
# ship it by default), fall back to sed if absent.
install -d %{buildroot}/etc/documentdb/gateway
if command -v jq >/dev/null 2>&1; then
    jq 'del(.PostgresPort, .GatewayListenPort, .PostgresDataUserPassword, .PostgresHostName, .PostgresSystemUser, .PostgresDataUser)' \
        %{_sourcedir}/SetupConfiguration.json > %{buildroot}/etc/documentdb/gateway/SetupConfiguration.json
else
    sed -E '/"(PostgresPort|GatewayListenPort|PostgresDataUserPassword|PostgresHostName|PostgresSystemUser|PostgresDataUser)"[[:space:]]*:/d' \
        %{_sourcedir}/SetupConfiguration.json > %{buildroot}/etc/documentdb/gateway/SetupConfiguration.json
fi
chmod 0644 %{buildroot}/etc/documentdb/gateway/SetupConfiguration.json

%post
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi
echo "DocumentDB Gateway installed."
echo ""
echo "Configuration is taken from the environment first; the systemd unit"
echo "reads /etc/documentdb/gateway/gateway.env if it exists. To customize:"
echo "  sudo install -d -m 0755 /etc/documentdb/gateway"
echo "  sudo install -m 0644 /usr/share/doc/documentdb-gateway/examples/gateway.env.sample \\"
echo "                       /etc/documentdb/gateway/gateway.env"
echo "  sudoedit /etc/documentdb/gateway/gateway.env"
echo ""
echo "Next: choose one workflow."
echo "  * Workflow C (recommended): sudo dnf install documentdb && sudo documentdb-setup --admin-user admin"
echo "  * Workflow B (gateway on top of an existing PG, replace <N> with the PG major such as 18):"
echo "      sudo dnf install postgresql<N>-documentdb documentdb-postgresql-tools && \\"
echo "        sudo documentdb-tune --pg-version <N> --pgdata /var/lib/pgsql/<N>/data --yes && \\"
echo "        sudo systemctl restart postgresql-<N> && \\"
echo "        sudo -u postgres psql -c 'CREATE EXTENSION documentdb CASCADE;' && \\"
echo "        sudo documentdb-register-gateway --target-postgres-instance <N>/main --admin-user admin --yes && \\"
echo "        sudo systemctl reload postgresql-<N> && \\"
echo "        sudo systemctl enable --now documentdb-gateway"
echo "  See /usr/share/doc/documentdb-gateway/ and the packaging-design.md \"User workflows\" section."

%preun
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    if [ "$1" -eq 0 ]; then
        systemctl stop documentdb-gateway 2>/dev/null || true
        systemctl disable documentdb-gateway 2>/dev/null || true
    fi
fi

%postun
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi
# Full uninstall ($1 == 0): clean up gateway-owned runtime state only.
# Per packaging-design.md §4.3, the gateway runtime package is runtime-
# only: it MUST NOT mutate PostgreSQL-side state (pg_hba.conf,
# pg_ident.conf, postgresql.conf, gateway PG role). That cleanup belongs
# to documentdb-postgresql-tools (operator-invoked via
# documentdb-register-gateway --restore) and to documentdb-N's %postun
# (Issue 8 from the second-pass review). We only sweep the gateway's
# own /run/documentdb-gateway tmpfs state and the env file at
# /etc/documentdb/gateway/gateway.env.
if [ "$1" -eq 0 ]; then
    rm -rf /run/documentdb-gateway 2>/dev/null || true
    # /etc/documentdb/gateway/gateway.env may be an admin-authored
    # file that pre-dates the package install (the package itself only
    # ships the .sample under /usr/share/doc/...). Leave it alone so an
    # operator's customized env survives reinstall.
fi

%posttrans
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
    # Restart Workflow B's plain gateway service if active.
    if systemctl is-active --quiet documentdb-gateway.service; then
        if ! systemctl restart documentdb-gateway.service; then
            echo "WARNING: Failed to restart documentdb-gateway.service after package transaction." >&2
        fi
    fi
    # Restart all active stand-alone per-major gateway-local@N.service
    # instances. They use the same /usr/bin/documentdb-gateway binary as
    # the plain unit, so an upgrade of this RPM that doesn't restart them
    # leaves them running the old binary. The DEB postinst does the same
    # (see oss/documentdb-local/maintainer-scripts/gateway/postinst). The
    # lockstep release model in §4.4 makes solo gateway upgrades rare but
    # the design's §6 "Restart active gateway service on upgrade" still
    # requires the gateway side to be refreshed.
    for unit in $(systemctl list-units 'documentdb-gateway-local@*.service' \
            --state=active --plain --no-legend 2>/dev/null \
            | awk '{print $1}'); do
        if ! systemctl restart "${unit}"; then
            echo "WARNING: Failed to restart ${unit} after package transaction." >&2
        fi
    done
fi

%files
%defattr(-,root,root,-)
%license %{_licensedir}/%{name}/LICENSE_Apache-2.0
%license %{_licensedir}/%{name}/LICENSE_MIT
/usr/bin/documentdb-gateway
/usr/lib/documentdb-gateway/documentdb-gateway-daemon
/lib/systemd/system/documentdb-gateway.service
/usr/lib/sysusers.d/documentdb-gateway.conf
/usr/lib/tmpfiles.d/documentdb-gateway.conf
%doc /usr/share/doc/%{name}/examples/gateway.env.sample
%config(noreplace) /etc/documentdb/gateway/SetupConfiguration.json

%changelog
