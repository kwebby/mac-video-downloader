#!/bin/bash
# Build standalone LGPL FFmpeg tools. No global installs or Homebrew libraries.
set -euo pipefail

runtime_dir="$(cd "$(dirname "$0")" && pwd)"
target_arch="${1:-arm64}"
case "$target_arch" in
  arm64) configure_arch=aarch64; host_triplet=aarch64-apple-darwin ;;
  x86_64) configure_arch=x86_64; host_triplet=x86_64-apple-darwin ;;
  *) echo "Usage: $0 [arm64|x86_64]" >&2; exit 2 ;;
esac
jobs="${MVD_BUILD_JOBS:-6}"
deployment_target="${MVD_MACOS_DEPLOYMENT_TARGET:-13.0}"
pkg_config_tool="${MVD_PKG_CONFIG:-$(command -v pkg-config || true)}"
test -x "$pkg_config_tool" || { echo 'pkg-config is required only on the build machine.' >&2; exit 1; }
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --sdk macosx --find clang)"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
cache_dir="$runtime_dir/cache"
work_dir="$runtime_dir/build/$target_arch"
prefix_dir="$work_dir/prefix"
output_dir="$runtime_dir/output/$target_arch"
mkdir -p "$cache_dir" "$work_dir" "$prefix_dir" "$output_dir/bin" "$output_dir/licenses" "$output_dir/source" "$output_dir/reports"

