#!/bin/bash
set -e

test -n "$OS" || (echo "OS not set" && false)

# Change to the build directory
cd /build

# Update packaging changelogs from CHANGELOG.md (fail build if this fails)
if [[ -n "${DOCUMENTDB_VERSION:-}" ]]; then
   echo "DOCUMENTDB_VERSION provided via environment: ${DOCUMENTDB_VERSION}"
else
   DOCUMENTDB_VERSION=$(grep -E "^default_version" pg_documentdb_core/documentdb_core.control | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/" || true)
fi
if [[ -n "$DOCUMENTDB_VERSION" ]]; then
   echo "Running changelog update for version: $DOCUMENTDB_VERSION"
   /bin/bash /build/packaging/update_spec_changelog.sh "$DOCUMENTDB_VERSION"
else
   echo "WARNING: Could not determine documentdb version; skipping changelog update"
   exit 1
fi

# Keep the internal directory out of the Debian package
sed -i '/internal/d' Makefile

# Resolve versions for Static-Built-Using from the same source the build used.
# Subshell because setup_versions.sh runs `set -u`.
bundled_versions=$(bash -c 'set -e; . /build/scripts/setup_versions.sh
    printf "%s %s %s\n" "$(GetLibbsonVersion)" "$(GetPcre2Version)" "$(GetIntelDecimalMathLibVersion)"') \
   || { echo "ERROR: could not read versions from scripts/setup_versions.sh" >&2; exit 1; }
read -r LIBBSON_VER PCRE2_VER IDML_VER <<<"$bundled_versions"

# Convert the Launchpad ref to the upstream library version.
IDML_VER=${IDML_VER#applied/}
IDML_VER=${IDML_VER%%-*}

for v in "$LIBBSON_VER" "$PCRE2_VER" "$IDML_VER"; do
   [[ "$v" =~ ^[A-Za-z0-9.+~]+$ ]] \
      || { echo "ERROR: '$v' is not usable as a Debian version in Static-Built-Using" >&2; exit 1; }
done

sed -i -e "/^XB-Static-Built-Using:/{
         s/LIBBSON_VERSION/${LIBBSON_VER}/
         s/PCRE2_VERSION/${PCRE2_VER}/
         s/INTEL_DECIMAL_MATH_LIB_VERSION/${IDML_VER}/
       }" debian/control
if grep -n '^XB-Static-Built-Using:.*_VERSION' debian/control >&2; then
   echo "ERROR: the Static-Built-Using field above kept its placeholder" >&2
   exit 1
fi
echo "Bundled versions: libbson ${LIBBSON_VER}, pcre2 ${PCRE2_VER}, intel-decimal-math ${IDML_VER}"

# Build the Debian package
debuild -us -uc

# Change to the root to make file renaming expression simpler
cd /

# Guard: the .deb must not ship or depend on libbson (it is statically linked).
# Static-Built-Using is checked separately since naming libbson there is correct.
shopt -s nullglob
deb_files=(*.deb)
shopt -u nullglob
if (( ${#deb_files[@]} == 0 )); then
   echo "ERROR: debuild produced no .deb in $(pwd)" >&2
   exit 1
fi
for f in "${deb_files[@]}"; do
   contents=$(dpkg-deb -c "$f") \
      && control=$(dpkg-deb -f "$f" Depends Pre-Depends Provides Conflicts Breaks Replaces) \
      || { echo "ERROR: dpkg-deb failed on $f" >&2; exit 1; }
   if grep -i libbson >&2 <<<"${contents}"; then
      echo "ERROR: $f ships the libbson file above (dpkg-deb -c)." >&2
      exit 1
   fi
   if grep -i libbson >&2 <<<"${control}"; then
      echo "ERROR: $f declares the libbson relationship above (dpkg-deb -f)." >&2
      exit 1
   fi

   # Skip auto-built debug packages; debhelper may strip Static-Built-Using from them.
   auto_built_package=$(dpkg-deb -f "$f" Auto-Built-Package) \
      || { echo "ERROR: dpkg-deb -f Auto-Built-Package failed on $f" >&2; exit 1; }
   if [[ -n "${auto_built_package}" ]]; then
      echo "libbson guard: $f is clean (auto-built, no declaration expected)"
      continue
   fi

   sbu=$(dpkg-deb -f "$f" Static-Built-Using) \
      || { echo "ERROR: dpkg-deb -f Static-Built-Using failed on $f" >&2; exit 1; }
   # Whole items, not substrings: 'notlibbson (= 1.28.0)' must not satisfy this.
   mapfile -t sbu_items < <(tr ',' '\n' <<<"${sbu}" | sed 's/^ *//; s/ *$//')
   for decl in "libbson (= ${LIBBSON_VER})" "pcre2 (= ${PCRE2_VER})" "intel-decimal-math (= ${IDML_VER})"; do
      printf '%s\n' "${sbu_items[@]}" | grep -qxF "${decl}" \
         || { echo "ERROR: $f does not record '${decl}' in Static-Built-Using (got: '${sbu}')." >&2; exit 1; }
   done
   echo "libbson guard: $f is clean, and records Static-Built-Using: ${sbu}"
done

# Rename .deb files to include the OS name prefix
for f in *.deb; do
   mv $f $OS-$f;
done

# Create the output directory if it doesn't exist
mkdir -p /output

# Copy the built packages to the output directory
cp *.deb /output/

# Change ownership of the output files to match the host user's UID and GID
chown -R $(stat -c "%u:%g" /output) /output