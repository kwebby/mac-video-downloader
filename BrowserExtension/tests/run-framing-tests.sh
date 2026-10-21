#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repository_dir="$(cd "$test_dir/../.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
swiftc "$repository_dir/Sources/HarborNativeHost/NativeMessageFraming.swift" "$repository_dir/Sources/HarborCore/PublicNetworkPolicy.swift" "$test_dir/FramingHarness.swift" -o "$temporary_dir/framing-tests"
"$temporary_dir/framing-tests"
