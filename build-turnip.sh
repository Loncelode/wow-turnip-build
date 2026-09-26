#!/usr/bin/env bash
set -euo pipefail

MESA_COMMIT="8736d1a9a6b323fc2c6c1bdb5d6a445f1cef1575"
NDK_VER="android-ndk-r29"
ANDROID_API="34"
PLATFORM_SDK="36"
BUILD_VERSION="25.1-wow-ir3-fallback"
WORKDIR="${RUNNER_TEMP:-/tmp}/wow-turnip-build"
PREFIX="$WORKDIR/install"
MESA_DIR="$WORKDIR/mesa"
NDK_DIR="$WORKDIR/$NDK_VER"
NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
OUTDIR="$WORKDIR/out"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" "$OUTDIR"

echo "== Download Android NDK r29 =="
curl -L --fail --retry 3 "https://dl.google.com/android/repository/${NDK_VER}-linux.zip" -o "$WORKDIR/${NDK_VER}-linux.zip"
unzip -q "$WORKDIR/${NDK_VER}-linux.zip" -d "$WORKDIR"

echo "== Fetch exact A8XX MR v25.1 source revision =="
git init -q "$MESA_DIR"
git -C "$MESA_DIR" remote add origin https://github.com/whitebelyash/mesa-tu8.git
git -C "$MESA_DIR" fetch --depth=1 origin "$MESA_COMMIT"
git -C "$MESA_DIR" checkout -q --detach FETCH_HEAD

ACTUAL_COMMIT="$(git -C "$MESA_DIR" rev-parse HEAD)"
test "$ACTUAL_COMMIT" = "$MESA_COMMIT"
echo "Mesa commit: $ACTUAL_COMMIT"

echo "== Verify and apply WoW IR3 fallback patch =="
git -C "$MESA_DIR" apply --check "$GITHUB_WORKSPACE/patches/wow-ir3.patch"
git -C "$MESA_DIR" apply "$GITHUB_WORKSPACE/patches/wow-ir3.patch"
git -C "$MESA_DIR" diff --check

grep -n -A8 -B4 'relax_cross_block_baryf' "$MESA_DIR/src/freedreno/ir3/ir3_sched.c"

echo '#define TUGEN8_DRV_VERSION "v25.1-wow-ir3-fallback"' > "$MESA_DIR/src/freedreno/vulkan/tu_version.h"

mkdir -p "$WORKDIR/bin"
ln -sf "$NDK_BIN/clang" "$WORKDIR/bin/cc"
ln -sf "$NDK_BIN/clang++" "$WORKDIR/bin/c++"

export PATH="$WORKDIR/bin:$NDK_BIN:$PATH"
export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export OBJDUMP=llvm-objdump
export OBJCOPY=llvm-objcopy
export LDFLAGS="-fuse-ld=lld"

cd "$MESA_DIR"

cat > android-aarch64.txt <<EOF
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$NDK_BIN/ld.lld'
cpp_ld = '$NDK_BIN/ld.lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$NDK_BIN/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

cat > native.txt <<EOF
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

echo "== Configure Mesa =="
meson setup build-android-aarch64   --cross-file android-aarch64.txt   --native-file native.txt   --prefix "$PREFIX"   -Dbuildtype=release   -Dstrip=true   -Dplatforms=android   -Dvideo-codecs=   -Dplatform-sdk-version="$PLATFORM_SDK"   -Dandroid-stub=true   -Dgallium-drivers=   -Dvulkan-drivers=freedreno   -Dvulkan-beta=true   -Dfreedreno-kmds=kgsl   -Degl=disabled   -Dandroid-libbacktrace=disabled

echo "== Build =="
ninja -C build-android-aarch64 install

LIB="$(find "$PREFIX" -type f -name libvulkan_freedreno.so -print -quit)"
if [[ -z "$LIB" || ! -f "$LIB" ]]; then
  echo "ERROR: libvulkan_freedreno.so not found"
  find "$PREFIX" -maxdepth 4 -type f -print || true
  exit 1
fi

echo "Built: $LIB"
file "$LIB"
sha256sum "$LIB"

PKG="$WORKDIR/package"
mkdir -p "$PKG"
cp "$LIB" "$PKG/libvulkan_freedreno.so"

cat > "$PKG/meta.json" <<'EOF'
{
  "schemaVersion": 1,
  "name": "A8XX MR v25.1 WoW IR3 Fallback",
  "description": "A8XX MR v25.1 with fallback-only WoW IR3 scheduler relaxation for Adreno 829 testing",
  "author": "whitebelyash base + fallback-only WoW IR3 patch",
  "packageVersion": "2",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

(
  cd "$PKG"
  zip -9 "$OUTDIR/A8XX-MR-v25.1-WoW-IR3-Fallback.zip" libvulkan_freedreno.so meta.json
)

sha256sum "$OUTDIR/A8XX-MR-v25.1-WoW-IR3-Fallback.zip" | tee "$OUTDIR/A8XX-MR-v25.1-WoW-IR3-Fallback.zip.sha256"

cat > "$OUTDIR/PROVENANCE.txt" <<EOF
Base repository: https://github.com/whitebelyash/mesa-tu8
Base commit: $MESA_COMMIT
Reference package: A8XX MR v25.1
Patch: patches/wow-ir3.patch
Patch mode: fallback-only cross-block bary.f relaxation
NDK: $NDK_VER
Android compiler API: $ANDROID_API
Mesa platform-sdk-version: $PLATFORM_SDK
Build label: $BUILD_VERSION
EOF

echo "== Output =="
ls -lh "$OUTDIR"
