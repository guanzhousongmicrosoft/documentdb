%global pg_version POSTGRES_VERSION
%define debug_package %{nil}

Name:           documentdb-%{pg_version}
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB stand-alone package for PostgreSQL %{pg_version}
BuildArch:      noarch

License:        MIT
URL:            https://github.com/documentdb/documentdb

Requires:       (postgresql%{pg_version}-server or percona-postgresql%{pg_version}-server)
Requires:       postgresql%{pg_version}-documentdb >= %{version}
# Track 1 lockstep release: the gateway runtime is intentionally upgraded
# in lockstep with the stand-alone wrapper, but the gateway RPM carries
# the host dist tag (1.el9) while the stand-alone .spec is noarch (1).
# Pinning `documentdb-gateway = %{version}-%{release}` therefore breaks
# cross-architecture/distribution installs even though the packages are
# in fact compatible. Pin `>= %{version}` so the release qualifier
# differing across arch/distro builds does not block installs.
Requires:       documentdb-gateway >= %{version}
Requires:       documentdb-postgresql-tools >= %{version}
Requires:       jq

%description
DocumentDB stand-alone package for PostgreSQL %{pg_version}. Makes
DocumentDB work on this machine with a single command. Manages a private
PostgreSQL instance and gateway via systemd template units.

%pre
getent group documentdb-local >/dev/null || groupadd -r documentdb-local
NOLOGIN=$(command -v nologin 2>/dev/null || echo /sbin/nologin)
getent passwd documentdb-local >/dev/null || useradd -r -g documentdb-local -d /var/lib/documentdb-local -s "$NOLOGIN" documentdb-local
install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
install -d -m 0755 -o documentdb-local -g documentdb-local /run/documentdb-local
install -d -m 0755 -o documentdb-local -g documentdb-local /var/log/documentdb-local

%install
install -Dpm 0755 %{_sourcedir}/documentdb-setup.sh %{buildroot}/usr/bin/documentdb-setup
install -Dpm 0755 %{_sourcedir}/documentdb-local-reset.sh %{buildroot}/usr/bin/documentdb-local-reset
install -Dpm 0644 %{_sourcedir}/documentdb-local@.target %{buildroot}/lib/systemd/system/documentdb-local@.target
install -Dpm 0644 %{_sourcedir}/documentdb-postgresql@.service %{buildroot}/lib/systemd/system/documentdb-postgresql@.service
install -Dpm 0644 %{_sourcedir}/documentdb-gateway-local@.service %{buildroot}/lib/systemd/system/documentdb-gateway-local@.service
install -Dpm 0644 %{_sourcedir}/documentdb-local-sysusers.conf %{buildroot}/usr/lib/sysusers.d/documentdb-local.conf
install -Dpm 0644 %{_sourcedir}/documentdb-local-tmpfiles.conf %{buildroot}/usr/lib/tmpfiles.d/documentdb-local.conf
install -Dpm 0755 %{_sourcedir}/documentdb_postgresql_service.sh %{buildroot}/usr/share/documentdb/scripts/documentdb_postgresql_service.sh
install -Dpm 0755 %{_sourcedir}/init_documentdb_data.sh %{buildroot}/usr/share/documentdb/scripts/init_documentdb_data.sh
install -Dpm 0644 %{_sourcedir}/sample-data/01-users.js %{buildroot}/usr/share/documentdb/sample-data/01-users.js
install -Dpm 0644 %{_sourcedir}/sample-data/02-products.js %{buildroot}/usr/share/documentdb/sample-data/02-products.js
install -Dpm 0644 %{_sourcedir}/sample-data/03-orders.js %{buildroot}/usr/share/documentdb/sample-data/03-orders.js
install -Dpm 0644 %{_sourcedir}/sample-data/04-analytics.js %{buildroot}/usr/share/documentdb/sample-data/04-analytics.js
install -Dpm 0644 %{_sourcedir}/sample-data/README.md %{buildroot}/usr/share/documentdb/sample-data/README.md

%post
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi
echo "DocumentDB stand-alone package for PostgreSQL %{pg_version} installed."
echo ""
echo "Next step:"
echo "  sudo documentdb-setup --admin-user admin --pg-version %{pg_version}"
echo "  sudo systemctl enable --now documentdb-local@%{pg_version}.target"

%preun
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    if [ "$1" -eq 0 ]; then
        systemctl stop "documentdb-local@%{pg_version}.target" || true
        systemctl disable "documentdb-local@%{pg_version}.target" || true
    fi
fi

%postun
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi

