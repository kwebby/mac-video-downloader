#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[a-p]{32}$ ]]; then
  print -u2 'Usage: Scripts/install-chrome-host.sh EXTENSION_ID [/absolute/path/MVD.app]'
  print -u2 'Load BrowserExtension as an unpacked extension first, then copy its exact ID.'
  exit 2
fi

extension_id="$1"
script_dir="${0:A:h}"
app_path="${2:-${script_dir:h}/build/MVD.app}"
if [[ "$app_path" != /* ]]; then
  print -u2 'The application path must be absolute.'
  exit 2
fi
host_path="${app_path%/}/Contents/MacOS/HarborNativeHost"
if [[ ! -x "$host_path" ]]; then
  print -u2 'HarborNativeHost is missing. Build/package MVD.app before registering the companion.'
  exit 1
fi

registration_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
registration_path="$registration_dir/io.harbor.downloads.json"
mkdir -p "$registration_dir"
umask 077
temporary_path="$(mktemp "$registration_dir/.io.harbor.downloads.XXXXXXXX")"
trap 'rm -f "$temporary_path"' EXIT

# JXA's JSON encoder handles spaces, quotes and Unicode in the application path.
/usr/bin/osascript -l JavaScript - "$extension_id" "$host_path" > "$temporary_path" <<'JXA'
function run(args) {
  return JSON.stringify({
    name: "io.harbor.downloads",
    description: "MVD desktop download handoff",
    path: args[1],
    type: "stdio",
    allowed_origins: ["chrome-extension://" + args[0] + "/"]
  }, null, 2);
}
JXA
chmod 600 "$temporary_path"
mv "$temporary_path" "$registration_path"
print "Registered MVD Companion for extension $extension_id."
print "Chrome host manifest: $registration_path"
print 'Re-run this command after moving the app or changing the unpacked extension ID.'
