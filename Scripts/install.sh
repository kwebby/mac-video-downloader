#!/bin/bash
# Install the signed public MVD release using tools included with macOS.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

repository="https://github.com/kwebby/mac-video-downloader"
release_api="https://api.github.com/repos/kwebby/mac-video-downloader/releases/latest"
team_id="SG77J9KKYK"
signing_authority="Developer ID Application: Raman Singh (SG77J9KKYK)"
version="${MVD_VERSION:-latest}"
destination=""
download_only=0
replace=0
work_dir=""
stage_dir=""
mount_dir=""
mounted=0
preserve_stage=0
stapler=""

say() { printf '%s\n' "$*"; }
fail() { printf 'MVD: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Install MVD for Apple Silicon, macOS 14 or later.

Usage: bash install.sh [options]

  --version VERSION    Install a release such as v0.4.4 (default: latest).
  --destination DIR    App folder (default: /Applications). With
                       --download-only, the default is the current folder.
  --download-only      Save the verified DMG without installing the app.
  --replace            Explicitly allow replacing an existing app or DMG.
  -h, --help           Show this help.

MVD_VERSION can also pin the release. This installer does not use sudo,
quit apps, open MVD, or install a browser extension. If /Applications is
not writable, use --destination "$HOME/Applications".
USAGE
}

cleanup() {
    local status=$?
    local keep_work=0
    trap - EXIT INT TERM HUP
    if [[ "$mounted" == 1 ]]; then
        if ! /usr/bin/hdiutil detach "$mount_dir" >/dev/null 2>&1; then
            printf 'MVD: Could not eject %s. Eject it in Finder; temporary files were kept.\n' "$mount_dir" >&2
            keep_work=1
            [[ "$status" != 0 ]] || status=1
        fi
    fi
    if [[ -n "$stage_dir" && "$preserve_stage" == 0 ]]; then /bin/rm -rf "$stage_dir"; fi
    if [[ -n "$work_dir" && "$keep_work" == 0 ]]; then /bin/rm -rf "$work_dir"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 && -n "${2:-}" ]] || fail '--version needs a release number.'
            version="$2"; shift 2 ;;
        --destination)
            [[ $# -ge 2 && -n "${2:-}" ]] || fail '--destination needs a folder.'
            destination="$2"; shift 2 ;;
        --download-only) download_only=1; shift ;;
        --replace) replace=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1. Use --help for options." ;;
    esac
done

