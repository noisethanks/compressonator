#!/usr/bin/env bash
# build_flavor.sh — macOS configure+build for compressonatorcli with the
# bc7enc_rdo integration. Companion to tools/linux/build_flavor.sh and
# tools/win/build_cli_batch.ps1: same three flavors (off / unbatched /
# batch), same flag intent, same build-dir naming.
#
# Usage:
#   tools/macos/build_flavor.sh [off|unbatched|batch] [arm64|x86_64|universal]
# Defaults: batch arm64.
#
# The arch default is arm64, not the host and not x86_64. An x86_64 default
# is wrong on every Apple Silicon machine, and the ISPC package most people
# already have installed is the arm64 one, which cannot emit x86-64 at all
# (see the ISPC note below). Host detection is not used because `uname -m`
# reports x86_64 inside a Rosetta shell. Intel users pass x86_64 explicitly.
#
# `universal` builds both slices, joins them with `lipo -create`, and ad-hoc
# signs the result. That is the artifact ATAK embeds. It is opt-in because it
# doubles the wall clock, and because it needs an ISPC that can emit both
# architectures.
#
# First-time setup, from nothing:
#
#   mkdir -p ~/dev/cmp && cd ~/dev/cmp
#
#   git clone -b bc7enc-rdo-integration \
#     https://github.com/noisethanks/compressonator.git compressonator
#   git clone https://github.com/richgel999/bc7enc_rdo.git
#
#   # External dependencies. external/CMakeLists.txt includes glm and
#   # rapidxml for any CLI build, whatever OPTION_CMP_OPENGL and
#   # OPTION_CMP_QT say, so this step is not optional. On macOS it ends in
#   # a traceback: the last item is an OpenEXR tarball from a plain-HTTP
#   # host that no longer answers. OPTION_BUILD_EXR is OFF here, so that
#   # one is not needed. The git clones before it are the ones that count.
#   (cd compressonator && python3 build/fetch_dependencies.py)
#
#   # bc7enc_rdo#29: five one-line rewrites in bc7e.ispc, still unmerged.
#   # Required for any arm64 ispc host. See the ISPC note below for why.
#   (cd bc7enc_rdo && gh pr diff 29 --repo richgel999/bc7enc_rdo | git apply)
#
#   # ISPC v1.31.0, 108 MB. Take the arm64 package on Apple Silicon: it
#   # cross-compiles the x86_64 slice, so Rosetta 2 is not needed and the
#   # 222 MB universal package buys nothing here.
#   curl -L -o ispc.tar.gz \
#     https://github.com/ispc/ispc/releases/download/v1.31.0/ispc-v1.31.0-macOS.arm64.tar.gz
#   tar xzf ispc.tar.gz
#   mkdir -p tools/ispc && mv ispc-v1.31.0-macOS.arm64 tools/ispc/macos
#
#   brew install cmake
#
#   compressonator/tools/macos/build_flavor.sh batch universal
#
# That leaves the layout every one of these scripts expects:
#
#   ~/dev/cmp/
#   |-- common/lib/ext/          <- written by build/fetch_dependencies.py
#   |-- compressonator/          <- this repository
#   |-- bc7enc_rdo/              <- with bc7enc_rdo#29 applied
#   `-- tools/ispc/macos/bin/ispc
#
# If your layout differs, skip the moves and point at the two directly:
#
#   ISPC=~/dev/cmp/ispc-v1.31.0-macOS.arm64/bin/ispc \
#   BC7ENC=~/dev/cmp/bc7enc_rdo \
#     compressonator/tools/macos/build_flavor.sh batch universal
#
# OUTPUT= writes the joined binary straight to its destination, which saves
# a copy step for a consumer such as ATAK:
#
#   OUTPUT=~/dev/atak/internal/tools/bin/compressonator-bc7e-macos \
#     compressonator/tools/macos/build_flavor.sh batch universal
#
# While iterating, build one slice. `arm64` is the default, so plain
# `build_flavor.sh` does it, and that skips lipo and codesign entirely.
#
# Environment overrides (all optional):
#   CMAKE=             cmake binary. Default: the first of `cmake` on PATH,
#                      /Applications/CMake.app/Contents/bin/cmake, or the
#                      Homebrew cmake prefix.
#   ISPC=              ispc binary. Default: $ROOT/tools/ispc/macos/bin/ispc.
#   BC7ENC=            bc7enc_rdo checkout. Default: $ROOT/bc7enc_rdo.
#   JOBS=              build parallelism. Default: sysctl -n hw.ncpu.
#   CODESIGN_IDENTITY= identity for `universal`. Default: `-`, ad-hoc.
#   OUTPUT=            path `universal` writes the joined binary to.
#
# Prereqs (each is checked, and each failure names its own remedy):
#   - Xcode Command Line Tools. Probed with `xcrun --find clang++`, not
#     `command -v clang`: /usr/bin/{clang,make,lipo,otool} are hard links to
#     one xcrun shim that ships with base macOS whether or not the tools are
#     installed, so `command -v` proves nothing. `xcode-select -p` is no
#     better — it echoes DEVELOPER_DIR and exits 0 even when that points at
#     a directory that no longer exists.
#   - macOS ISPC v1.31.0. Default location is tools/ispc/macos/bin/ispc,
#     relative to the repo root that holds compressonator/ and bc7enc_rdo/
#     side by side; override with ISPC=.
#
#     ISPC host architecture matters twice over.
#
#     Correctness: aarch64 *hosts* of ispc 1.19 and later silently
#     miscompile `--` on a varying unsigned int into a no-op (ispc#3882),
#     which corrupts bc7e.ispc's bit packing (bc7enc_rdo#23). The damage is
#     not confined to arm64 output — an arm64 ispc host produces corrupt
#     encoders for the x86_64 target too. With assertions enabled the
#     failure surfaces as "bc7e.ispc:2890: Assertion failed: *pCur_ofs
#     <= 128"; this recipe passes --opt=disable-assertions, so it would
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
#
#     Capability: which architectures an ispc can emit depends on the LLVM
#     it was built against, not on its own Mach-O slice. The official macOS
#     packages carry both backends, so the arm64 one cross-compiles the
#     x86_64 slice fine (measured, v1.31.0). Homebrew's arm64 bottle does
#     not: it links llvm@22 and rejects `--arch=x86-64` outright. bc7enc_rdo#29
#     does not change that — it fixes correctness, not capability. The
#     preflight below compiles a throwaway kernel for each target before
#     starting any build, so this fails in the first second instead of
#     minutes into `make`.
#     https://github.com/ispc/ispc/issues/3882
#     https://github.com/richgel999/bc7enc_rdo/issues/23
#     https://github.com/richgel999/bc7enc_rdo/pull/29
#   - bc7enc_rdo checkout at ../bc7enc_rdo, or BC7ENC=.
#   - CMake 3.13 or later, for -S/-B and `--build --parallel`. CMake itself
#     puts nothing on PATH when installed as CMake.app, which is why the
#     discovery below looks in /Applications.
#
# How this differs from the Linux recipe, and why:
#   - No -static. Darwin has no static libSystem, so a fully static link is
#     not available. The binary links only OS-shipped libraries (libSystem,
#     libc++ and libz), which need no install — the same practical result as
#     the Windows build's 3 OS DLLs.
#   - CMAKE_OSX_ARCHITECTURES selects the slice. An arm64 host builds the
#     x86_64 slice by cross-compiling with clang; the result runs under
#     Rosetta 2. ISPC is the part that does not cross-compile for free.
#   - The bc7e ISPC target list follows the architecture: the four
#     SSE/AVX targets for x86_64, NEON for arm64.
#   - OPTION_BUILD_EXR is OFF on both, as on Linux.