while read -r component version checksum url; do
  [[ "$component" == \#* || -z "$component" ]] && continue
  archive="$cache_dir/${url##*/}"
  # A distributed source kit keeps the pinned archives beside this script.
  if [[ ! -f "$archive" && -f "$runtime_dir/${url##*/}" ]]; then
    cp "$runtime_dir/${url##*/}" "$archive"
  fi
  if [[ ! -f "$archive" ]]; then
    /usr/bin/curl --fail --silent --show-error --location --retry 2 --proto '=https' --tlsv1.2 "$url" --output "$archive.partial"
    mv "$archive.partial" "$archive"
  fi
  actual_checksum="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
  [[ "$actual_checksum" == "$checksum" ]] || { echo "Checksum mismatch: $archive" >&2; exit 1; }
  source_dir="$work_dir/$component-$version"
  [[ -d "$source_dir" ]] || /usr/bin/tar -xf "$archive" -C "$work_dir"
  cp "$archive" "$output_dir/source/"
done < "$runtime_dir/media-sources.lock"

common_cflags="-O2 -arch $target_arch -isysroot $sdk_path -mmacosx-version-min=$deployment_target"
common_ldflags="-arch $target_arch -isysroot $sdk_path -mmacosx-version-min=$deployment_target"
export CC="$compiler" CXX="$compiler++"
export CFLAGS="$common_cflags" CXXFLAGS="$common_cflags" LDFLAGS="$common_ldflags"
export PKG_CONFIG_PATH="$prefix_dir/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix_dir/lib/pkgconfig"
export PKG_CONFIG="$pkg_config_tool"

if [[ ! -f "$prefix_dir/lib/libmp3lame.a" ]]; then
  echo "Building LAME 4.0 ($target_arch)…"
  (
    cd "$work_dir/lame-4.0"
    ./configure --prefix="$prefix_dir" --host="$host_triplet" --disable-shared --enable-static --enable-pic --disable-decoder --disable-frontend --disable-gtktest > "$output_dir/reports/lame-configure.log" 2>&1
    /usr/bin/make -j "$jobs" > "$output_dir/reports/lame-build.log" 2>&1
    /usr/bin/make install > "$output_dir/reports/lame-install.log" 2>&1
    cp config.log config.status "$output_dir/reports/"
    mv "$output_dir/reports/config.log" "$output_dir/reports/lame-config.log"
    mv "$output_dir/reports/config.status" "$output_dir/reports/lame-config.status"
  )
fi
if [[ ! -f "$prefix_dir/lib/libopus.a" ]]; then
  echo "Building Opus 1.6.1 ($target_arch)…"
  (
    cd "$work_dir/opus-1.6.1"
    ./configure --prefix="$prefix_dir" --host="$host_triplet" --disable-shared --enable-static --disable-doc --disable-extra-programs --disable-dred --disable-deep-plc --disable-osce > "$output_dir/reports/opus-configure.log" 2>&1
    /usr/bin/make -j "$jobs" > "$output_dir/reports/opus-build.log" 2>&1
    /usr/bin/make install > "$output_dir/reports/opus-install.log" 2>&1
    cp config.log "$output_dir/reports/opus-config.log"
    cp config.status "$output_dir/reports/opus-config.status"
  )
fi

echo "Building FFmpeg 9.0.2 and FFprobe ($target_arch)…"
(
  cd "$work_dir/ffmpeg-9.0.2"
  ./configure \
    --prefix="$prefix_dir" --target-os=darwin --arch="$configure_arch" \
    --cc="$compiler" --cxx="$compiler++" --sysroot="$sdk_path" --pkg-config="$pkg_config_tool" \
    --host-cc="$compiler" --host-cflags="-O2 -isysroot $sdk_path -mmacosx-version-min=$deployment_target" \
    --host-ldflags="-isysroot $sdk_path -mmacosx-version-min=$deployment_target" \
    --extra-cflags="$common_cflags -I$prefix_dir/include" \
    --extra-ldflags="$common_ldflags -L$prefix_dir/lib" \
    --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 \
    --disable-shared --enable-static --enable-pic --disable-debug --disable-doc \
    --disable-ffplay --disable-avdevice --disable-indevs --disable-outdevs --disable-x86asm \
    --enable-securetransport --enable-zlib --enable-libmp3lame --enable-libopus \
    --disable-protocols --enable-protocol=file,http,https,tcp,tls,httpproxy,crypto,data,concat,subfile,pipe \
    --disable-encoders --enable-encoder=aac,alac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,libmp3lame,libopus \
    --disable-filters --enable-filter=aresample,anull,aformat,atrim,asetpts,apad,volume \
    > "$output_dir/reports/ffmpeg-configure.log" 2>&1
  /usr/bin/make -j "$jobs" ffmpeg ffprobe > "$output_dir/reports/ffmpeg-build.log" 2>&1
  cp ffmpeg ffprobe "$output_dir/bin/"
  cp ffbuild/config.log "$output_dir/reports/ffmpeg-config.log"
  cp ffbuild/config.mak "$output_dir/reports/ffmpeg-config.mak"
  cp config.h "$output_dir/reports/ffmpeg-config.h"
)

cp "$work_dir/ffmpeg-9.0.2/COPYING.LGPLv2.1" "$output_dir/licenses/FFmpeg-LGPL-2.1.txt"
cp "$work_dir/ffmpeg-9.0.2/LICENSE.md" "$output_dir/licenses/FFmpeg-LICENSE.md"
cp "$work_dir/lame-4.0/COPYING" "$output_dir/licenses/LAME-LGPL-2.0.txt"
cp "$work_dir/lame-4.0/LICENSE" "$output_dir/licenses/LAME-LICENSE.txt"
cp "$work_dir/opus-1.6.1/COPYING" "$output_dir/licenses/Opus-BSD-3-Clause.txt"
cp "$runtime_dir/media-sources.lock" "$runtime_dir/build-media-runtime.sh" "$runtime_dir/verify-media-runtime.py" "$runtime_dir/MEDIA-NOTICES.md" "$runtime_dir/README.md" "$output_dir/source/"
cp "$runtime_dir/MEDIA-NOTICES.md" "$output_dir/licenses/"
printf '%s\n' 'No source-code patches were applied. Configure/build commands are in build-media-runtime.sh. GPL, nonfree and version3 FFmpeg components were disabled.' > "$output_dir/source/PATCHES.txt"
{
  /usr/bin/sw_vers
  "$compiler" --version
  "$pkg_config_tool" --version
  printf 'Target architecture: %s\nDeployment target: %s\nSDK: %s\n' "$target_arch" "$deployment_target" "$sdk_path"
} > "$output_dir/reports/build-environment.txt"
"$output_dir/bin/ffmpeg" -version > "$output_dir/reports/ffmpeg-version.txt" 2>&1
"$output_dir/bin/ffmpeg" -L > "$output_dir/reports/ffmpeg-license.txt" 2>&1
"$output_dir/bin/ffmpeg" -encoders > "$output_dir/reports/ffmpeg-encoders.txt" 2>&1
"$output_dir/bin/ffmpeg" -protocols > "$output_dir/reports/ffmpeg-protocols.txt" 2>&1
for binary in "$output_dir/bin/ffmpeg" "$output_dir/bin/ffprobe"; do
  /usr/bin/otool -L "$binary" > "$output_dir/reports/$(basename "$binary")-dependencies.txt"
  if /usr/bin/otool -L "$binary" | /usr/bin/awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad=1 } END { exit !bad }'; then
    echo "Non-system dynamic dependency found: $binary" >&2; exit 1
  fi
done
/usr/bin/shasum -a 256 "$output_dir/bin/ffmpeg" "$output_dir/bin/ffprobe" > "$output_dir/reports/binary-sha256.txt"
echo "Portable media runtime built: $output_dir"
