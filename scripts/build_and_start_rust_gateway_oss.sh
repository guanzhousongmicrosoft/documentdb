#!/bin/bash

# TODO move this to the OSS folder

# exit immediately if a command exits with a non-zero status
set -e
# fail if trying to reference a variable that is not set.
set -u

configFile=""
help="false"
clean="false"
createUser="false"

while getopts "d:chu" opt; do
    case $opt in
    d)
        configFile="$OPTARG"
        ;;
    c)
        clean="true"
        ;;
    h)
        help="true"
        ;;
    u) createUser="true" ;;
    esac

    # Assume empty string if it's unset since we cannot reference to
    # an unset variable due to "set -u".
    case ${OPTARG:-""} in
    -*)
        echo "Option $opt needs a valid argument. use -h to get help."
        exit 1
        ;;
    esac
done

green=$(tput setaf 2)
if [ "$help" == "true" ]; then
    echo "${green}sets up and launches the documentdb rust gateway on the port specified in the config."
    echo "${green}build_and_start_rust_gateway_oss.sh -d <SetupConfigurationFile> [-c] [-u]"
    echo "${green}<SetupConfigurationFile> is the location of your config file,"
    echo "${green}[-c] - optional argument. runs cargo clean before building the gateway."
    echo "${green}[-u] - optional argument. creates an admin user for connection."
    echo "${green}       TestAdmin:Admin100"
    echo "${green}if SetupConfigurationFile not specified assumed to be"
    echo "${green}gateway/native/SetupConfiguration.JsTests.json and the default port is 10260"
    exit 1
fi

# Get the script directory
source="${BASH_SOURCE[0]}"
while [[ -L $source ]]; do
    scriptroot="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"

    # if $source was a relative symlink, we need to resolve it relative to the path where the
    # symlink file was located
    [[ $source != /* ]] && source="$scriptroot/$source"
done
scriptDir="$(cd -P "$(dirname "$source")" && pwd)"

pushd $scriptDir/../pg_documentdb_gw

if [ $clean = "true" ]; then
    echo "Cleaning the build directory..."
    cargo clean
fi

if [ $createUser = "true" ]; then
    echo "Creating user..."
    # This sets up a user
    user="TestAdmin"
    p="Admin100"
    port="9712"
    owner=$(whoami)

    echo "Setting up user $user with role privilege."
    psql -p $port -U $owner -d postgres -c "CREATE ROLE \"$user\" WITH LOGIN INHERIT PASSWORD '$p' IN ROLE documentdb_admin_role"
    psql -p $port -U $owner -d postgres -c "ALTER ROLE \"$user\" CREATEROLE"
    psql -p $port -U $owner -d postgres -c "GRANT \"$user\" TO $owner WITH ADMIN OPTION"
fi

if [ -z "$configFile" ]; then
    cargo run
else
    cargo run $configFile
fi