set -euo pipefail

ISPC_PINNED=1.31.0
CODESIGN_ID_NAME=compressonatorcli   # matches the identifier on the shipped binary

usage() {
  cat <<EOF
usage: ${0##*/} [off|unbatched|batch] [arm64|x86_64|universal]

  flavor  off        stock Compressonator BC7          -> build_cli_off
          unbatched  bc7e.ispc, per-block              -> build_cli
          batch      bc7e.ispc, SIMD-batched           -> build_cli_batch  (default)

  arch    arm64      one slice                                             (default)
          x86_64     one slice
          universal  both slices, joined with lipo and ad-hoc signed

environment overrides:
  CMAKE=  ISPC=  BC7ENC=  JOBS=  CODESIGN_IDENTITY=  OUTPUT=

first-time setup, and the directory layout this expects: see the comment
block at the top of $0
EOF
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# `(( ))` returns 1 when the expression evaluates to 0, which would abort the
# script under `set -e` if used on a line of its own. Safe as a || condition.
(( $# <= 2 )) || { echo "error: unexpected argument '$3'" >&2; usage >&2; exit 2; }

FLAVOR="${1:-batch}"
ARCH="${2:-arm64}"

case "$FLAVOR" in
  off)       USE_RDO=OFF; USE_BATCH=OFF; BUILD_BASE=build_cli_off   ;;
  unbatched) USE_RDO=ON;  USE_BATCH=OFF; BUILD_BASE=build_cli       ;;
  batch)     USE_RDO=ON;  USE_BATCH=ON;  BUILD_BASE=build_cli_batch ;;
  arm64|x86_64|universal)
    echo "error: '$FLAVOR' is an arch, and arch is the second argument." >&2
    echo "       Did you mean: ${0##*/} batch $FLAVOR" >&2
    exit 2 ;;
  *) echo "error: unknown flavor '$FLAVOR'" >&2; usage >&2; exit 2 ;;
