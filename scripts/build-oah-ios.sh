#!/bin/bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/.." && pwd)"
oah_repo="${OAH_REPO:-$app_dir/../../oah}"
if [ ! -f "$oah_repo/SPEC.md" ]; then
  echo "Set OAH_REPO to the local oah repository." >&2
  exit 1
fi
cargo build --manifest-path "$oah_repo/Cargo.toml" -p oah-mobile --release --target aarch64-apple-ios-sim --locked
cargo build --manifest-path "$oah_repo/Cargo.toml" -p oah-mobile --release --target aarch64-apple-ios --locked
build_temp="$(mktemp -d)"
trap 'rm -rf "$build_temp"' EXIT
headers="$build_temp/headers"
mkdir "$headers"
cp "$oah_repo/crates/oah-mobile/include/oah_mobile.h" "$headers/"
printf 'module OAHMobile { header "oah_mobile.h" export * }\n' > "$headers/module.modulemap"
output="$app_dir/Packages/OAHCore/OAHMobile.xcframework"
xcodebuild -create-xcframework \
  -library "$oah_repo/target/aarch64-apple-ios/release/liboah_mobile.a" -headers "$headers" \
  -library "$oah_repo/target/aarch64-apple-ios-sim/release/liboah_mobile.a" -headers "$headers" \
  -output "$build_temp/OAHMobile.xcframework"
if [ -d "$output" ]; then mv "$output" "$build_temp/previous.xcframework"; fi
mv "$build_temp/OAHMobile.xcframework" "$output"
