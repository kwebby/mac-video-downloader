#!/bin/bash
set -euo pipefail
test_dir="$(cd "$(dirname "$0")" && pwd)"
repository_dir="$(cd "$test_dir/../.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
swiftc -emit-library -emit-module -module-name HarborCore "$repository_dir/Sources/HarborCore/Models.swift" "$repository_dir/Sources/HarborCore/PublicNetworkPolicy.swift" "$repository_dir/Sources/HarborCore/ChromeCompanionConnection.swift" -o "$temporary_dir/libHarborCore.dylib" -emit-module-path "$temporary_dir/HarborCore.swiftmodule"
swiftc -I "$temporary_dir" -L "$temporary_dir" -lHarborCore -Xlinker -rpath -Xlinker "$temporary_dir" "$repository_dir/Sources/HarborNativeHost/NativeMessageFraming.swift" "$repository_dir/Sources/HarborNativeHost/HostRegistration.swift" "$test_dir/ChromeCompanionConnectionHarness.swift" -o "$temporary_dir/chrome-connection-tests"
"$temporary_dir/chrome-connection-tests"