esac

case "$ARCH" in
  x86_64|arm64) SLICES=( "$ARCH" ) ;;
  universal)    SLICES=( x86_64 arm64 ) ;;
  *) echo "error: unknown arch '$ARCH'" >&2; usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"        # compressonator/ root
ROOT="$(cd "$SRC/.." && pwd)"                 # repo root (holds tools/, bc7enc_rdo/)
ISPC="${ISPC:-$ROOT/tools/ispc/macos/bin/ispc}"
BC7ENC="${BC7ENC:-$ROOT/bc7enc_rdo}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

TMPDIR_PROBE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PROBE"' EXIT

# CMake.app does not add itself to PATH unless the user runs its
# "Install Command Line Tools" menu item, so look where it actually lands.
if [[ -z "${CMAKE:-}" ]]; then
  for candidate in cmake \
                   /Applications/CMake.app/Contents/bin/cmake \
                   "$(brew --prefix cmake 2>/dev/null)/bin/cmake"; do
    if command -v "$candidate" >/dev/null 2>&1; then CMAKE="$candidate"; break; fi
  done
fi
CMAKE="${CMAKE:-cmake}"

# A failed command substitution in argument position is invisible to `set -e`,
# and cmake does not reject `--parallel ""` — it maps to a bare `-j`, which
# GNU Make reads as "no limit". Compute it here so a failure is visible.
if [[ -z "${JOBS:-}" ]]; then
  if ! JOBS="$(sysctl -n hw.ncpu 2>/dev/null)" || [[ -z "$JOBS" ]]; then
    JOBS=4
    echo "WARNING: could not read hw.ncpu; falling back to -j$JOBS" >&2
  fi
fi

arch_flags() {   # $1 = x86_64|arm64 -> ISPC_ARCH, ISPC_TARGETS, DEPLOY_TARGET
  case "$1" in
    x86_64) ISPC_ARCH=x86-64;  ISPC_TARGETS=sse2,sse4,avx,avx2; DEPLOY_TARGET=10.15 ;;
    arm64)  ISPC_ARCH=aarch64; ISPC_TARGETS=neon-i32x4;         DEPLOY_TARGET=11.0  ;;
  esac
}

echo "Flavor      : $FLAVOR"
echo "Arch        : $ARCH"
echo "RepoRoot    : $ROOT"
echo "Source      : $SRC"
echo "ISPC        : $ISPC"
echo "bc7enc_rdo  : $BC7ENC"
echo "CMake       : $CMAKE"
echo "Jobs        : $JOBS"

# toolchain

# Skip when the operator has deliberately selected a non-Xcode compiler.
if [[ -z "${CC:-}${CXX:-}" ]]; then
  xcrun --find clang++ >/dev/null 2>&1 || {
    echo "ERROR: no usable Xcode toolchain." >&2
    echo "       Install the Command Line Tools:  xcode-select --install" >&2
    echo "       Or select an Xcode:  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
  }
fi

command -v "$CMAKE" >/dev/null || {
  echo "ERROR: cmake not found: $CMAKE" >&2
  echo "       brew install cmake" >&2
  echo "       or CMAKE=/Applications/CMake.app/Contents/bin/cmake $0 $*" >&2
  exit 1
}

