#!/usr/bin/env bash
# build_flavor.sh — macOS configure+build for compressonatorcli with the
# bc7enc_rdo integration. Companion to tools/linux/build_flavor.sh and
# tools/win/build_cli_batch.ps1: same three flavors (off / unbatched /
# batch), same flag intent, same build-dir naming.
#
# Usage:
#   tools/macos/build_flavor.sh [off|unbatched|batch] [x86_64|arm64]
# Defaults: batch x86_64.
#
# One binary per architecture. Join them into a universal binary with:
#   lipo -create -output compressonatorcli-bin <x86_64 bin> <arm64 bin>
#
# Prereqs (checked below):
#   - Xcode Command Line Tools (clang, make, lipo)
#   - macOS ISPC v1.31.0 unpacked at tools/ispc/macos/bin/ispc, relative to
#     the repo root that holds compressonator/ and bc7enc_rdo/ side by side.
#     ISPC host architecture matters. aarch64 *hosts* of ispc 1.19 and later
#     silently miscompile `--` on a varying unsigned int into a no-op
#     (ispc#3882), which corrupts bc7e.ispc's bit packing (bc7enc_rdo#23).
#     The damage is not confined to arm64 output — an arm64 ispc host
#     produces corrupt encoders for the x86_64 target too. With assertions
#     enabled the failure surfaces as "bc7e.ispc:2890: Assertion failed:
#     *pCur_ofs <= 128"; the release build disables assertions, so it would
#     instead ship silently wrong textures.
#
#     Two independent ways to be safe, and this script accepts either:
#       1. bc7enc_rdo#29 rewrites the five affected `x--` sites as `x -= 1`,
#          which any ispc host compiles correctly. Verified byte-identical
#          to an unpatched build made with an x86_64 host, on both targets.
#       2. Use the macOS x86_64 ISPC package, which runs under Rosetta 2 on
#          Apple Silicon.
#     The check below refuses only the unsafe combination: an arm64 ispc
#     against a bc7e.ispc that still carries the bare decrements.
#     https://github.com/ispc/ispc/issues/3882
#     https://github.com/richgel999/bc7enc_rdo/issues/23
#     https://github.com/richgel999/bc7enc_rdo/pull/29
#   - bc7enc_rdo checkout at ../bc7enc_rdo
#   - CMake 3.31 or later (needs CMAKE_POLICY_VERSION_MINIMUM). Override the
#     binary with CMAKE=/path/to/cmake.
#
# How this differs from the Linux recipe, and why:
#   - No -static. Darwin has no static libSystem, so a fully static link is
#     not available. The binary links only OS-shipped libraries
#     (libSystem, libc++), which need no install — the same practical
#     result as the Windows build's 3 OS DLLs.
#   - CMAKE_OSX_ARCHITECTURES selects the slice. An arm64 host builds the
#     x86_64 slice by cross-compiling; the result runs under Rosetta 2.
#   - The bc7e ISPC target list follows the architecture: the four
#     SSE/AVX targets for x86_64, NEON for arm64.
#   - OPTION_BUILD_EXR is OFF on both, as on Linux.

set -euo pipefail

FLAVOR="${1:-batch}"
ARCH="${2:-x86_64}"

case "$FLAVOR" in
  off)       USE_RDO=OFF; USE_BATCH=OFF; BUILD_BASE=build_cli_off   ;;
  unbatched) USE_RDO=ON;  USE_BATCH=OFF; BUILD_BASE=build_cli       ;;
  batch)     USE_RDO=ON;  USE_BATCH=ON;  BUILD_BASE=build_cli_batch ;;
  *) echo "usage: $0 [off|unbatched|batch] [x86_64|arm64]" >&2; exit 2 ;;
esac

case "$ARCH" in
  x86_64) ISPC_ARCH=x86-64;  ISPC_TARGETS=sse2,sse4,avx,avx2; DEPLOY_TARGET=10.15 ;;
  arm64)  ISPC_ARCH=aarch64; ISPC_TARGETS=neon-i32x4;         DEPLOY_TARGET=11.0  ;;
  *) echo "usage: $0 [off|unbatched|batch] [x86_64|arm64]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"        # compressonator/ root
ROOT="$(cd "$SRC/.." && pwd)"                 # repo root (holds tools/, bc7enc_rdo/)
BUILD="$SRC/${BUILD_BASE}_macos_${ARCH}"
ISPC="$ROOT/tools/ispc/macos/bin/ispc"
BC7ENC="$ROOT/bc7enc_rdo"
CMAKE="${CMAKE:-cmake}"

