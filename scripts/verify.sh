#!/bin/sh
# Runs every check that needs neither hardware nor code signing:
# the protocol tests, the macOS probe, the driver extension, and the app
# (with the embedded driver) for macOS and iPadOS.
set -eu
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$1"; }

step "Swift package: build and test"
swift build
swift test

step "Driver extension (DriverKit)"
xcodebuild -quiet -project YubiKeyUSBPoC.xcodeproj -scheme YubiKeyUSBDriver \
  -configuration Debug -sdk driverkit CODE_SIGNING_ALLOWED=NO build

for platform in macOS iOS; do
  step "App with embedded driver ($platform)"
  xcodebuild -quiet -project YubiKeyUSBPoC.xcodeproj -scheme YubiKeyUSBPoC \
    -configuration Debug -destination "generic/platform=$platform" CODE_SIGNING_ALLOWED=NO build
done

step "All checks passed"