# external/CMakeLists.txt gates glew/glm/opengl/qt5/rapidxml/vulkan on
# OPTION_BUILD_APPS_CMP_CLI, so a CLI-only build still needs the common/ tree
# that build/fetch_dependencies.py writes. Without it, configure dies ~30
# lines into unrelated output with "add_subdirectory given source ... which is
# not an existing directory". Check the two the CLI actually resolves.
for dep in glm rapidxml; do
  [[ -d "$ROOT/common/lib/ext/$dep" ]] || {
    echo "ERROR: missing external dependency: $ROOT/common/lib/ext/$dep" >&2
    echo "       cd $SRC && python3 build/fetch_dependencies.py" >&2
    echo "       Its last step downloads an OpenEXR tarball from a dead host" >&2
    echo "       and ends in a traceback. OPTION_BUILD_EXR is OFF here, so" >&2
    echo "       that failure is harmless; the git clones are what matter." >&2
    exit 1
  }
done

# ISPC

if [[ "$USE_RDO" == "ON" ]]; then
  [[ -x "$ISPC" ]] || {
    echo "ERROR: ISPC not executable at $ISPC" >&2
    echo "       Set ISPC=/path/to/ispc, or unpack the official macOS ISPC" >&2
    echo "       v$ISPC_PINNED package under $ROOT/tools/ispc/macos/." >&2
    if on_path="$(command -v ispc 2>/dev/null)"; then
      echo "       Note: $on_path is on PATH." >&2
      echo "       Homebrew's ispc links llvm@22 and cannot emit x86-64; the" >&2
      echo "       official macOS packages carry both backends." >&2
    fi
    exit 1
  }

  # -x tests a permission bit and nothing else. An x86_64 ispc on Apple
  # Silicon passes it and still will not exec without Rosetta 2. Running it
  # once also catches Gatekeeper quarantine on a downloaded tarball.
  if ! ispc_banner="$("$ISPC" --version 2>&1)"; then
    echo "ERROR: $ISPC is present but will not run:" >&2
    printf '%s\n' "$ispc_banner" | sed 's/^/       /' >&2
    if [[ "$(uname -m)" == arm64 ]] \
       && file -b "$ISPC" | grep -q x86_64 \
       && ! file -b "$ISPC" | grep -q arm64; then
      echo "       That is an x86_64-only ispc on an arm64 host. Install" >&2
      echo "       Rosetta 2 once:" >&2
      echo "         softwareupdate --install-rosetta --agree-to-license" >&2
    else
      echo "       Check quarantine:  xattr -dr com.apple.quarantine <ispc dir>" >&2
    fi
    exit 1
  fi

  ispc_ver="$(sed -n 's/.*ISPC), \([0-9][0-9.]*\).*/\1/p' <<<"$ispc_banner")"
  echo "ISPC ver    : ${ispc_ver:-unparsed}"
  if [[ -z "$ispc_ver" ]]; then
    echo "WARNING: could not parse a version from: $ispc_banner" >&2
  elif [[ "$ispc_ver" != "$ISPC_PINNED" ]]; then
    # A warning, not a failure. The real requirement is capability, tested
    # below; pinning the string would block anyone deliberately trying 1.32.
    echo "WARNING: ispc $ispc_ver, but readme.md pins $ISPC_PINNED." >&2
  fi

  [[ -f "$BC7ENC/bc7e.ispc" ]] || {
    echo "ERROR: bc7enc_rdo checkout missing at $BC7ENC (need bc7e.ispc)" >&2
    echo "       git clone https://github.com/richgel999/bc7enc_rdo $BC7ENC" >&2
    echo "       or set BC7ENC=/path/to/bc7enc_rdo" >&2
    exit 1
  }

  # Which architecture this ispc EXECUTES as. `file -b` is the wrong tool: on a
  # fat binary it repeats the pathname on each continuation line, so an ispc
  # stored under a directory named arm64 matches; it prints both arch names for
  # a universal package, so the official one gets refused on an Intel Mac; and
  # it says "POSIX shell script" for a wrapper, which matches nothing at all.
  # `lipo -archs` prints slice names and nothing else.
  ispc_host_arch() {
    local archs host
    host="$(uname -m)"
    command -v lipo >/dev/null 2>&1 || { echo "$host"; return; }
    # An unguarded assignment would abort the script under `set -e` when $ISPC
    # is not Mach-O ("lipo: not a mach-o"). Degrade to the host instead.
    archs="$(lipo -archs "$1" 2>/dev/null)" || { echo "$host"; return; }
    # Only an Apple Silicon host can execute an arm64* slice, and it prefers
    # that slice. The substring match is deliberate: arm64e and arm64_32 are
    # aarch64 hosts too, and carry the same ispc#3882 miscompile.
    if [[ "$host" == arm64 && "$archs" == *arm64* ]]; then echo arm64; else echo x86_64; fi
  }

  # Test ispc#3882 directly rather than inferring it from the host architecture.
  # Returns 0 = miscompiles, 1 = correct, 2 = could not be tested.
  # Compiled for the arch ispc RUNS as, not the arch it is asked to emit: the
  # defect is a property of the compiler host, and probing at the target arch
  # would fail outright whenever the host cannot emit that target, turning a
  # misconfiguration into a fake miscompile report.
  ispc_3882_probe() {
    local harch="$1" a t c d="$TMPDIR_PROBE/mc"
    case "$harch" in
      arm64)  a=aarch64; t=neon-i32x4; c=arm64  ;;
      x86_64) a=x86-64;  t=sse4;       c=x86_64 ;;
      *) return 2 ;;
    esac
    mkdir -p "$d"
    cat > "$d/p.ispc" <<'ISPC_PROBE'
