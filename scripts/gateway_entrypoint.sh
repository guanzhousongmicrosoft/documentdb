#!/bin/bash

echo "Starting OSS server..."
./scripts/start_oss_server.sh -c > /home/documentdb/oss_server.log 2>&1
wait # Wait for the OSS server script to finish
echo "OSS server started."

echo "Starting Rust gateway..."
./scripts/build_and_start_rust_gateway_oss.sh -u -d ~/code/pg_documentdb_gw/SetupConfiguration.json > /home/documentdb/rust_gateway.log 2>&1 &
