# The three spellings of one DocumentDB release, in one place. Sourced (POSIX
# sh) by the package build scripts and the gateway Dockerfiles so the RC
# grammar cannot drift between them.
#
#   package  1.0~rc2    deb/rpm Version; ~ sorts below the 1.0.0 / 1.0-0 release
#   display  1.0-rc2    file names, image tags, /version.txt, install.sh --version
#   cargo    1.0.0-rc2  the gateway binary; Cargo needs X.Y.Z and has no ~
#
# Stable versions pass through: 1.0.0 stays 1.0.0, and the control-file form
# 1.0-0 becomes 1.0.0 for Cargo.

# 1.0-rc2 or 1.0.0-rc2 -> 1.0~rc2 (a literal -rc2 would be a Debian revision above GA).
documentdb_package_version() {
    printf '%s' "$1" | sed -E 's/^([0-9]+\.[0-9]+)(\.0)?-rc([0-9]+)$/\1~rc\3/'
}

# 1.0~rc2 -> 1.0-rc2
documentdb_display_version() {
    printf '%s' "$1" | tr '~' '-'
}

# 1.0~rc2 or 1.0-rc2 -> 1.0.0-rc2; 1.0-0 -> 1.0.0
documentdb_cargo_version() {
    printf '%s' "$1" | sed -E -e 's/^([0-9]+\.[0-9]+)[-~]rc([0-9]+)$/\1.0-rc\2/' -e 's/^([0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/'
}