export void probe(uniform unsigned int out[]) {
    varying unsigned int x = (unsigned int)programIndex + 5;
    x--;
    out[programIndex] = x;
}
ISPC_PROBE
    cat > "$d/m.cpp" <<'CPP_PROBE'
#include "p_ispc.h"
int main() { unsigned int o[64]; ispc::probe(o); return o[0] == 4 ? 0 : 1; }
CPP_PROBE
    # Same flags the real build uses. --opt=disable-assertions matters: with
    # assertions the miscompile aborts loudly, which is not what ships.
    "$ISPC" --arch="$a" --target="$t" --opt=disable-assertions \
      -o "$d/p.o" -h "$d/p_ispc.h" "$d/p.ispc" >/dev/null 2>&1 || return 2
    # /usr/bin/clang++, not $(xcrun --find clang++): the bare path resolves no
    # sysroot and cannot find <cstdio>.
    /usr/bin/clang++ -arch "$c" -I"$d" -o "$d/probe" "$d/m.cpp" "$d/p.o" \
      >/dev/null 2>&1 || return 2
    "$d/probe" >/dev/null 2>&1 && return 1 || return 0
  }

  ISPC_HOST="$(ispc_host_arch "$ISPC")"
  echo "ISPC host   : executes as $ISPC_HOST"

  # bc7enc_rdo#29 rewrites the affected `x--` sites as `x -= 1`. Match any bare
  # decrement statement on a plain identifier, rather than the three names the
  # current upstream file happens to use. Member and array lvalues are excluded
  # on purpose: bc7e.ispc's other decrements are `pTrialMinColor->m_c[i]--` on a
  # signed int32_t, which ispc#3882 does not affect, and #29 leaves them alone.
  # This is still a text heuristic and cannot tell signed from unsigned.
  BC7E_PATCHED=no
  grep -qE '(^|[^_[:alnum:].>])[_[:alpha:]][_[:alnum:]]*[[:space:]]*--[[:space:]]*;' \
    "$BC7ENC/bc7e.ispc" || BC7E_PATCHED=yes

  MISCOMPILES=0
  ispc_3882_probe "$ISPC_HOST" || MISCOMPILES=$?
  case "$MISCOMPILES" in
    0) echo "ispc#3882   : PRESENT in $ISPC (bc7e.ispc patched: $BC7E_PATCHED)" ;;
    1) echo "ispc#3882   : not present in $ISPC" ;;
    *) echo "ispc#3882   : could not be tested; falling back to the source check" ;;
  esac

  # Accept when the compiler is proven good, or when the source no longer
  # depends on the broken construct. Refuse only the combination that is
  # actually unsafe. An untestable probe falls back to the host-arch rule.
  if [[ "$MISCOMPILES" == 0 && "$BC7E_PATCHED" == no ]] \
     || [[ "$MISCOMPILES" == 2 && "$ISPC_HOST" == arm64 && "$BC7E_PATCHED" == no ]]; then
    echo "ERROR: $ISPC drops '--' on varying unsigned values (ispc#3882), and" >&2
    echo "       $BC7ENC/bc7e.ispc still uses it. That combination miscompiles" >&2
    echo "       silently (bc7enc_rdo#23) and corrupts BC7 output for every" >&2
    echo "       target, not only this host's." >&2
    echo "       Fix either side:" >&2
    echo "         (cd $BC7ENC && gh pr diff 29 --repo richgel999/bc7enc_rdo | git apply)" >&2
    echo "       or use an x86_64 ispc, which is unaffected." >&2
    exit 1
  fi
  if [[ "$BC7E_PATCHED" == yes ]]; then
    echo "Note: bc7e.ispc carries the bc7enc_rdo#29 rewrite."
  fi

  # Capability preflight, for every slice this run will build, before any of
  # them starts. cmp_core/CMakeLists.txt hands --arch/--target to ispc from an
  # add_custom_command, so without this an incapable ispc is only discovered
  # minutes into `make` — and in `universal` mode only after a full first
  # slice has been built and thrown away.
  #
  # The probe writes into a temp dir, never /dev/null: ispc derives one output
  # file per target from -o, so a multi-target list against /dev/null fails
  # with `Cannot open output file "/dev/null_sse2"` even on a healthy ispc.
  printf 'export void p(uniform int a[]) { a[programIndex] = programIndex; }\n' \
    > "$TMPDIR_PROBE/probe.ispc"
  for slice in "${SLICES[@]}"; do
    arch_flags "$slice"
    if ! "$ISPC" --arch="$ISPC_ARCH" --target="$ISPC_TARGETS" \
         -o "$TMPDIR_PROBE/probe_$slice.o" -h "$TMPDIR_PROBE/probe_$slice.h" \
         "$TMPDIR_PROBE/probe.ispc" 2>"$TMPDIR_PROBE/err_$slice"; then
      echo "ERROR: $ISPC cannot emit --arch=$ISPC_ARCH --target=$ISPC_TARGETS" >&2
      sed 's/^/       /' "$TMPDIR_PROBE/err_$slice" >&2
      echo "       bc7enc_rdo#29 fixes correctness, not capability: this is the" >&2
      echo "       LLVM behind ispc, not its own slice. Use an official macOS" >&2
      echo "       package of ISPC v$ISPC_PINNED, which carries both backends." >&2
      exit 1
    fi
    echo "ISPC probe  : $slice ok (--arch=$ISPC_ARCH --target=$ISPC_TARGETS)"
  done
