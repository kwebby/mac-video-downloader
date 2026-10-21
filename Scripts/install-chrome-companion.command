#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
app_path="${1:-/Applications/MVD.app}"
source_dir="$script_dir/MVD Companion"
support_dir="$HOME/Library/Application Support/MVD"
target_dir="$support_dir/Chrome Companion"
staging_dir=""
runtime_replaced=false
registration_complete=false

finish() {
  local result=$?
  if [[ "$result" -ne 0 && "$runtime_replaced" == true && "$registration_complete" == false ]]; then
    rm -rf "$target_dir"
    if [[ -d "$staging_dir/previous-extension" ]]; then
      mv "$staging_dir/previous-extension" "$target_dir"
    fi
  fi
  [[ -z "$staging_dir" ]] || rm -rf "$staging_dir"
  if [[ -t 0 ]]; then
    print '\nPress Return to close this installer.'
    read -r _reply
  fi
  return "$result"
}
trap finish EXIT

if [[ $# -gt 1 || "$app_path" != /* || ! -x "$app_path/Contents/MacOS/HarborNativeHost" ]]; then
  print -u2 'Install MVD.app in /Applications and open it once, then run this installer again.'
  print -u2 'For another location: zsh "Install Chrome Companion.command" "/absolute/path/MVD.app"'
  exit 2
fi
if [[ ! -f "$source_dir/manifest.json" || ! -f "$script_dir/EXTENSION-ID.txt" || ! -f "$script_dir/install-chrome-host.sh" ]]; then
  print -u2 'Keep this installer with the complete Chrome Companion package.'
  exit 2
fi
extension_id="$(< "$script_dir/EXTENSION-ID.txt")"
if [[ ! "$extension_id" =~ ^[a-p]{32}$ ]]; then
  print -u2 'The packaged extension identity is invalid. Download a complete package again.'
  exit 2
fi
if [[ -L "$support_dir" || -L "$target_dir" ]]; then
  print -u2 'The MVD support or extension path is a symbolic link. Use a regular folder before installing.'
  exit 2
fi

mkdir -p "$support_dir"
staging_dir="$(mktemp -d "$support_dir/.chrome-companion.XXXXXXXX")"
/usr/bin/ditto "$source_dir" "$staging_dir/extension"
if [[ -e "$target_dir" ]]; then
  # Replace only MVD's owned extension runtime, never downloads or browser data.
  if [[ ! -d "$target_dir" || ! -f "$target_dir/manifest.json" ]]; then
    print -u2 'The extension destination is occupied by another item. Move it before installing.'
    exit 2
  fi
  mv "$target_dir" "$staging_dir/previous-extension"
fi
mv "$staging_dir/extension" "$target_dir"
runtime_replaced=true
/bin/zsh "$script_dir/install-chrome-host.sh" "$extension_id" "$app_path"
registration_complete=true

print '\nThe extension files and desktop bridge are ready.'
print 'Chrome still needs your explicit installation:'
print '1. Open chrome://extensions in Google Chrome.'
print '2. Turn on Developer mode, then click Load unpacked.'
print "3. Select: $target_dir"
print "4. Confirm its ID is $extension_id and pin MVD Companion."
print 'For an update, click Reload on the existing companion and refresh video pages.'
print 'This installer does not install or enable an extension, alter Chrome policies, or grant site access.'
