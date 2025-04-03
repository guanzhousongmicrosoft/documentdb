./scripts/start_oss_server.sh -c > ~/oss_server.log 2>&1 & 
wait # Wait for the first script to complete

./scripts/build_and_start_rust_gateway_oss.sh -u  > ~/rust_gateway.log 2>&1 &