fi

# build

build_slice() {   # $1 = x86_64|arm64 -> writes $BUILD/bin/compressonatorcli-bin
  local slice="$1" build cmake_args
  arch_flags "$slice"
  build="$SRC/${BUILD_BASE}_macos_${slice}"

  echo
  echo "=== $slice ==="
  echo "Build       : $build"
  echo "ISPC target : --arch=$ISPC_ARCH --target=$ISPC_TARGETS"
  echo "Deployment  : $DEPLOY_TARGET"

  # Clean build dir so stale cache entries can't shadow the flags below.
  rm -rf "$build"

  cmake_args=(
    -S "$SRC"
    -B "$build"
    -G "Unix Makefiles"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="$slice"
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
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  )

  if [[ "$USE_RDO" == "ON" ]]; then
    cmake_args+=(
      -DBC7ENC_RDO_ISPC="$ISPC"
      -DBC7ENC_RDO_DIR="$BC7ENC"
      -DBC7ENC_RDO_ISPC_ARCH="$ISPC_ARCH"
      -DBC7ENC_RDO_ISPC_TARGETS="$ISPC_TARGETS"
    )
  fi

  "$CMAKE" "${cmake_args[@]}"

  # Assert the C++17 branch before spending minutes on the build. The C++
  # feature probe used to skip Apple hosts and leave them on C++11, which
  # disables the std::filesystem path in cmp_fileio.cpp. CMP_GetJustFileExt
  # then returns "dds" instead of ".dds", IsDestinationUnCompressed() answers
  # true for every destination, and the CLI writes a DECOMPRESSED DDS at 4x
  # the expected size while reporting success and exit 0.
  # CMAKE_CXX_STANDARD is a plain set(), never CACHE, so CMakeCache.txt cannot
  # answer this. The compile database can.
  local cc_json="$build/compile_commands.json"
  # Test for the file first: grep on a missing file exits 2, and `!` would
  # invert that into a confident report of the wrong cause.
  [[ -f "$cc_json" ]] || {
    echo "ERROR: $cc_json was not written. The check itself broke, not the build." >&2
    exit 1
  }
  grep -q -- '-D_CMP_CPP17_=1' "$cc_json" || {
    echo "ERROR: configure did not define _CMP_CPP17_ (CMakeLists.txt:281)." >&2
    echo "       This build would write decompressed DDS and report success." >&2
    exit 1
  }
  echo "C++17       : _CMP_CPP17_ defined"

  "$CMAKE" --build "$build" --parallel "$JOBS"

  local bin="$build/bin/compressonatorcli-bin"
  [[ -f "$bin" ]] || {
    echo "Build reported success but binary not at expected path: $bin" >&2
    exit 1
  }

  # The Linux sibling decides on its critical property rather than printing it.
  # Do the same, but fail rather than warn: this artifact gets embedded and
  # shipped, so a library that exists only on the build machine is not a
  # warning, it is a binary that dies with a dyld error on every user's box.
  # Match dependency lines by their leading tab, not `tail -n +2`: otool prints
  # one unindented header per architecture, so tail is wrong on a fat binary.
  local deps bad got_arch got_min
  deps="$(otool -L "$bin" | awk '/^\t/{print $1}' | sort -u)"
  bad="$(grep -vE '^(/usr/lib/|/System/Library/)' <<<"$deps" || true)"
  if [[ -n "$bad" ]]; then
    echo "ERROR: $slice slice links non-OS libraries and will not run elsewhere:" >&2
    printf '%s\n' "$bad" | sed 's/^/    /' >&2
    exit 1
  fi

  got_arch="$(lipo -archs "$bin")"
  [[ "$got_arch" == "$slice" ]] || {
    echo "ERROR: asked for $slice, built $got_arch." >&2
    exit 1
  }

  # The toolchain silently clamps a deployment target it considers too old:
  # clang++ -arch arm64 -mmacosx-version-min=10.15 yields minos 11.0, exit 0,
  # no diagnostic. Assert what actually landed in LC_BUILD_VERSION.
  got_min="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [[ "$got_min" == "$DEPLOY_TARGET" ]] || {
    echo "ERROR: $slice slice carries minos '$got_min', expected $DEPLOY_TARGET." >&2
    echo "       An empty value means the check broke; otherwise the toolchain" >&2
    echo "       clamped the deployment target." >&2
    exit 1
  }

  echo "SLICE OK: $bin"
  file "$bin" | sed 's/^/  file: /'
  echo "  arch     : $got_arch"
  echo "  minos    : $got_min"
  echo "  otool -L : OS-shipped libraries only"
  printf '%s\n' "$deps" | sed 's/^/    /'
}

