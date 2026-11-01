#!/bin/sh
# Exercises the real app model and Swift driver client with a fake C I/O boundary.
set -eu
cd "$(dirname "$0")/.."
status_build_dir=$(mktemp -d)
trap 'rm -rf "$status_build_dir"' EXIT
xcrun clang -c Tests/AppConnectionTests/DriverStub.c -I App -I Shared \
  -o "$status_build_dir/stub.o"
xcrun swiftc -parse-as-library -module-cache-path "$status_build_dir/cache" \
  -import-objc-header Tests/AppConnectionTests/DriverStub.h -I App -I Shared \
  Sources/YubiKeyOTP/*.swift App/DriverClient.swift App/AppModel.swift \
  Tests/AppConnectionTests/main.swift "$status_build_dir/stub.o" \
  -o "$status_build_dir/check"
"$status_build_dir/check"