echo "Flavor      : $FLAVOR"
echo "Arch        : $ARCH (ispc --arch=$ISPC_ARCH --target=$ISPC_TARGETS)"
echo "RepoRoot    : $ROOT"
echo "Source      : $SRC"
echo "Build       : $BUILD"
echo "ISPC        : $ISPC"
echo "bc7enc_rdo  : $BC7ENC"
echo "CMake       : $CMAKE"

command -v "$CMAKE" >/dev/null || { echo "cmake not found: $CMAKE" >&2; exit 1; }

if [[ "$USE_RDO" == "ON" ]]; then
  [[ -x "$ISPC" ]] || { echo "ISPC not executable at $ISPC" >&2; exit 1; }
  [[ -f "$BC7ENC/bc7e.ispc" ]] || { echo "bc7enc_rdo checkout missing at $BC7ENC (need bc7e.ispc)" >&2; exit 1; }

  # Refuse an arm64 ispc host against an unpatched bc7e.ispc — see the
  # prereq note above (ispc#3882). A checkout carrying bc7enc_rdo#29 has no
  # bare `--` left on these unsigned varyings and compiles correctly anywhere.
  if file -b "$ISPC" | grep -q arm64; then
    if grep -qE '^[[:space:]]*(sel|n|la)--;' "$BC7ENC/bc7e.ispc"; then
      echo "ERROR: $ISPC is an arm64 build of ispc, and $BC7ENC/bc7e.ispc still" >&2
      echo "       uses bare '--' on varying unsigned values. That combination" >&2
      echo "       miscompiles silently (ispc#3882 / bc7enc_rdo#23) and produces" >&2
      echo "       corrupt BC7 output for every target." >&2
      echo "       Fix either side: apply bc7enc_rdo#29, or use the macOS x86_64" >&2
      echo "       ispc package, which runs under Rosetta 2." >&2
      exit 1
    fi
    echo "Note: arm64 ispc host accepted — bc7e.ispc carries the bc7enc_rdo#29 rewrite."
  fi
fi

# Clean build dir so stale cache entries can't shadow the flags below.
rm -rf "$BUILD"

CMAKE_ARGS=(
  -S "$SRC"
  -B "$BUILD"
  -G "Unix Makefiles"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET"
  -DOPTION_ENABLE_ALL_APPS=OFF
  -DOPTION_BUILD_APPS_CMP_CLI=ON
  -DOPTION_BUILD_APPS_CMP_GUI=OFF
  -DOPTION_BUILD_CMP_SDK=OFF
  -DOPTION_BUILD_APPS_CMP_UNITTESTS=OFF
  -DOPTION_BUILD_INTERNAL_CMP_TEST=OFF
  -DOPTION_CMP_OPENCV=OFF
  -DOPTION_CMP_OPENGL=OFF
  -DOPTION_CMP_QT=OFF
  -DOPTION_CMP_DIRECTX=OFF
  -DOPTION_BUILD_KTX2=OFF
  -DOPTION_BUILD_BROTLIG=OFF
  -DOPTION_BUILD_EXR=OFF
  -DOPTION_CMP_ETC=OFF
  -DOPTION_CMP_USE_BC7ENC_RDO="$USE_RDO"
  -DOPTION_CMP_USE_BC7ENC_RDO_BATCH="$USE_BATCH"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

if [[ "$USE_RDO" == "ON" ]]; then
  CMAKE_ARGS+=(
    -DBC7ENC_RDO_ISPC="$ISPC"
    -DBC7ENC_RDO_DIR="$BC7ENC"
    -DBC7ENC_RDO_ISPC_ARCH="$ISPC_ARCH"
    -DBC7ENC_RDO_ISPC_TARGETS="$ISPC_TARGETS"
  )
fi

"$CMAKE" "${CMAKE_ARGS[@]}"
"$CMAKE" --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"

BIN="$BUILD/bin/compressonatorcli-bin"
if [[ -f "$BIN" ]]; then
  echo
  echo "BUILD OK: $BIN"
  file "$BIN" | sed 's/^/  file: /'
  echo "  otool -L:"
  otool -L "$BIN" | tail -n +2 | sed 's/^/    /'
else
  echo "Build reported success but binary not at expected path: $BIN" >&2
  exit 1
fi