for slice in "${SLICES[@]}"; do
  build_slice "$slice"
done

if [[ "$ARCH" != universal ]]; then
  exit 0
fi

# join and sign

X86="$SRC/${BUILD_BASE}_macos_x86_64/bin/compressonatorcli-bin"
ARM="$SRC/${BUILD_BASE}_macos_arm64/bin/compressonatorcli-bin"
OUT="${OUTPUT:-$SRC/${BUILD_BASE}_macos_universal/compressonatorcli-bin}"

echo
echo "=== universal ==="
mkdir -p "$(dirname "$OUT")"   # lipo does not create parent directories
rm -f "$OUT"                   # never let a stale join survive a failed rebuild
lipo -create -output "$OUT" "$X86" "$ARM"

# --force is required: a second `codesign --sign -` over an already-signed
# file exits 1, which would kill the script on every rebuild.
# --identifier is required to reproduce the shipped artifact. Without it,
# codesign derives the identifier from the file name and appends a content
# hash, so it changes on every build.
codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$CODESIGN_ID_NAME" "$OUT"
codesign --verify --strict --all-architectures "$OUT"

got_archs="$(lipo -archs "$OUT")"
[[ "$got_archs" == "x86_64 arm64" ]] || {
  echo "ERROR: expected 'x86_64 arm64' in $OUT, got '$got_archs'" >&2
  exit 1
}

echo
echo "UNIVERSAL OK: $OUT"
file "$OUT" | sed 's/^/  file: /'
codesign -dv "$OUT" 2>&1 | sed 's/^/  /'
shasum -a 256 "$OUT" | sed 's/^/  /'