if [[ "$version" != latest && ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail 'Use a stable version such as v0.4.4, or latest.'
fi
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'This installer runs on macOS.'
[[ "$(/usr/bin/uname -m)" == arm64 ]] || fail 'MVD requires an Apple Silicon Mac. Run Terminal natively if it is using Rosetta.'
macos_version="$(/usr/bin/sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
[[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 14 ]] || fail 'MVD requires macOS 14 or later.'

if [[ -z "$destination" ]]; then
    if [[ "$download_only" == 1 ]]; then destination="$PWD"; else destination=/Applications; fi
fi
case "$destination" in /*) ;; *) destination="$PWD/$destination" ;; esac
/bin/mkdir -p "$destination" || fail "Could not create $destination. Choose a writable --destination."
destination="$(cd "$destination" && /bin/pwd -P)"
[[ -w "$destination" ]] || fail "$destination is not writable. Choose a writable --destination."

check_running_app() {
    if /usr/bin/pgrep -x MVD >/dev/null 2>&1; then
        fail 'Quit MVD before installing. No running app was stopped.'
    fi
    if /usr/bin/pgrep -x HarborBroker >/dev/null 2>&1; then
        fail 'MVD background downloads are still running. Stop its background service before installing; no process was stopped.'
    fi
}

check_target() {
    [[ ! -L "$target" ]] || fail "Refusing to replace a symbolic link: $target"
    if [[ -e "$target" ]]; then
        [[ "$replace" == 1 ]] || fail "$target already exists. Use --replace to replace it explicitly."
        if [[ "$download_only" == 1 ]]; then
            [[ -f "$target" ]] || fail "The download target is not a regular file: $target"
        else
            [[ -d "$target" ]] || fail "The app target is not a folder: $target"
        fi
    fi
}

# Refuse a conflicting install before making network requests.
if [[ "$download_only" == 0 ]]; then
    target="$destination/MVD.app"
    check_target
    check_running_app
fi

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mvd-install.XXXXXX")" || fail 'Could not create a temporary folder.'
mount_dir="$work_dir/mount"

fetch() {
    /usr/bin/curl --fail --location --silent --show-error --retry 2 \
        --connect-timeout 15 --max-time 900 --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --output "$2" "$1" || fail "Could not download $1. Check your connection and release version."
}

if [[ "$version" == latest ]]; then
    say 'Finding the latest MVD release...'
    fetch "$release_api" "$work_dir/release.json"
    version="$(/usr/bin/plutil -extract tag_name raw -o - "$work_dir/release.json" 2>/dev/null)" || fail 'GitHub did not return a release tag. Try --version v0.4.4.'
fi
[[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'GitHub returned an unexpected release tag.'
version="${version#v}"
tag="v$version"
asset="MVD-$version-arm64.dmg"
release_url="$repository/releases/download/$tag"
dmg="$work_dir/$asset"
if [[ "$download_only" == 1 ]]; then target="$destination/$asset"; check_target; fi
target_identity=""
if [[ -e "$target" ]]; then target_identity="$(/usr/bin/stat -f '%d:%i' "$target")"; fi

say "Getting MVD $tag..."
fetch "$release_url/SHA256SUMS.txt" "$work_dir/SHA256SUMS.txt"
fetch "$release_url/$asset" "$dmg"

# Validate exactly one named entry. Other manifest entries are never interpreted
# as local paths by shasum.
/usr/bin/awk -v asset="$asset" '
    $2 == asset {
        count++
        if (NF != 2 || length($1) != 64 || $1 !~ /^[[:xdigit:]]+$/) invalid=1
        hash=tolower($1)
    }
    END {
        if (count != 1 || invalid) exit 1
        print hash "  " asset
    }
' "$work_dir/SHA256SUMS.txt" >"$work_dir/selected-checksum.txt" || fail 'The release checksum entry is missing, duplicated, or invalid.'
say 'Checking the download...'
(cd "$work_dir" && /usr/bin/shasum -a 256 --check --strict selected-checksum.txt) >"$work_dir/checksum.log" 2>&1 || fail 'The download checksum did not match. Nothing was installed.'

# Read an already installed developer-tool location without invoking xcrun or
# asking macOS to install Command Line Tools. Gatekeeper is always required.
developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
if [[ -n "$developer_dir" && -x "$developer_dir/usr/bin/stapler" ]]; then stapler="$developer_dir/usr/bin/stapler"; fi

verify_signature() {
    local path="$1"
    local kind="$2"
    local requirement='=anchor apple generic and certificate leaf[subject.OU] = "SG77J9KKYK"'
    if [[ "$kind" == app ]]; then requirement="$requirement and (identifier \"io.harbor.downloads\" or identifier \"io.harbor.downloads.dev\")"; fi
    /usr/bin/codesign --verify --deep --strict --test-requirement="$requirement" "$path" >"$work_dir/signature.log" 2>&1 || fail "Apple signature validation failed for $(/usr/bin/basename "$path"). Nothing was installed."
    /usr/bin/codesign --display --verbose=4 "$path" >"$work_dir/signer.log" 2>&1 || fail 'Could not read the Apple signing identity.'
    /usr/bin/grep -Fxq "TeamIdentifier=$team_id" "$work_dir/signer.log" && \
        /usr/bin/grep -Fxq "Authority=$signing_authority" "$work_dir/signer.log" || fail 'The signing identity does not match Raman Singh (SG77J9KKYK). Nothing was installed.'
    if [[ -n "$stapler" ]]; then
        "$stapler" validate "$path" >"$work_dir/stapler.log" 2>&1 || fail 'The Apple notarization ticket could not be validated. Nothing was installed.'
    fi
    if [[ "$kind" == dmg ]]; then
        /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$path" >"$work_dir/gatekeeper.log" 2>&1 || fail 'Gatekeeper rejected the disk image. Nothing was installed.'
    else
        /usr/sbin/spctl --assess --type execute --verbose=2 "$path" >"$work_dir/gatekeeper.log" 2>&1 || fail 'Gatekeeper rejected the app. Nothing was installed.'
    fi
    /usr/bin/grep -Fxq 'source=Notarized Developer ID' "$work_dir/gatekeeper.log" || fail 'Gatekeeper did not confirm Apple notarization. Nothing was installed.'
}

say 'Checking the Apple signature and notarization...'
verify_signature "$dmg" dmg
/bin/mkdir "$mount_dir"
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" "$dmg" >"$work_dir/mount.log" 2>&1 || fail 'Could not mount the verified disk image. Nothing was installed.'
mounted=1
source_app="$mount_dir/MVD.app"
[[ -d "$source_app" && ! -L "$source_app" ]] || fail 'The disk image does not contain a regular MVD.app bundle.'
verify_signature "$source_app" app
app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$source_app/Contents/Info.plist" 2>/dev/null)" || fail 'Could not read the app version.'
[[ "$app_version" == "$version" ]] || fail 'The app version does not match the selected release.'

stage_dir="$(/usr/bin/mktemp -d "$destination/.mvd-install.XXXXXX")" || fail 'Could not stage files in the selected destination.'
if [[ "$download_only" == 1 ]]; then
    staged="$stage_dir/$asset"
    /bin/cp -p "$dmg" "$staged" || fail 'Could not save the verified download.'
else
    staged="$stage_dir/MVD.app"
    /usr/bin/ditto "$source_app" "$staged" || fail 'Could not copy MVD. The previous app was kept.'
    verify_signature "$staged" app
fi
/usr/bin/hdiutil detach "$mount_dir" >"$work_dir/eject.log" 2>&1 || fail 'Could not eject the disk image. Nothing was installed; eject it in Finder and retry.'
mounted=0

check_target
if [[ "$download_only" == 0 ]]; then check_running_app; fi
current_identity=""
if [[ -e "$target" ]]; then current_identity="$(/usr/bin/stat -f '%d:%i' "$target")"; fi
[[ "$current_identity" == "$target_identity" ]] || fail 'The destination changed while downloading. Nothing was replaced; run the installer again.'

backup="$stage_dir/previous"
if [[ -e "$target" ]]; then /bin/mv "$target" "$backup" || fail 'Could not move the previous version aside. It was kept.'; fi
if ! /bin/mv "$staged" "$target"; then
    if [[ -e "$backup" ]]; then
        if ! /bin/mv "$backup" "$target"; then
            preserve_stage=1
            fail "Could not finish or restore the previous version. Its files are safe at $backup."
        fi
    fi
    fail 'Could not finish installing. The previous version was restored.'
fi

if [[ "$download_only" == 1 ]]; then
    say "Saved verified MVD $tag to $target"
else
    say "Installed MVD $tag at $target"
    say 'Open MVD to get started and connect Chrome.'
fi
