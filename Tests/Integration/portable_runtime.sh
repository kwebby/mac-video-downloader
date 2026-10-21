#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repository_dir="$(cd "$test_dir/../.." && pwd)"
cd "$repository_dir"
swift build --product HarborBroker
binary_dir="$(swift build --show-bin-path)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
core_objects=("$binary_dir/HarborCore.o")
engine_objects=("$binary_dir/HarborEngine.o")
if [[ ! -f "${core_objects[0]}" ]]; then core_objects=("$binary_dir"/HarborCore.build/*.swift.o); fi
if [[ ! -f "${engine_objects[0]}" ]]; then engine_objects=("$binary_dir"/HarborEngine.build/*.swift.o); fi
swiftc -parse-as-library -I "$binary_dir" -I "$binary_dir/Modules" -I "$repository_dir/Sources/CSQLite" \
    "${core_objects[@]}" "${engine_objects[@]}" -lsqlite3 \
    "$test_dir/PortableRuntimeHarness.swift" -o "$temporary_dir/portable-runtime-tests"
"$temporary_dir/portable-runtime-tests"