# Full uninstall ($1 == 0 in RPM): strip the documentdb-setup managed
# blocks from the underlying PG instance's config files (Issue 8 from
# the second-pass review). The gateway runtime package used to do this
# work which violated its runtime-only boundary; ownership now lives
# here with the stand-alone package that orchestrated the writes in
# the first place.
if [ "$1" -eq 0 ]; then
    documentdb_strip_managed_block() {
        target_file="$1"
        block_start="$2"
        block_end="$3"
        [ -f "${target_file}" ] || return 0
        grep -Fqx "${block_start}" "${target_file}" 2>/dev/null || return 0
        if ! grep -Fqx "${block_end}" "${target_file}" 2>/dev/null; then
            echo "documentdb-%{pg_version} %%postun: refusing to strip managed block in ${target_file}: end marker missing." >&2
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

    # Strip the standalone-side managed blocks the wizard / delegated
    # tools wrote. State file names: setup.conf (greenfield),
    # brownfield.conf (brownfield).
    for sf in /etc/documentdb/local/%{pg_version}/setup.conf \
              /etc/documentdb/local/%{pg_version}/brownfield.conf \
              /etc/documentdb/local/%{pg_version}/gateway-setup.state; do
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
        # Strip per-major gateway.env fragment + remove the connection
        # URL file from tmpfs.
        state_dir="$(dirname "${sf}")"
        env_file="${state_dir}/gateway.env"
        if [ -f "${env_file}" ]; then
            documentdb_strip_managed_block "${env_file}" \
                "# >>> documentdb-register-gateway managed env >>>" \
                "# <<< documentdb-register-gateway managed env <<<"
            grep -q '[^[:space:]]' "${env_file}" 2>/dev/null || rm -f "${env_file}" 2>/dev/null || true
        fi
        rm -f "${sf}" 2>/dev/null || true
        # Reviewer-flagged (GPT-5.5 iter 11): pg-url moved from tmpfs /run
        # to persistent /var/lib so it survives reboot. Clean BOTH paths
        # for upgrade-safe cleanup from pre-iter11 installs.
        rm -f "/run/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true
        rm -f "/var/lib/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty "${state_dir}" 2>/dev/null || true
    done

    # Unconditional per-major sweeps for orphaned artifacts. The per-state-
    # file loop above short-circuits when the state file is already gone
    # (e.g. an earlier --restore removed it but did not clean these), so we
    # repeat the cleanup unconditionally here. The %{pg_version} macro
    # scopes the sweep to this package's major, matching the package's
    # ownership boundary. Reviewer-flagged (GPT-5 second pass).
    #
    # Brownfield drop-in cleanup: the wizard writes a per-instance systemd
    # drop-in at
    # /etc/systemd/system/documentdb-gateway-local@%{pg_version}.service.d/brownfield.conf
    # when adopting an existing PG (see packaging-design.md §4.4).
    dropin_dir="/etc/systemd/system/documentdb-gateway-local@%{pg_version}.service.d"
    rm -f "${dropin_dir}/brownfield.conf" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "${dropin_dir}" 2>/dev/null || true

    # Per-major gateway env fragment (loaded by documentdb-gateway-local@N).
    per_major_env="/etc/documentdb/local/%{pg_version}/gateway.env"
    if [ -f "${per_major_env}" ]; then
        documentdb_strip_managed_block "${per_major_env}" \
            "# >>> documentdb-register-gateway managed env >>>" \
            "# <<< documentdb-register-gateway managed env <<<"
        grep -q '[^[:space:]]' "${per_major_env}" 2>/dev/null || rm -f "${per_major_env}" 2>/dev/null || true
    fi
    rmdir --ignore-fail-on-non-empty "/etc/documentdb/local/%{pg_version}" 2>/dev/null || true

    # Per-major connection-URL files. Clean BOTH the legacy tmpfs path
    # (pre-iter11) and the current persistent path so upgrades don't leak.
    rm -f "/run/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true
    rm -f "/var/lib/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true

    # Reviewer-flagged (GPT-5 iter 4): the legacy host-level state file
    # /etc/documentdb/documentdb-postgresql.env (written by
    # documentdb-setup's read_persisted_managed_data_dir() flow) was
    # never cleaned on uninstall. It's shared across all majors, so we
    # only remove it when no other documentdb-N package's per-major
    # state remains. Matches the DEB postrm logic.
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

    rmdir --ignore-fail-on-non-empty /etc/documentdb/local 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty /etc/documentdb 2>/dev/null || true
fi

%posttrans
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
    # Per packaging-design.md §6 "Restart active gateway service on
    # upgrade: documentdb-N install: Yes (gateway side only)": restart
    # only the per-major templated gateway-local instance, NOT the
    # per-major target — restarting the target would also bounce the
    # underlying PostgreSQL service (greenfield via PartOf=) which §7
    # prohibits ("Maintainer scripts restart PostgreSQL: Never"). If
    # the gateway unit isn't active we leave state untouched, matching
    # Citus/pgvector convention.
    if systemctl is-active --quiet "documentdb-gateway-local@%{pg_version}.service"; then
        if ! systemctl restart "documentdb-gateway-local@%{pg_version}.service"; then
            echo "WARNING: failed to restart documentdb-gateway-local@%{pg_version}.service after package transaction." >&2
        fi
    fi
fi

%files
%defattr(-,root,root,-)
/usr/bin/documentdb-setup
/usr/bin/documentdb-local-reset
/lib/systemd/system/documentdb-local@.target
/lib/systemd/system/documentdb-postgresql@.service
/lib/systemd/system/documentdb-gateway-local@.service
/usr/lib/sysusers.d/documentdb-local.conf
/usr/lib/tmpfiles.d/documentdb-local.conf
/usr/share/documentdb/scripts/documentdb_postgresql_service.sh
/usr/share/documentdb/scripts/init_documentdb_data.sh
/usr/share/documentdb/sample-data/01-users.js
/usr/share/documentdb/sample-data/02-products.js
/usr/share/documentdb/sample-data/03-orders.js
/usr/share/documentdb/sample-data/04-analytics.js
/usr/share/documentdb/sample-data/README.md

%changelog
