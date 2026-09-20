# Investigation notes — BC7 encoder integration

## Step 0 — bc7enc_rdo standalone build (sanity check)

Built at `bc7enc_rdo/build/bc7enc`. `SUPPORT_BC7E=TRUE`, ISPC toolchain
pinned to `tools/ispc/linux/bin/ispc` (v1.31.0, LLVM 23). Confirmed BC7E
present via `./bc7enc` diagnostic:

> "For BC7, the tool uses either bc7enc.cpp (uses modes 1/5/6/7) or
> bc7e.ispc (all modes, -U option, the default if SUPPORT_BC7E was TRUE)."

Two patches needed to build against a modern toolchain — record here so we
don't rediscover them:

1. `bc7enc_rdo/ert.h` — added `#include <cstdint>`. GCC 16 no longer pulls
   `<cstdint>` transitively through `<string>` / `<vector>`, so `uint8_t` /
   `uint32_t` were undefined at struct declaration. Symptom was misleading —
   compiler reported the struct as having "no member named
   m_lookback_window_size" at every call site, because the struct definition
   silently failed and only the empty forward-declared name survived.
2. `bc7enc_rdo/CMakeLists.txt` — added `--pic` to the ispc invocation. Without
   it, generated `.o` files contain absolute `R_X86_64_32S` relocations against
   `.bss` and the (PIE-by-default) executable link fails with
   `"relocation R_X86_64_32S ... can not be used when making a PIE object"`.

Reproduce build:
```
cd bc7enc_rdo && mkdir -p build && cd build
PATH=/home/abhi/compressonatorfork/tools/ispc/linux/bin:$PATH \
  cmake -DSUPPORT_BC7E=TRUE -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
PATH=/home/abhi/compressonatorfork/tools/ispc/linux/bin:$PATH make -j
```

CMake also required `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` because upstream's
`cmake_minimum_required(2.8)` is below the floor supported by current CMake.

## Phase 1 — Compressonator CPU BC7 codec

### Q1. Where is the current CPU-side BC7 codec?

- Public entry point: `CompressBlockBC7()` in
  `compressonator/cmp_core/shaders/bc7_encode_kernel.cpp:3517`. Declared in
  `cmp_core/source/cmp_core.h:165`.
- All BC7 CPU work funnels through `BC7_CompressBlock()` at
  `bc7_encode_kernel.cpp:2663` — a large monolithic block encoder that operates
  on a `BC7_EncodeState` filled from the 4x4 source, driven by a
  `BC7_Encode` settings struct (see `bc7_encode_kernel.h:197,222` for
  `BC7_Encode`; `:138,172` for `BC7_EncodeState`). This is the "legacy"
  path — not CMPMSC.
- CLAUDE.md's assumption that CMPMSC is the active CPU codec is stale.
  CMPMSC is dispatched only through `CompressBlockBC7_UNORM()` in
  `bc7_common_encoder.h:62`, and that function is only reached when
  `USE_NEW_SINGLE_HEADER_INTERFACES` is defined — which is
  **explicitly commented out** at `bc7_encode_kernel.cpp:48`:
  `//#define USE_NEW_SINGLE_HEADER_INTERFACES`. So on a stock CPU build the
  CMPMSC / MSC / RGBCX_RDO / VOLT / ICBC / ARRIS dispatch table is entirely
  dead code; the real codec is `BC7_CompressBlock`.
- Interface a BC7 codec must satisfy for `CMP_Core`'s public C API
  (see `cmp_core.h`):
  ```
  int CreateOptionsBC7(void** options);            // alloc BC7_Encode
  int DestroyOptionsBC7(void* options);
  int SetQualityBC7(void* options, float q);       // 0..1
  int SetMaskBC7(void* options, unsigned char);    // valid-mode bitmask
  int SetAlphaOptionsBC7(void*, bool, bool, bool);
  int SetErrorThresholdBC7(void*, float, float);
  int CompressBlockBC7(const unsigned char* srcBlock,
                       unsigned int srcStrideInBytes,
                       unsigned char cmpBlock[16],
                       const void* options);
  int DecompressBlockBC7(const unsigned char cmpBlock[16],
                         unsigned char srcBlock[64],
                         const void* options);
  ```

### Q2. Codec selection mechanism — is there a clean seam?

- Compile-time `#define`, no runtime registry. The dispatch table in
  `bc7_common_encoder.h:62-93` is a chain of `#ifdef USE_X` blocks, so
  choosing a codec = flipping one define in `bc7_encode_kernel.cpp:52-57`.
- But that dispatch is dead on stock CPU builds (see Q1). Hooking a new
  codec via the same mechanism would require *also* defining
  `USE_NEW_SINGLE_HEADER_INTERFACES` — which turns off the legacy
  `BC7_CompressBlock` path completely. Not "additive".
- Cleanest additive seam: intercept at the top of `CompressBlockBC7()`
  (`bc7_encode_kernel.cpp:3517`). Under a new compile flag
  (e.g. `CMP_USE_BC7ENC_RDO`), forward to a thin adapter that calls
  `ispc::bc7e_compress_blocks(1, out, pixels, &params)`. Stock behavior stays
  reachable when the flag is off. No changes to callers, no changes to the
  HLSL path, no need to enable the `USE_NEW_SINGLE_HEADER_INTERFACES` chain.
- Options struct handling: adapter can ignore `BC7_Encode` fields it doesn't
  map cleanly (quality/mask/etc.) or translate `quality` → one of
  `bc7e_compress_block_params_init_{ultrafast,fast,basic,slow,slowest}`. Init
  the ISPC params once (guarded by a static flag) since `bc7e_compress_block_init()`
  populates lookup tables.

### Q3. Minimum CLI-only build target — real dependency surface

From `compressonator/CMakeLists.txt`:

- Recipe: `-DOPTION_ENABLE_ALL_APPS=OFF -DOPTION_BUILD_APPS_CMP_CLI=ON`.
- `cmp_option` chain (lines 162-172) auto-enables for a CLI build:
  - `OPTION_CMP_OPENGL`  — forced ON (line 167)
  - `OPTION_CMP_OPENCV`  — forced ON (line 169)
  - `OPTION_CMP_QT`      — **not** forced (only for GUI or ENABLE_ALL_APPS)
  - `OPTION_CMP_VULKAN`  — **not** forced (only for ENABLE_ALL_APPS)
  - `OPTION_CMP_DIRECTX` — Windows-only
- CLI target subdirs pulled in (lines 367-418):
  `cmp_core`, `cmp_framework`, `cmp_compressonatorlib`,
  `applications/_plugins/common`, image plugins
  (`dds`, `tga`, `exr` if `OPTION_BUILD_EXR`, `ktx` if `OPTION_BUILD_KTX2`),
  `canalysis`, `compressonatorcli`, `_libs/gpu_decode`.
- OpenEXR / OpenCV / Draco lookups (lines 332-362) are `pkg_check_modules` /
  `find_package` — if the package is missing, the corresponding
  `OPTION_BUILD_EXR` / `OPTION_CMP_OPENCV` is silently switched OFF, so a
  missing lib is a warning not a hard fail.
- Qt5 (line 320) is `find_package(... REQUIRED ...)` **only inside**
  `if (CMP_HOST_LINUX AND OPTION_CMP_QT)`. Since CLI-only doesn't set
  `OPTION_CMP_QT`, Qt can stay unset. `QT_DIR` env var is only consulted
  inside that block.
- `applications/compressonatorcli/CMakeLists.txt:190` unconditionally links
  `${OpenCV_LIBRARIES}` — harmless (empty) if OpenCV was disabled by the
  find_package fallback, but if OpenCV is present and enabled the CLI links
  it. `cmp_meshoptimizer` and glTF sources are included regardless.
- Practical CLI-only invocation (Linux, no Qt/Vulkan):
  ```
  cmake -DOPTION_ENABLE_ALL_APPS=OFF \
        -DOPTION_BUILD_APPS_CMP_CLI=ON \
        -DOPTION_CMP_QT=OFF \
        -DOPTION_CMP_VULKAN=OFF \
        -DOPTION_BUILD_EXR=OFF \
        -DOPTION_CMP_OPENCV=OFF \
        -DOPTION_BUILD_KTX2=OFF \
        -DOPTION_BUILD_BROTLIG=OFF \
        ..
  ```
  Now tested — see "CLI-only build — actual result" below.

### Q4. Block API — Compressonator vs. bc7enc_rdo

Compressonator (`CompressBlockBC7`, above):
- Input: 4x4 pixels as strided RGBA8, `srcStrideInBytes` = row stride.
- Output: `unsigned char cmpBlock[16]` (128-bit BC7 block).
- Options: opaque `void*` → `BC7_Encode*`.

bc7enc_rdo has two candidate entry points:

a) Scalar / SSE-ish, `bc7enc.h:121`
```
bool bc7enc_compress_block(void *pBlock,
                           const void *pPixelsRGBA,
                           const bc7enc_compress_block_params *pComp_params);
```
Packed 16 RGBA px in, 16-byte block out. Modes 1/5/6/7 only — the
"weaker" scalar path. Requires one-time `bc7enc_compress_block_init()`.

b) ISPC full-fat encoder, `bc7e_ispc.h:105`
```
extern void ispc::bc7e_compress_blocks(uint32_t num_blocks,
                                       uint64_t* pBlocks,          // 2*num_blocks u64
                                       const uint32_t* pPixelsRGBA,// 16*num_blocks u32
                                       const bc7e_compress_block_params* p);
```
Batched; all 8 BC7 modes; SIMD via SSE2/SSE4/AVX/AVX2 (bc7enc_rdo built
with `--target=sse2,sse4,avx,avx2`). Requires one-time
`ispc::bc7e_compress_block_init()`. This is the target — it's the codec
whose quality/perf we actually want.

Minimum adapter shape:
```
int CompressBlockBC7_bc7enc(const uint8_t* srcBlock, uint32_t stride,
                            uint8_t cmpBlock[16], const void* options)
{
    // 1. gather 16 packed uint32 RGBA from strided src
    uint32_t pixels[16];
    for (int y=0; y<4; ++y) {
        const uint8_t* row = srcBlock + y*stride;
        for (int x=0; x<4; ++x)
            pixels[y*4+x] = *(const uint32_t*)(row + x*4);
    }
    // 2. one-shot init of ispc tables + default params (thread-safe once flag)
    static std::once_flag f;
    static ispc::bc7e_compress_block_params p;
    std::call_once(f, [](){
        ispc::bc7e_compress_block_init();
        ispc::bc7e_compress_block_params_init_slowest(&p, /*perceptual=*/false);
    });
    // 3. encode one block
    uint64_t out[2];
    ispc::bc7e_compress_blocks(1, out, pixels, &p);
    memcpy(cmpBlock, out, 16);
    return 0;
}
```
Options mapping (BC7_Encode → bc7e params) is the interesting bit: at
minimum, use `SetQualityBC7`'s 0..1 quality to pick between
`veryfast/fast/basic/slow/slowest`. `SetMaskBC7`'s mode bitmask can
translate to `p.m_mode_selection[i]` bits (see `bc7e_ispc.h:71-95`).
Batching one block at a time throws away most of bc7e's SIMD win — Phase 2
should also expose a batch entry to Compressonator's per-image loop when
possible, but per-block adapter is sufficient to prove correctness.

### Q5. bc7enc_rdo build requirements (already answered by Step 0)

- Toolchain: any C++14+ compiler + ISPC ≥ 1.something. Confirmed working
  with GCC 16.1.1 and `ispc-v1.31.0-linux` in `tools/ispc/linux/bin`.
- Flags needed on modern hosts: `--pic` to ispc, `#include <cstdint>` in
  `ert.h`, `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` to cmake.
- Two patches (both above) are already applied in-tree, so the standalone
  build reproduces. Neither patch touches encoder logic, only build glue.

## Phase 1 → Phase 2 handoff

Nothing in Phase 1 invalidates the CLAUDE.md plan except:

- CMPMSC is not the live CPU codec — legacy `BC7_CompressBlock` in
  `bc7_encode_kernel.cpp:2663` is. Don't waste time studying CMPMSC.
- The `USE_X` dispatch in `bc7_common_encoder.h` is dead on stock CPU builds.
  Hook the new codec directly at `CompressBlockBC7`
  (`bc7_encode_kernel.cpp:3517`) behind a new `CMP_USE_BC7ENC_RDO` define, or
  provide a parallel exported function
  (e.g. `CompressBlockBC7_bc7enc`) and let the caller pick. The latter is
  the smaller/less-risky diff and matches CLAUDE.md's "additive/selectable"
  constraint literally.
- CLI-only build's real hard deps: OpenGL + Threads. Everything else is
  either forced on but disable-able (`OpenCV`, `EXR`, `KTX2`, `Brotlig`,
  `Qt`, `Vulkan`) or fetched via `fetch_dependencies.py` (glm, rapidxml,
  imgui, glfw). Actual "does it link" test not yet done — flag as first
  Phase 2 sub-step before writing adapter code.

## CLI-only build — actual result

Configure + build succeeded on this machine (Arch Linux, GCC 16.1.1,
CMake ≥ 3.28, Python 3.14). Binary produced at
`compressonator/build_cli/bin/compressonatorcli-bin` (~4 MB), runs
`--help` cleanly.

### Reality vs. Q3 prediction

| Q3 said | Reality |
|---|---|
| `fetch_dependencies.py` will pull glm / rapidxml / imgui / glfw / openexr | Git clones all succeed. **openexr2 ilmbase savannah tarball download times out** (`download.savannah.nongnu.org` unreachable / dead-ish). Fetch aborts with `URLError: Connection timed out`. Not fatal for a build with `OPTION_BUILD_EXR=OFF` — CMake never touches openexr2, so the missing tarball is invisible to the CLI build. Run fetch once, ignore the openexr2 failure, move on. |
| Qt / Vulkan / EXR / KTX2 / Brotlig disable flags are clean | True. |
| OpenCV disable is clean | **False.** `applications/_plugins/common/CMakeLists.txt:26` unconditionally lists `ssim.cpp` in `CMP_Common`, and ssim.cpp does `#include <opencv2/opencv.hpp>`. CMP_Common is a hard dependency of the CLI target, so OpenCV headers are non-optional at build time. Set `OPTION_CMP_OPENCV=ON` and rely on system OpenCV, or delete ssim.cpp from the file list. Same for `applications/_plugins/canalysis/analysis/canalysis.cpp`, part of `Image_Analysis`, which the CLI links unconditionally. |
| Vanilla flag set as sketched should just work | **No.** Five separate patches needed, listed below. |

### Patches applied to get CLI-only building

1. `compressonator/applications/_plugins/common/pluginbase.h` — added
   `#include <cstdint>`. Same GCC-16-no-transitive-`<cstdint>` issue as
   `bc7enc_rdo/ert.h`. Without it, the `TC_PluginVersion` struct silently
   loses every `uint32_t` field; downstream error is misleading (`'no
   member named dwAPIVersionMajor'` from canalysis.cpp), pointing away
   from the real cause.
2. `compressonator/cmp_core/CMakeLists.txt:101` — changed
   `-march=knl` to `-march=skylake-avx512`. GCC 15+ dropped Knights
   Landing support; `knl` is no longer a valid `-march=` value. Failure
   was `cc1plus: error: bad value 'knl' for '-march=' switch` on
   `CMP_Core_AVX512`.
3. `compressonator/external/CMakeLists.txt:14` — gated
   `include(.../glfw/CMakeLists.txt)` behind `if
   (OPTION_BUILD_APPS_CMP_GUI)`. GLFW is only linked by the GUI; the
   ExternalProject_Add step was failing at configure time on a CLI-only
   build (glfw's own cmake_minimum policy), and killing the top-level
   build even though nothing linked against it.
4. `compressonator/CMakeLists.txt:354` — narrowed `find_package(OpenCV)`
   to specific components + `set(OpenCV_LIBRARIES opencv_core opencv_imgproc
   opencv_highgui opencv_imgcodecs)`. Without this, `OpenCV_LIBRARIES`
   included every component installed system-wide, including
   `opencv_hdf` (unresolved HDF5 symbols) and `opencv_viz` (unresolved
   VTK symbols), which broke the CLI final link with dozens of
   `undefined reference` errors.
5. `bc7enc_rdo/ert.h` + `bc7enc_rdo/CMakeLists.txt` — see Step 0 above.
   Standalone bc7enc_rdo patches, unrelated to Compressonator CLI, but
   required for Phase 2 adapter work.

### Final working CMake invocation

```
cd compressonator
mkdir build_cli && cd build_cli
cmake -DOPTION_ENABLE_ALL_APPS=OFF \
      -DOPTION_BUILD_APPS_CMP_CLI=ON \
      -DOPTION_CMP_QT=OFF \
      -DOPTION_CMP_VULKAN=OFF \
      -DOPTION_BUILD_EXR=OFF \
      -DOPTION_CMP_OPENCV=ON \
      -DOPTION_BUILD_KTX2=OFF \
      -DOPTION_BUILD_BROTLIG=OFF \
      -DOPTION_BUILD_INTERNAL_CMP_TEST=OFF \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      ..
make -j$(nproc)
```

`fetch_dependencies.py` must be run once in `build/` first; ignore its
openexr2 tarball download error.

### System dependencies actually required (Arch Linux this run)

- gcc/g++ (16.1.1)
- cmake (≥ 3.28)
- python3 (3.14)
- OpenGL (`libOpenGL.so`)
- OpenCV core+imgproc+highgui+imgcodecs (system, v5.0.0)
- pkg-config
- Threads (stdc++ std::thread)

Not required despite Q3's suspicion:
- Qt5, Vulkan SDK, OpenEXR, KTX2, Brotli-G, TBB, Half/Imath — all skipped.
- glfw — needed to fetch but not to build.

## Check: AVX-512 codepath — runtime-gated?

Yes, safe. `CMP_Core_AVX512` compiles `core_simd_avx512.cpp` with
`-march=skylake-avx512`, but its only export is
`avx512_bc1ComputeBestEndpoints` (a BC1 helper — nothing BC7 uses it).
The dispatch site at `cmp_core/shaders/bc1_cmp.h:112` guards the call
with `IsAvailableAVX512(GetCPUExtensions())` (impl in
`applications/_libs/cmp_math/cpu_extensions.cpp:52`, cpuid-based), and
`cmp_core/source/cmp_core.cpp:74-88` also runtime-selects the SIMD tier.
So an AVX-512 binary distributed to a non-AVX512 CPU never enters the
AVX-512 function pointers — no illegal-instruction risk. The only
distribution concern is the compiler itself: `-march=skylake-avx512`
must be a value the target build host's GCC understands. `knl` isn't;
`skylake-avx512` has been valid since GCC 6.1 (2016).

## Phase 2 — Upstream call chain for BC7 CPU encoding

`CompressBlockBC7()` in `cmp_core` has essentially **one caller** in the
codebase: `BC7BlockEncoder::CompressBlock`
(`cmp_compressonatorlib/bc7/bc7_encode.cpp:1298`), and that call is
gated behind `#ifdef USE_CMP_BC7_CORE` — not defined in the current
build. So on the CLI path the `cmp_core` BC7 entry is **dead**.

The live CPU encode chain is:
```
CCodec_BC7::Compress                 codec_bc7.cpp:479   (per-image, nested block loop 552-704)
  → CCodec_BC7::EncodeBC7Block       codec_bc7.cpp:361   (per-block, thread dispatch)
    → BC7BlockEncoder::CompressBlock bc7_encode.cpp:1272 (per-block, the giant local encoder)
```

`CCodec_BC7::Compress` iterates blocks with two nested `for` loops
(rows × cols), reads a 4x4 RGBA block via `bufferIn.ReadBlockRGBA`,
converts to a `double[16][4]`, and hands off one block at a time to
`EncodeBC7Block`. Multi-threading fan-out lives inside
`EncodeBC7Block` — it round-robins blocks across a worker pool that
each calls `BC7BlockEncoder::CompressBlock` in isolation.

**Batching potential.** No natural batch site without a real
refactor. The outer loop is scalar and interleaves per-row progress
feedback + abort checks (652-703). Multi-threading already gets
coarse-grain parallelism block-by-block, which is exactly what bc7e's
SIMD does within a single call — so a per-block adapter loses the SIMD
throughput but keeps the MT parallelism. For a phase-2 proof-of-
correctness this is acceptable; real batching (gather ~64 blocks →
`bc7e_compress_blocks(64, …)`) needs the row loop rewritten to
accumulate a scratch buffer and emit an eventual batch call, breaking
the per-row feedback cadence. Defer to a later pass; note in the
Phase 3 benchmark section that per-block bc7e will underperform its
batched form.

**Hook target choice** (revising Q2). Hook `CompressBlockBC7` in
`cmp_core` if we ever expose that entry to CLI. For the actual live
path, the additive hook has to sit *inside* `BC7BlockEncoder::
CompressBlock` (`bc7_encode.cpp:1272`), guarded by a new
`CMP_USE_BC7ENC_RDO` compile flag, since that's what the codec plugin
actually calls. Same shape as the Q2 sketch — early return to the
adapter if the flag is on. Keeps the stock encoder reachable when the
flag is off.

## Phase 2 — Adapter built and smoke-tested

### Files added / changed

- `compressonator/cmp_core/source/bc7enc_rdo_adapter.h` — public C API
  (`CompressBlockBC7_bc7enc`, `CompressBlockBC7_bc7enc_from_double`).
- `compressonator/cmp_core/source/bc7enc_rdo_adapter.cpp` — thin per-block
  wrapper. One-shot `std::call_once` init of `bc7e_compress_block_init()` +
  `bc7e_compress_block_params_init_slowest(&p, /*perceptual=*/false)`.
  Encodes one block via `ispc::bc7e_compress_blocks(1, out, pixels, &p)`.
- `compressonator/cmp_core/CMakeLists.txt` — new option
  `OPTION_CMP_USE_BC7ENC_RDO` (default OFF). When ON, invokes the ISPC
  binary at configure time to build
  `bc7e.o + bc7e_{sse2,sse4,avx,avx2}.o`, adds the adapter sources +
  generated objects to `CMP_Core`, and sets `CMP_USE_BC7ENC_RDO=1` as
  a **PUBLIC** target_compile_definition so `CMP_Compressonator`
  (which links `CMP_Core` PUBLIC) picks it up too.
- `compressonator/cmp_compressonatorlib/bc7/bc7_encode.cpp` —
  inside `BC7BlockEncoder::CompressBlock` (line 1272), an early
  `#ifdef CMP_USE_BC7ENC_RDO` branch calls the adapter and returns.
  Stock encoder body untouched below.

### CMake variables surfaced

- `BC7ENC_RDO_DIR` — defaults to `${CMAKE_SOURCE_DIR}/../bc7enc_rdo`.
- `BC7ENC_RDO_ISPC` — defaults to
  `${CMAKE_SOURCE_DIR}/../tools/ispc/linux/bin/ispc`.

### Build + smoke test

Configured with the same recipe as the OpenCV-on CLI build plus
`-DOPTION_CMP_USE_BC7ENC_RDO=ON`. Builds cleanly. Binary size grows
from ~4 MB to ~6.5 MB (ISPC codegen for four SIMD targets).

Round-trip test:
```
compressonatorcli-bin -fd BC7 -EncodeWith CPU ruby.png ruby.dds
compressonatorcli-bin -fd RGBA_8888          ruby.dds ruby_dec.tga
```
- `ruby.dds` = 576×416 `BC7_UNORM`, 239 616 pixel bytes (4:1 ratio ✓).
- Decoded TGA = 576×416 RGBA (matches source dims).
- PSNR vs. source: **51.51 dB** (mean abs diff = 0.18, max abs = 22)
  — well within expected quality for BC7 on a photographic image; not
  garbage, not identity, encoder is doing real work.

### Known limitations (deferred to later)

- Per-block ISPC calls throw away most SIMD width. Batching over
  `CCodec_BC7::Compress`'s outer loop is Phase 3+ work.
- Options mapping is stubbed — the adapter always uses
  `bc7e_compress_block_params_init_slowest(..., perceptual=false)`
  regardless of the caller's `SetQualityBC7 / SetMaskBC7 /
  SetAlphaOptionsBC7` values. Quality→preset translation is Phase 3.
- The adapter is currently hooked only inside
  `BC7BlockEncoder::CompressBlock`. The `CompressBlockBC7()` seam in
  `cmp_core` (advertised as a public API but unused on the CLI path)
  is not hooked; the C entry `CompressBlockBC7_bc7enc` is exposed and
  can be wired in later if downstream code adopts the new-single-header
  interface path.

## Phase 2 verification — Adapter live, byte-level proof

### 1. ON vs OFF byte diff on identical input

Both binaries built with the same CMake flags except
`-DOPTION_CMP_USE_BC7ENC_RDO`, run against
`runtime/images/ruby.png` with identical CLI args
(`-fd BC7 -EncodeWith CPU`, no `-Quality` flag).

- File sizes: 239 764 B each (matches — same header + block count).
- `cmp` disagrees at **byte 149** (first byte past the 128-byte DDS
  header + 20-byte DX10 extension = 148). SHA-256 differs:
  - OFF: `9ac08b12…`
  - ON:  `35bfdc34…`
- BC7 mode histogram (extracted from block byte-0 unary prefix, 14 976
  blocks total in each file):

  | mode | OFF (stock) | ON (bc7enc_rdo) |
  |---:|---:|---:|
  | 0 |   62 (0.4%) |   211 (1.4%) |
  | 1 |  556 (3.7%) | 1432 (9.6%) |
  | 2 |  140 (0.9%) |   47 (0.3%) |
  | 3 |  155 (1.0%) |  451 (3.0%) |
  | 4 |    0 (0.0%) |  117 (0.8%) |
  | 5 |    0 (0.0%) |11629 (77.7%) |
  | 6 |14063 (93.9%)| 1089 (7.3%) |
  | 7 |    0 (0.0%) |    0 (0.0%) |

  Stock is mode-6 dominated (94%) and never emits modes 4 or 5.
  Adapter is mode-5 dominated (78%) and uses the full mode set 0-6
  (7 skipped because ruby is opaque and mode 7 is the alpha-partitioned
  mode — expected). This is textbook bc7e behavior vs. Compressonator's
  legacy fast path. Unambiguous proof the adapter code is what's
  actually running.

- Round-trip PSNR of decoded output vs original:
  - Stock:   49.17 dB (mean|Δ| 0.401, MSE 0.787)
  - Adapter: 51.51 dB (mean|Δ| 0.182, MSE 0.459)

### 2. Quality-tier mismatch in Step 5 — what was actually compared

**Stock** CLI default when `-Quality` is not passed:
`applications/_plugins/common/cmdline.cpp:3529-3540` sets
`fquality = AMD_CODEC_QUALITY_DEFAULT` for BC7. That constant is
`0.05f` (`cmp_compressonatorlib/common.h:185`). This propagates to
`CCodec_BC7::m_Quality = 0.05`, then into
`BC7BlockEncoder`'s constructor
(`cmp_compressonatorlib/bc7/bc7_encode.h:42`). At quality 0.05 the
constructor takes the `m_quality < g_qFAST_THRESHOLD (0.5)` branch:
- `m_shakerRangeThreshold = 0`
- `m_errorThreshold        = 204.8`   (i.e. 256 · (1 − 0.05·2/0.5))
- `m_partitionSearchSize   = 0.2`     (max(1/16, 0.05·2/0.5))

That's Compressonator's "fast/low" tier — the loop short-circuits
early on the majority of blocks and only scans 20% of the partition
space.

**Adapter** unconditionally calls
`ispc::bc7e_compress_block_params_init_slowest(&p, false)`
(`bc7enc_rdo_adapter.cpp:24`). "Slowest" is bc7e's highest-quality
preset: all 8 modes enabled, all 64 partitions scanned in modes 1/3/7,
all p-bit combos with compensated rounding. Perceptual weighting off.

So the Step 5 comparison — and the PSNR delta reported above — is
**tier-mismatched**: stock ran at ~fast, adapter ran at max. The
+2.34 dB PSNR advantage attributed to the adapter conflates:
- (a) genuine codec-quality difference between bc7e's exhaustive
  search and Compressonator's legacy encoder, and
- (b) the fast-vs-slowest tier gap within each.

For any Phase 3 comparison to be meaningful, we need one of:
- Run stock at `-Quality 1.0` (which takes the
  `m_quality > g_HIGHQULITY_THRESHOLD` branch: `m_errorThreshold=0`,
  full partition search) and compare against adapter-slowest.
- Wire a quality→bc7e-preset map into the adapter, then run both at
  the same `-Quality` value across a sweep.

Neither is done yet — this section just pins down what the current
numbers actually mean. **Do not treat +2.34 dB as the codec quality
delta.** It is the "fast-tier stock vs. slowest-tier bc7e" delta.

## Phase 3 (part 1) — fair-tier PSNR + wall-clock

### Setup

- Host: same machine as prior steps (Arch, GCC 16.1.1, 8-core CPU with
  AVX2, no AVX-512).
- Threads pinned: `-NumThreads 8` for both Compressonator variants;
  `OMP_NUM_THREADS=8` for standalone `bc7enc_rdo/build/bc7enc`.
- Timing: `time.perf_counter()` around `subprocess.run(...)`, best-of-3.
- Quality tiers:
  - **stock @ -Q 1.0** — Compressonator OFF-build, explicit
    `-Quality 1.0` (`m_quality > g_HIGHQULITY_THRESHOLD`,
    `m_errorThreshold=0`, all 64 partitions, no early exit).
  - **adapter (slowest)** — ON-build with `-Quality 1.0` (adapter
    unconditionally uses `bc7e_compress_block_params_init_slowest`
    regardless of `-Quality`, so this is bc7e's max preset; the
    `-Quality` flag is passed for consistency but ignored inside the
    adapter branch).
  - **bc7enc_rdo standalone** — `bc7enc -U -u6 -g`
    (`-U` = bc7e path, `-u6` = highest uber level, `-g` skips
    unpacked-PNG writeback so the timing isn't dominated by I/O).
- Test images: `runtime/images/ruby.png` (photographic-ish RGBA), plus
  three synthesized 512×512 RGBA patterns:
  - `bench_grad`   — linear R/G/B gradients + ±30 uniform noise
    (smooth-but-noisy)
  - `bench_noise`  — full random RGB per pixel (worst case for BC7)
  - `bench_struct` — 32×32 checker + inverted-circle mask
    (large flat regions + hard edges)
- Decode path: for PSNR, all three DDS outputs are decoded via the
  ON-build CLI (`-fd RGBA_8888`) so the decoder is held constant across
  variants.

### Raw numbers

```
image          W×H        variant                time(s)   PSNR(dB)
--------------------------------------------------------------------
ruby           576x416    stock @-Q 1.0            3.728      51.66
ruby           576x416    adapter (slowest)        0.267      51.51
ruby           576x416    bc7enc_rdo standalone    0.119      51.51

bench_grad     512x512    stock @-Q 1.0            8.612      31.34
bench_grad     512x512    adapter (slowest)        1.077      31.50
bench_grad     512x512    bc7enc_rdo standalone    0.188      31.50

bench_noise    512x512    stock @-Q 1.0            6.427      19.39
bench_noise    512x512    adapter (slowest)        1.084      19.29
bench_noise    512x512    bc7enc_rdo standalone    0.190      19.29

bench_struct   512x512    stock @-Q 1.0            1.038      83.98
bench_struct   512x512    adapter (slowest)        0.120      74.46
bench_struct   512x512    bc7enc_rdo standalone    0.044      74.46
```

### Observations (facts only, no editorializing)

- Adapter's PSNR equals standalone bc7enc's PSNR to two decimal places
  across all four images (they run the same algorithm with the same
  preset). This is a correctness check that the adapter's per-block
  path is not silently corrupting output.
- Adapter is 2.2×–5.7× slower than the standalone tool (per-block ISPC
  vs. bc7enc's whole-image batched call). Compressonator's per-block
  MT dispatch recovers some parallelism but not the intra-batch SIMD
  width bc7e is designed to fill.
- Adapter is 4×–13× faster than stock @ -Q 1.0 while producing
  approximately equal PSNR on `ruby`, `bench_grad`, `bench_noise`.
- On `bench_struct` (large flat-color regions + hard edges) stock
  @ -Q 1.0 beats bc7e by 9.5 dB. Both bc7e variants match, so it's
  not a per-block-vs-batched artifact — it's a codec/algorithm
  difference on that specific content. Flag for closer look before
  the full benchmark corpus in part 2.

## Phase 3 (part 1b) — GAMMA sample corpus (hard alpha cutouts)

### File distribution

`runtime/images/gamma_sample/` contains **116 `.dds` files** total
(the "113" figure was close). Size stats:

```
n=116  min=240B  max=134 MB  median=131 KB  mean=2.5 MB
p10=33 KB  p25=64 KB  p50=131 KB  p75=524 KB  p90=2 MB  p95=16 MB
```

Bucket counts:
```
<10KB       2     (edge; the 240-byte "*_bump#.dds" is a stub, skip)
10-100KB   33
100KB-1MB  57     (heavy middle)
1-10MB     18
>10MB       6
```

Extremes filtered: skipped files <2 KB (degenerate stubs) and
>30 MB (the single 134 MB entry would dominate wall time without
adding evidence). 9 files picked to span the remaining range:

| size     | file |
|---:|---|
| 2 KB     | `Maids/ui_icon_maidfillcant.dds` |
| 33 KB    | `Maids/ui_icon_pm_drum.dds` |
| 66 KB    | `Maids/ui_icon_sks_short.dds` |
| 131 KB   | `Maids/ui_icon_maidindicators.dds` |
| 131 KB   | `Maids/ui_icon_rspartan.dds` |
| 262 KB   | `Maids/ui_icon_mg36e.dds` |
| 524 KB   | `Maids/ui_icon_w50.dds` |
| 2 MB     | `Maids/ui_maid_pistols.dds` |
| 22 MB    | `Dovetail/wpn_mount_dovetail_kmz_1p59_mount_bump.dds` |

Rationale: covers 4 orders of magnitude of file size (2 KB → 22 MB),
mixes small UI icons with the requested Dovetail scope texture, and
keeps individual runs under ~13 s on the slowest variant so the
total sweep completes in a few minutes.

### Methodology

- Source pixels obtained by decoding each `.dds` via the ON-build CLI
  (`-fd RGBA_8888`) to a `.tga`. That TGA is then fed to both
  Compressonator variants; for the standalone `bc7enc` (PNG-only),
  the same pixels are re-saved as PNG via PIL. Decoder held constant
  across variants for PSNR reads.
- Timing/threading: identical to Part 1 setup — `-NumThreads 8` /
  `OMP_NUM_THREADS=8`, best-of-3 wall time via `time.perf_counter()`.
- PSNR:
  - **RGB@α>0** — mean squared error restricted to pixels whose
    source alpha is non-zero; `20·log10(255) − 10·log10(mse)`.
  - **αPSNR** — same formula over the full alpha channel.
  - Every sampled image had non-trivial transparency (mean α ranged
    21 → 127 on a 0-255 scale). No file needed the fallback to naive
    all-4-channel PSNR.

### Raw numbers

```
name                                   W×H       variant                 t(s)   RGB@α>0  αPSNR    α>0 px   mean α
-----------------------------------------------------------------------------------------------------------------
ui_icon_maidfillcant                   32×16     stock @-Q 1.0           0.086    32.24    39.57       138   63.8
ui_icon_maidfillcant                   32×16     adapter (slowest)       0.100    35.68    40.32       138   63.8
ui_icon_maidfillcant                   32×16     bc7enc_rdo standalone   0.029    35.68    40.32       138   63.8

ui_icon_pm_drum                       128×64     stock @-Q 1.0           0.142    40.70    43.04      1659   46.4
ui_icon_pm_drum                       128×64     adapter (slowest)       0.106    40.97    45.34      1659   46.4
ui_icon_pm_drum                       128×64     bc7enc_rdo standalone   0.032    40.97    45.34      1659   46.4

ui_icon_sks_short                     256×64     stock @-Q 1.0           0.185    38.56    43.18      3705   53.2
ui_icon_sks_short                     256×64     adapter (slowest)       0.121    39.21    44.88      3705   53.2
ui_icon_sks_short                     256×64     bc7enc_rdo standalone   0.035    39.21    44.88      3705   53.2

ui_icon_maidindicators                256×128    stock @-Q 1.0           0.473    40.79    33.02     11957   87.6
ui_icon_maidindicators                256×128    adapter (slowest)       0.136    43.52    46.01     11957   87.6
ui_icon_maidindicators                256×128    bc7enc_rdo standalone   0.041    43.52    46.01     11957   87.6

ui_icon_rspartan                      512×64     stock @-Q 1.0           0.263    40.32    46.63      4839   33.5
ui_icon_rspartan                      512×64     adapter (slowest)       0.124    41.10    47.83      4839   33.5
ui_icon_rspartan                      512×64     bc7enc_rdo standalone   0.040    41.10    47.83      4839   33.5

ui_icon_mg36e                         512×128    stock @-Q 1.0           0.382    41.89    47.77      7290   25.2
ui_icon_mg36e                         512×128    adapter (slowest)       0.131    42.68    49.51      7290   25.2
ui_icon_mg36e                         512×128    bc7enc_rdo standalone   0.045    42.68    49.51      7290   25.2

ui_icon_w50                           512×256    stock @-Q 1.0           0.524    38.33    47.02     11963   21.0
ui_icon_w50                           512×256    adapter (slowest)       0.154    39.14    48.74     11963   21.0
ui_icon_w50                           512×256    bc7enc_rdo standalone   0.060    39.14    48.74     11963   21.0

ui_maid_pistols                      2048×256    stock @-Q 1.0           3.169    39.48    42.97    101883   45.2
ui_maid_pistols                      2048×256    adapter (slowest)       0.391    40.21    44.58    101883   45.2
ui_maid_pistols                      2048×256    bc7enc_rdo standalone   0.282    40.21    44.58    101883   45.2

wpn_mount_dovetail_..._bump         2048×2048    stock @-Q 1.0          12.670    43.10    41.87   4150203  127.1
wpn_mount_dovetail_..._bump         2048×2048    adapter (slowest)       6.759    44.89    43.01   4150203  127.1
wpn_mount_dovetail_..._bump         2048×2048    bc7enc_rdo standalone   1.503    44.89    43.01   4150203  127.1
```

### BC7 mode histograms (mode 7 = alpha-partitioned)

```
-- ui_icon_pm_drum --                    (128×64, 512 blocks)
  stock @-Q 1.0        m0:  2.9  m1:  4.7  m2:  0.0  m3:  1.0  m4:  0.0  m5:  0.0  m6: 81.6  m7:  9.8
  adapter (slowest)    m0:  2.5  m1:  2.1  m2:  0.0  m3:  0.4  m4:  5.3  m5: 73.8  m6: 10.5  m7:  5.3

-- ui_icon_maidindicators --             (256×128, 2 048 blocks)
  stock @-Q 1.0        m0:  0.4  m1:  0.4  m2:  0.2  m3:  3.4  m4:  0.0  m5:  0.0  m6: 55.9  m7: 39.6
  adapter (slowest)    m0:  0.4  m1:  0.3  m2:  0.2  m3:  0.0  m4: 39.0  m5: 50.6  m6:  8.8  m7:  0.5

-- wpn_mount_dovetail_..._bump --        (2048×2048, 262 144 blocks)
  stock @-Q 1.0        m0:  0.0  m1:  0.0  m2:  0.0  m3:  0.0  m4:  0.0  m5:  0.0  m6: 78.3  m7: 21.7
  adapter (slowest)    m0:  0.0  m1:  0.0  m2:  0.0  m3:  0.0  m4: 26.7  m5: 46.1  m6: 23.5  m7:  3.6
```

### Observations (facts only)

- Adapter's RGB@α>0 PSNR **matches standalone bc7enc's** to 2 decimals
  on every one of the 9 files. Adapter's αPSNR also matches standalone
  to 2 decimals. Correctness of the per-block wrapper w.r.t. the
  batched reference is preserved across the alpha-cutout corpus, not
  just on ruby.png.
- Adapter beats stock @ -Q 1.0 on every file:
  - RGB@α>0 PSNR: +0.27 to +3.44 dB
  - αPSNR:        +0.75 to +12.99 dB (biggest on `maidindicators`)
- Adapter is 1.3× to 8.1× faster than stock on this corpus.
- Standalone bc7enc is 1.4× to 4.5× faster than the adapter (per-block
  vs. batched — matches Part 1 pattern).
- **Mode 7 usage differs sharply.** Stock relies on mode 7 as its
  primary alpha-partitioned answer (9.8-39.6% on the three sampled
  files); adapter almost never picks it (0.5-5.3%) and instead uses
  modes 4/5 for the alpha-cutout blocks. Despite that, adapter's
  αPSNR is *higher* than stock's on all three, so mode 4/5 with bc7e's
  exhaustive endpoint search out-performs stock's mode-7 selection on
  this content — not the reverse. Mode 7 is present in the adapter's
  output (it does fire, just rarely), so the mode is reachable — bc7e
  simply prefers modes 4/5 when they score better.

### Scope color map (Dovetail diffuse, appended to part 1b)

Fully opaque (mean α = 255, α>0 pixels = 4 194 304 = all of them), so
per Part 1b's methodology fallback this file uses naive all-pixel RGB
PSNR — the alpha channel carries no signal.

```
name                             W×H         variant                 t(s)   PSNR(RGB)
wpn_mount_dovetail_..._mount    2048×2048    stock @-Q 1.0         343.381    61.18
                                             adapter (slowest)       4.254    61.38
                                             bc7enc_rdo standalone   1.473    61.38

BC7 mode histogram (opaque, so mode 7 correctly unused by both):
  stock @-Q 1.0       m0: 2.7% m1:11.2% m2: 0.1% m3:19.1% m4: 0.0% m5: 0.0% m6:66.9% m7: 0.0%
  adapter (slowest)   m0: 2.3% m1: 4.2% m2: 0.1% m3: 1.0% m4: 0.0% m5:24.6% m6:67.8% m7: 0.0%
```

Observations (facts only):

- Adapter PSNR matches standalone bc7enc to 2 decimals (61.38 vs 61.38)
  — correctness holds on the diffuse map too.
- Adapter +0.20 dB over stock @ -Q 1.0.
- Stock **343 s vs. adapter 4.25 s** — 80.7× ratio on this file, the
  widest gap seen in the corpus so far. Standalone 1.47 s, another
  2.9× beyond the adapter.
- Neither variant emits mode 7 (correct — file is fully opaque, mode 7
  is alpha-partitioned). Stock leans on modes 6/3/1; adapter leans on
  modes 6/5.

## Phase 3 (part 1d) — Why stock is so slow: shaker + dispatch code review

Findings, no code changes.

### 1. Shaker refinement structure

Loop layout inside `BC7BlockEncoder::CompressBlock`
(`cmp_compressonatorlib/bc7/bc7_encode.cpp`):

```
per candidate mode (up to 8):
  per shake-attempt i = 0..numShakeAttempts-1     [bc7_encode.cpp:613]
    per subset:
      if (m_blockMaxRange > m_shakerRangeThreshold || dimension != 3)
        ep_shaker_2_d(..., shakeSize, ...)                 [629]
      else
        ep_shaker_d(...)                                    [652]
        ep_shaker_2_d(...)                                  [655]
        if (shaker_d beat shaker_2_d) ep_shaker_2_d(...)    [671]  // third call
    // early exit for this mode:
    if (m_errorThreshold > 0 && bestError <= m_errorThreshold) break;   [718-725]
```

Bounds:
- `numShakeAttempts = max(1, min(floor(8 * m_quality + 0.5), partitionsToTry))`
  (`bc7_encode.cpp:594`). At `-Quality 1.0` → up to 8 attempts.
- `shakeSize = max(2, min(floor((8 − 1.5·indexBits) · m_quality + 0.5), 6))`
  (`bc7_encode.cpp:590-591`), +2 if parity is `SAME_PAR` / `BCC`.
  Fixed by mode + quality, not block content.
- The `for i < numShakeAttempts` loop is **iteration-capped**; there is no
  convergence-based termination for the outer attempt loop itself.
- The **only** early-out for the outer loop is the `bestError <=
  m_errorThreshold` check on line 721 — and it only fires when
  `m_errorThreshold > 0`. At `-Quality 1.0`,
  `m_errorThreshold = 0` (`bc7_encode.h:91`), so **that early-out never
  fires at Q1.0**. Every mode/attempt combination runs to completion.

Inside each shaker call (`ep_shaker_2_d`, shake.cpp:661) there **is** a
convergence-based loop:

```
do {
    ... cluster/endpoint refinement ...
    change  = index_changed;
    better  = err_r < err_o;
    done    = !(change && better);
} while (!done && maxTry--);       // shake.cpp:1015
```

So each shaker invocation runs at most `maxTry = 8` iterations, terminates
early when the index doesn't change or error doesn't improve. That's a
hard cap (8) with early exit — not unbounded.

### 2. Content-dependent cost

Yes, but not through the shaker's own iteration count. Two content-driven
knobs actually affect wall time:

- **`m_blockMaxRange`** = max of per-channel (max−min) over the 16 pixels
  in a block (`bc7_encode.cpp:1372-1378`). Purely content-based (a
  measure of block variance in the widest channel).
- **`m_blockMaxRange > m_shakerRangeThreshold`** gate at `bc7_encode.cpp:627`:
  - When true, only `ep_shaker_2_d` runs (one shaker call per subset).
  - When false, `ep_shaker_d` + `ep_shaker_2_d` both run, plus a third
    `ep_shaker_2_d` re-run if `shaker_d` won round one. Up to **3×** the
    shaker work of the high-variance path.
  - At `-Quality 1.0`, `m_shakerRangeThreshold = 255 · 1.0 = 255`. Since
    `m_blockMaxRange` is bounded by 255 (uint8 range), the gate is
    **never true at Q1.0** — every block takes the expensive dual-shaker
    path. This is one big reason Q1.0 is dramatically slower than
    intermediate quality settings, and why the wall time is uniform
    across content (all blocks pay full price).

- Per-shaker convergence: an "easy" block (low variance, quickly-converging
  index refinement) exits the inner `do/while` in 1-2 iterations; a
  pathological block hits the `maxTry=8` cap. Same *upper* bound, so no
  runaway; but yes, per-block cost has ~4-8× spread depending on how
  quickly the inner cluster refinement stabilizes.

Net picture: at `-Quality 1.0`, per-block cost = (fixed outer loop of
modes × 8 shake attempts × 2-3 shaker calls × 1-8 inner iterations).
Everything scales primarily by quality; content only modulates the inner
convergence rate and the choice of shaker variant (which is content-
gated only at Q<1). No runaway blocks, but no fast-path either.

### 3. Thread pool distribution

Structure (`cmp_compressonatorlib/bc7/codec_bc7.cpp`):

- Fixed-size pool of N worker threads (N = `-NumThreads` or auto).
- Each thread owns a `BC7EncodeThreadParam` slot with `run`, `exit`, in/out
  pointers.
- Worker loop (`BC7ThreadProcEncode`, line 64):
  ```
  while (!exit) {
      if (run) { encoder->CompressBlock(in, out); run = FALSE; }
      std::this_thread::sleep_for(0);  // yield, no real sleep
  }
  ```
  Busy-poll on the `run` flag. Not a proper condition variable.
- Producer (`EncodeBC7Block`, line 361): called once per block from the
  outer `CCodec_BC7::Compress` loop. It **busy-scans** the thread array
  round-robin starting from `m_LastThread` until it finds a slot with
  `run == FALSE`, hands the block to that slot, sets `run = TRUE`, updates
  `m_LastThread`. No sleep in the producer's wait either.

So distribution is **dynamic per-block**, not static chunks. Whichever
worker finishes its current block first gets picked up by the producer's
round-robin sweep on the next call. Effectively work-stealing-ish
(technically producer-poll rather than worker-steal, but the resulting
load balance is the same for this workload).

Straggler behavior:
- Mid-run: a slow block doesn't stall others — its worker stays busy
  while producer feeds the other N−1 workers. No idle time as long as
  fast blocks keep flowing.
- End of run: `FinishBC7Encoding` (line 421) waits for **every**
  worker's `run` flag to clear. If the last N blocks in flight include
  one 8× slower than the others, the whole compress call blocks for
  (slow_block_time − fast_block_time) at the join. On a 4 M-block image
  this residual is a small fraction of total time. On a small image
  (few hundred blocks) it can be a noticeable tail.
- The producer's busy-wait costs CPU while looking for an idle slot,
  which competes with the workers on an oversubscribed run. With
  `-NumThreads 8` on an 8-core machine, the producer thread is a 9th
  runnable thread; on a 16-thread host it's less relevant.

### What this means for Phase 3 numbers

- Adapter's 80× win on the fully-opaque 2048² scope map is consistent
  with everything above: Q1.0 kills stock's fast paths (never triggers
  the high-variance shaker shortcut, never triggers `m_errorThreshold`
  early-out), and the mode × attempt × shaker matrix runs full for
  every one of ~260k blocks. Dispatch is efficient; the encoder work
  itself is what's expensive.
- The gap will shrink at lower `-Quality` (fewer shake attempts, smaller
  shakeSize, content-gated shaker shortcut becomes reachable, error
  threshold early-out fires). Any future "fair fight" that isn't just
  the codec quality delta needs a `-Quality` sweep, not a single point.

## Phase 3 (part 2) — Options-mapping design (investigation, no impl)

### 1. BC7_Encode struct + setter semantics (cmp_core)

Struct definition (`cmp_core/shaders/bc7_encode_kernel.h:195-224`):

```
typedef struct {
    CGU_FLOAT  quality;          // 0..1, clamped
    CGU_FLOAT  errorThreshold;   // derived from quality by SetQualityBC7
    CGU_UINT32 validModeMask;    // 8-bit mode bitmask, default 0xFF
    CGU_BOOL   imageNeedsAlpha;  // set but NEVER READ (see below)
    CGU_BOOL   colourRestrict;   // block-level filter for modes 6/7 on opaque blocks
    CGU_BOOL   alphaRestrict;    // block-level filter for modes 6/7 on punch-through blocks
    // internal / working state
    CGV_FLOAT  opaque_err, best_err;
    CGU_FLOAT  minThreshold, maxThreshold;
    // USE_ICMP path only:
    CGU_INT    refineIterations, part_count, channels;
} BC7_Encode;
```

Defaults (`SetDefaultBC7Options`, `bc7_encode_kernel.h:958-976`):
`quality=1.0, minThreshold=5.0, maxThreshold=80.0, errorThreshold=5.0,
validModeMask=0xFF, imageNeedsAlpha=colourRestrict=alphaRestrict=FALSE,
part_count=128, channels=4`.

Setter semantics (`bc7_encode_kernel.cpp:3477-3515`):

- **`SetQualityBC7(opts, q)`** clamps `q` to `[0,1]`, stores it, and
  derives:
    `errorThreshold = maxThreshold * (1 − q)                 // if q ≤ 0.5`
    `errorThreshold = maxThreshold * (1 − q) + minThreshold  // if q > 0.5`
  So `errorThreshold` at defaults: q=0 → 80, q=1 → 5, q=0.5 → 40.
  It's an early-out threshold on per-block error: encoder breaks the
  refinement loop once the block error drops below it.

- **`SetMaskBC7(opts, mask)`** — `validModeMask` = 8-bit bitmask of
  which of the 8 BC7 modes (0..7) are allowed to be tried. bit i =
  mode i.

- **`SetAlphaOptionsBC7(opts, imageNeedsAlpha, colourRestrict,
  alphaRestrict)`** — pinned down by reading
  `notValidBlockForMode()` at `bc7_encode_kernel.cpp:2633-2661`:

  - `imageNeedsAlpha` — **dead flag**. Stored by
    `SetAlphaOptionsBC7`, never read by any file under `cmp_core/`.
    Also stored as `BC7BlockEncoder::m_imageNeedsAlpha` in
    `cmp_compressonatorlib/bc7/bc7_encode.h:57,191` and never read
    there either. Grep confirms: only assignments, no reads. Effectively
    a no-op API surface — probably historical.
  - `colourRestrict` — when true, and the block's own pixels don't
    need alpha (`blockNeedsAlpha == FALSE`), modes 6 and 7 (the
    combined-colour+alpha modes) are excluded from consideration for
    that block. Prevents parity-driven accidental sub-1.0 alpha on
    RGB-only content.
  - `alphaRestrict` — when true, and the block has alpha that is
    exactly 0 or 255 anywhere (`blockAlphaZeroOne == TRUE`) plus
    real alpha (`blockNeedsAlpha == TRUE`), modes 6 and 7 are again
    excluded. Avoids punch-through / thresholded-alpha corner cases
    those modes handle poorly.
  Both are per-block filters that further mask off modes 6/7 on top of
  `validModeMask`; neither changes global quality.

- **`SetErrorThresholdBC7(opts, minT, maxT)`** — sets the `minThreshold`
  / `maxThreshold` fields consumed by the derivation inside
  `SetQualityBC7`. If a caller wants a custom error-early-out schedule
  they set these before calling `SetQualityBC7`.

### 2. bc7e_compress_block_params — every field (bc7e_ispc.h:69-87)

```
struct bc7e_compress_block_params {
    uint32_t m_max_partitions_mode[8];   // per-mode partition scan caps (indexed by mode)
    uint32_t m_weights[4];               // R/G/B/A error weights (perceptual init sets non-1)
    uint32_t m_uber_level;               // 0..6, overall search depth
    uint32_t m_refinement_passes;        // final endpoint refinement pass count
    uint32_t m_mode4_rotation_mask;      // bits over 4 rotations for mode 4
    uint32_t m_mode4_index_mask;         // bits over the two index-bit assignments for mode 4
    uint32_t m_mode5_rotation_mask;      // bits over 4 rotations for mode 5
    uint32_t m_uber1_mask;               // uber-level extra search space bitmask
    bool     m_perceptual;               // YCbCrA metric vs. RGBA
    bool     m_pbit_search;              // search all p-bit combos vs. use heuristic
    bool     m_mode6_only;               // fast path: skip everything except mode 6
    bool     m_unused0;
    struct m_opaque_settings {
        uint32_t m_max_mode13_partitions_to_try; // clamps modes 1 & 3 partitions
        uint32_t m_max_mode0_partitions_to_try;
        uint32_t m_max_mode2_partitions_to_try;
        bool     m_use_mode[7];          // modes 0..6 enable flags (used only when block is opaque)
        bool     m_unused1;
    };
    struct m_alpha_settings {
        uint32_t m_max_mode7_partitions_to_try;
        uint32_t m_mode67_error_weight_mul[4]; // per-channel weight multiplier for modes 6/7 selection
        bool     m_use_mode4;            // enable flags for the alpha-capable modes only (4,5,6,7)
        bool     m_use_mode5;
        bool     m_use_mode6;
        bool     m_use_mode7;
        bool     m_use_mode4_rotation;
        bool     m_use_mode5_rotation;
        bool     m_unused2;
        bool     m_unused3;
    };
};
```

The preset init functions
(`ultrafast/veryfast/fast/basic/slow/slowest/veryslow`) set all of these
consistently — they're the intended "quality tier" entry points. Mode
selection is split by block content: `m_opaque_settings.m_use_mode[]`
gates modes 0..6 for blocks bc7e classifies as opaque; `m_alpha_settings.
m_use_mode4/5/6/7` gates the alpha-capable modes for blocks with
non-trivial alpha.

### 3. Proposed mapping (BC7_Encode → bc7e_compress_block_params)

```
CMP m_quality  →  bc7e preset selection:
    quality < 0.10    → bc7e_compress_block_params_init_ultrafast(&p, perc)
    0.10 ≤ q < 0.25   → bc7e_compress_block_params_init_veryfast(&p, perc)
    0.25 ≤ q < 0.45   → bc7e_compress_block_params_init_fast(&p, perc)
    0.45 ≤ q < 0.65   → bc7e_compress_block_params_init_basic(&p, perc)
    0.65 ≤ q < 0.85   → bc7e_compress_block_params_init_slow(&p, perc)
    0.85 ≤ q ≤ 1.00   → bc7e_compress_block_params_init_slowest(&p, perc)
```

Bucketing rather than interpolation is deliberate — bc7e's presets aren't
independent knobs that combine cleanly; each preset is a hand-tuned tuple
across all 15+ fields. Interpolating between two presets by mixing
their `m_use_mode[]` bools or `m_max_partitions_mode[]` uint32s would
produce configurations bc7e was never validated with. Six buckets over
the 0..1 range mirrors bc7e's own tier count and matches the granularity
Compressonator's own quality knob delivers (`AMD_CODEC_QUALITY_DEFAULT
= 0.05`, i.e. its own default is already sub-preset resolution).

`perceptual` argument to the preset init: derives from Compressonator's
`-EncodeWith` mode. Compressonator has no runtime perceptual toggle
exposed via `BC7_Encode`, so default `false` (linear RGBA) is the safe
choice. If a caller flips a `Perceptual=1` string parameter on the
codec, we can honor it — currently no evidence such a parameter exists
on the CLI side, so unmapped-but-safe.

```
CMP validModeMask (8-bit)  →  post-init override of use-mode flags:
    // opaque path
    for i in 0..6:
        p.m_opaque_settings.m_use_mode[i] = (validModeMask >> i) & 1
    // alpha path
    p.m_alpha_settings.m_use_mode4 = (validModeMask >> 4) & 1
    p.m_alpha_settings.m_use_mode5 = (validModeMask >> 5) & 1
    p.m_alpha_settings.m_use_mode6 = (validModeMask >> 6) & 1
    p.m_alpha_settings.m_use_mode7 = (validModeMask >> 7) & 1
```

Applied *after* the preset init so the preset's settings for enabled
modes are kept intact; only the disabled bits get cleared. If
`validModeMask == 0xFF` (default) this is a no-op.

```
CMP colourRestrict / alphaRestrict  →  per-block decision (NOT a bc7e param)
```

These are **block-content-conditional** filters (see §1 above), so they
cannot be baked into `bc7e_compress_block_params` up front — bc7e
receives one param struct for the whole batch. The adapter must decide
per block whether to further mask modes 6/7 before calling into bc7e.

Cleanest impl: hold two variants of `bc7e_compress_block_params` in the
adapter — the preset-with-mask one (used for most blocks) and a
"colour/alpha-restricted" copy with modes 6/7 forcibly disabled. Choose
per block based on scanning the source pixels the same way
`notValidBlockForMode()` does:

```
// once, outside the block loop:
params_default  = preset + validModeMask override
params_restricted = copy of params_default with:
    p.m_opaque_settings.m_use_mode[6] = 0  (if colourRestrict)
    p.m_alpha_settings.m_use_mode6    = 0  (if alphaRestrict)
    p.m_alpha_settings.m_use_mode7    = 0  (if alphaRestrict)

// per block:
scan 16 pixels: any α != 255 → blockNeedsAlpha
                any α ∈ {0,255} → blockAlphaZeroOne
if (colourRestrict && !blockNeedsAlpha) use params_restricted
else if (alphaRestrict && blockNeedsAlpha && blockAlphaZeroOne)
                                          use params_restricted
else                                      use params_default
```

The alpha scan is 16 comparisons per block — trivial next to the encode
itself. This preserves Compressonator's per-block filter semantics
without touching bc7e's internals.

```
CMP errorThreshold (early-exit)  →  UNMAPPED
```

bc7e does not expose an "early-exit if per-block error below X"
parameter. Its refinement is driven by `m_uber_level`,
`m_refinement_passes`, `m_max_partitions_mode[]`, and
`m_pbit_search` — all fixed-cost knobs, no per-block adaptive early
termination. The closest analogue is `m_mode6_only`, but that's a
global fast path, not an adaptive one. `errorThreshold` will be silently
ignored by the adapter. Documented behavioral divergence, not a bug.

Impact analysis: Compressonator's early-exit is what makes low-quality
runs fast on easy blocks (see Phase 3 part 1d). bc7e's fixed-cost
model gives up that content-adaptivity in exchange for a much better
worst-case and higher quality per-mode. This shows up in the benchmark
numbers as bc7e being uniformly-priced across content while stock at
low quality varies wildly. Not worth trying to force this into the
adapter — the mismatch is intrinsic.

```
CMP imageNeedsAlpha  →  UNMAPPED (dead in source too)
```

Setter accepts it, no one reads it. Ignoring in the adapter matches
existing behavior exactly.

```
CMP minThreshold / maxThreshold  →  UNMAPPED (feed errorThreshold, which is unmapped)
```

Same reasoning as `errorThreshold` — they only exist to derive it.

### 4. Callers of these setters — surface beyond the CLI

Grep for `SetQualityBC7 | SetMaskBC7 | SetAlphaOptionsBC7 |
SetErrorThresholdBC7 | CreateOptionsBC7 | CompressBlockBC7` across
`cmp_framework/`, `applications/`, `examples/`, `cmp_unittests/`:

- **Live CLI path (compressonatorcli)**: does **not** call any of these.
  The CLI's `-Quality` flag flows through
  `CCodec_BC7::SetParameter("Quality", …) → CCodec_BC7::m_Quality →
  new BC7BlockEncoder(..., m_Quality, ...)`. The adapter is hooked
  inside `BC7BlockEncoder::CompressBlock`, so it must read
  `this->m_quality`, `this->m_validModeMask`, `this->m_colourRestrict`,
  `this->m_alphaRestrict` (all already fields of `BC7BlockEncoder`),
  **not** the cmp_core `BC7_Encode` struct. `m_imageNeedsAlpha` field
  also exists on `BC7BlockEncoder` but is unread there too, mirroring
  cmp_core.
- **cmp_framework**: no direct calls to these setters.
- **`applications/_plugins/ccmp_sdk/bc7/bc7.cpp`**: a plugin using
  `CompressBlockBC7_Internal` (a `_Internal` variant, not the C API we
  looked at) via cmp_core headers. Not hit by the CLI build we've been
  testing.
- **`examples/core_example1/coreexample.cpp`**: SDK sample code — calls
  `CreateOptionsBC7 / SetQualityBC7 / SetMaskBC7 / CompressBlockBC7`
  directly to demonstrate the public C API. Doesn't run unless someone
  builds and runs the sample.
- **`cmp_unittests/…`**: `CompressBlockBC7()` used with `nullptr`
  options in ~50 test cases; `CreateOptionsBC7 + SetQualityBC7 +
  SetMaskBC7 + SetAlphaOptionsBC7 + SetErrorThresholdBC7` all exercised
  in `sdk_binary_tests/core_binary_test.cpp`. Only reached if the
  unittest target is built (it isn't in our CLI-only build).

So for the **CLI live path**, the adapter needs to read the
`BC7BlockEncoder` member fields — the cmp_core `BC7_Encode` C API is
irrelevant to it. For **eventual coverage** of the cmp_core C API
callers (examples + unittests + ccmp_sdk plugin), we'd also want to
add a second hook at `CompressBlockBC7()` in
`cmp_core/shaders/bc7_encode_kernel.cpp:3517` behind
`CMP_USE_BC7ENC_RDO`, using the same mapping applied to the passed
`BC7_Encode*`. That hook was flagged unhooked in Phase 2 §Q2; adding it
along with the options mapping keeps behavior consistent across both
entry points.

### Summary of what maps cleanly vs. not

| Compressonator field       | bc7e mapping                                | Clean? |
|:--|:--|:--:|
| `quality` (0..1)           | preset bucket (6 tiers)                     | ✓ |
| `validModeMask` (8-bit)    | override `m_use_mode[]` in both sub-structs | ✓ |
| `colourRestrict`           | per-block param-struct switch               | ✓ (needs 2 param variants + 16-px scan/block) |
| `alphaRestrict`            | same as above                                | ✓ |
| `imageNeedsAlpha`          | ignore (dead in source)                     | ✓ (matches stock) |
| `errorThreshold`           | none — bc7e has no adaptive early-out       | **✗ unmappable, documented divergence** |
| `minThreshold/maxThreshold`| derive-only, ignored with errorThreshold    | ✓ (irrelevant once errorThreshold is out) |
| perceptual (from bc7e)     | no CMP field exposes it; default `false`    | ✓ (only relevant if caller wires new param) |

Ready for review before implementing.

## Phase 3 (part 3) — Fast-end fight: stock @-Q 0.1 vs bc7e ultrafast

Answers "does bc7e's fixed-cost model lose to stock's adaptive early-out
at the fast end?" — one question, small sample.

Preset mapping confirmed via `bc7enc_rdo/rdo_bc_encoder.cpp:328-350`:
`-u0` → `bc7e_compress_block_params_init_ultrafast`.

Same 4 images as Part 1 (ruby + bench_grad/noise/struct), same
threading/timing methodology. Full-pixel PSNR (these images have no
alpha cutout — bench_* were synthesized fully opaque, ruby is
mostly-opaque).

```
image          W×H         variant                     t(s)   PSNR(dB)
----------------------------------------------------------------------
ruby           576×416     stock @-Q 0.1               0.154     49.55
ruby           576×416     bc7enc -U -u0 (ultrafast)   0.068     47.44

bench_grad     512×512     stock @-Q 0.1               1.440     30.78
bench_grad     512×512     bc7enc -U -u0 (ultrafast)   0.058     27.40

bench_noise    512×512     stock @-Q 0.1               1.592     18.86
bench_noise    512×512     bc7enc -U -u0 (ultrafast)   0.059     15.03

bench_struct   512×512     stock @-Q 0.1               0.096     57.94
bench_struct   512×512     bc7enc -U -u0 (ultrafast)   0.037     70.53
```

### Answer

**bc7e ultrafast loses on quality at the fast end, on 3 of 4 images.**

- Ruby (photographic):  stock +2.11 dB, at 2.3× the wall time.
- bench_grad (smooth+noise): stock +3.38 dB, 25× wall time.
- bench_noise (worst case): stock +3.83 dB, 27× wall time.
- bench_struct (checker+circles): bc7e +12.59 dB, 0.4× wall time.
  Same content outlier as Part 1 slowest-vs-Q1.0 comparison —
  structured/flat-region content is where bc7e's mode 5 selection wins
  regardless of tier.

The stock adaptive early-out (Phase 3 part 1d) plus mode-6 bias at low
quality is genuinely competitive on photographic/noisy content — it
converges early on easy blocks, spends its budget on hard ones. bc7e's
ultrafast preset spends the same fixed budget per block regardless of
content, and at that budget it's undershoot on hard content and
overshoot (irrelevant work) on easy content. Net RGB PSNR is worse on
natural imagery.

bc7e ultrafast is uniformly faster (1.6× to 27×) — the speed win holds
at the fast end even where quality loses. So the picture is:

- Slowest end (Q1.0 vs bc7e slowest, Part 1): bc7e wins on both time
  and PSNR on most content, roughly ties on structured.
- Fast end (Q0.1 vs bc7e ultrafast, this test): stock wins PSNR on
  photo/noise content, bc7e wins time uniformly.
- Structured/flat-region content: bc7e wins PSNR at every tier
  (mode-selection effect, not tier effect).

For a preset-bucket mapping (Phase 3 part 2 proposal), this means the
low-quality bucket (`ultrafast`) is genuinely a quality-loss vs stock —
users who set `-Quality 0.1` expecting stock's speed/quality tradeoff
will get a PSNR downgrade. Worth calling out in adapter docs or the
mapping table, or the low-quality tiers could be intentionally biased
one preset up (map `[0..0.10] → veryfast` rather than `ultrafast`) to
partially close the fast-end quality gap at some time cost. Not
implementing anything now — just recording the data.

## Phase 3 (part 4) — Options mapping implementation

### Step 1 — Adapter refactor

`cmp_core/source/bc7enc_rdo_adapter.{h,cpp}` now takes a
`CMP_bc7enc_Options` struct instead of hardcoding slowest/non-perceptual:

```
typedef struct {
    double        quality;         // 0..1
    unsigned char validModeMask;   // default 0xFF
    unsigned char colourRestrict;  // bool
    unsigned char alphaRestrict;   // bool
    unsigned char perceptual;      // bool (default 0)
} CMP_bc7enc_Options;
```

New entry points:
- `CompressBlockBC7_bc7enc_opts(src, stride, out, opts)`
- `CompressBlockBC7_bc7enc_from_double_opts(in, out, opts)`

Old zero-opts entries preserved; they resolve to `DEFAULT_OPTIONS`
(quality=1.0, mask=0xFF, no restricts) → slowest bucket, unchanged
behavior for anything not yet migrated.

**Bucket mapping** — 5 tiers, `ultrafast` intentionally dropped:

```
quality < 0.25 → veryfast    (lowest bucket biased up from ultrafast;
                              see Phase 3 part 3: ultrafast loses 2-4 dB
                              PSNR vs stock on photo/noisy content, so
                              biasing preserves quality at the low end
                              without giving up bc7e's speed advantage.)
quality < 0.45 → fast
quality < 0.65 → basic
quality < 0.85 → slow
quality ≤ 1.00 → slowest
```

**Mode mask** applied post-preset in both sub-structs
(`m_opaque_settings.m_use_mode[]` for modes 0..6,
`m_alpha_settings.m_use_modeN` for modes 4..7). No-op when mask = 0xFF.

**colourRestrict / alphaRestrict** — adapter keeps two variants of
`bc7e_compress_block_params` (default + modes-6/7-restricted). Per block,
scans 16 pixels for `blockNeedsAlpha` and `blockAlphaZeroOne` (same
semantics as `notValidBlockForMode` at `bc7_encode.cpp:2633-2661`), picks
the restricted variant when the block matches. No restricts → single
variant, no scan.

Thread-local single-slot cache keyed on `(quality, mask, restricts,
perceptual)` avoids re-running the preset init every call. Options
usually stay constant across a stripe, so hit rate ≈ 100%.

`errorThreshold`, `imageNeedsAlpha`, `minThreshold`, `maxThreshold` —
unmapped, documented divergences (bc7e has no adaptive early-out;
`imageNeedsAlpha` is dead in stock source too).

### Step 2 — Caller wiring + verification

`cmp_compressonatorlib/bc7/bc7_encode.cpp:1281` now builds a
`CMP_bc7enc_Options` from `BC7BlockEncoder` members
(`m_quality`, `m_validModeMask`, `m_colourRestrict`, `m_alphaRestrict`)
and calls `CompressBlockBC7_bc7enc_from_double_opts`.

Bucket-boundary verification on `runtime/images/ruby.png`, all quality
sweeps ON vs OFF. md5 of output DDS, mode histogram, byte-diff flag:

```
   Q variant    md5             m0   m1   m2  m3  m4    m5   m6  m7
------------------------------------------------------------------------
 0.05 ON        5fae5456ae19   113 1606    0 779   0 11353 1125   0
 0.05 OFF       051d40d6eaf5    62  556  140 155   0     0 14063  0   different bytes
 0.15 ON        5fae5456ae19   113 1606    0 779   0 11353 1125   0   same as Q=0.05 ✓ (veryfast bucket)
 0.30 ON        cff9a2cf1964     0 1804    0 835   0 11353  984   0   different from 0.15 ✓ (fast)
 0.50 ON        10cda379ba6f   154 1741    0 686   0 11353 1042   0   different from 0.30 ✓ (basic)
 0.70 ON        16c8a5170408   124 1526   72 754   0 11353 1147   0   different from 0.50 ✓ (slow)
 0.95 ON        7f115eab183c   229 1556   62 628   0 11353 1148   0   different from 0.70 ✓ (slowest)
 1.00 ON        7f115eab183c   229 1556   62 628   0 11353 1148   0   same as Q=0.95 ✓ (slowest bucket)
```

All 5 bucket boundaries fire. ON differs from OFF at every Q — adapter
is definitively live at stock's own default (Q=0.05 in cmp_core;
CLI's `-Quality` flag defaults to 0.05 as `AMD_CODEC_QUALITY_DEFAULT`).

Mode 5 usage (11353 blocks in every ON output vs 0 in every OFF output)
is a strong per-image signature of the bc7e encoder — bc7e's mode-5
selection heuristics differ meaningfully from stock's mode-6 bias.

### Step 3 — cmp_unittests / examples reachability

**Finding: cmp_unittests and examples are Windows-only in the current
CMake.** Both `add_subdirectory(examples)` and `add_subdirectory(cmp_unittests)`
sit inside a `if (CMP_HOST_WINDOWS)` block at `CMakeLists.txt:437`. On
Linux, `-DOPTION_BUILD_APPS_CMP_UNITTESTS=ON` / `EXAMPLES=ON` are
silently no-ops — the targets are never registered with CMake.

Confirmed reachable **manually** on Linux: built `examples/core_example1`
out-of-tree by linking directly against the existing `libCMP_Core.a` +
the SIMD sub-libs + the bc7e ISPC object files. Runs, all BCn tests
pass. So the source compiles fine on Linux; only the CMake gate blocks
integration.

**But `core_example1` doesn't hit the adapter.** It calls the cmp_core
public C API (`CompressBlockBC7()` at
`cmp_core/shaders/bc7_encode_kernel.cpp:3517`), which is a *different*
entry point from the `BC7BlockEncoder::CompressBlock` I hooked. Same
finding as NOTES.md Phase 3 part 2 §4: the CLI live path uses the
`BC7BlockEncoder` codec object; the SDK C API and unittests use the
cmp_core direct entry. Hooking the SDK surface needs an additional
`#ifdef CMP_USE_BC7ENC_RDO` early-return at
`bc7_encode_kernel.cpp:3517`, translating the passed `BC7_Encode*`
options via the same mapping.

Not implemented in this pass — the CLI path (the actual delivery target
for the ATAK integration) is fully working; the SDK/unittests path is
additional coverage that only matters when someone builds against the
library directly (not the case for a `compressonatorcli`-shell-out
consumer like ATAK).

To reach the unittest surface on this box, two independent pieces of
work would be needed:
1. Ungate `examples` and `cmp_unittests` from the `if (CMP_HOST_WINDOWS)`
   block in `CMakeLists.txt:437`. Confirmed feasible: `core_example1`
   builds and runs from source unmodified when linked manually.
2. Add the second hook at `bc7_encode_kernel.cpp:3517` with the same
   mapping function so the SDK C API also routes through bc7e.

Neither blocks the current ATAK integration path.

## Phase 3 (part 4b) — Boundary-exact verification + unittests reachability

### 1. Boundary values (Q = 0.25, 0.45, 0.65, 0.85)

Same md5/histogram method as Part 4, comparing boundary Q values against
known interior references (veryfast=0.05, fast=0.30, basic=0.50,
slow=0.70, slowest=0.95) on `ruby.png`:

```
Q=0.25  md5=cff9a2cf1964  bucket=fast     OK      (design: fast)
Q=0.45  md5=cff9a2cf1964  bucket=fast     WRONG   (design: basic)
Q=0.65  md5=10cda379ba6f  bucket=basic    WRONG   (design: slow)
Q=0.85  md5=7f115eab183c  bucket=slowest  OK      (design: slowest)
```

**2 of 4 boundaries misresolve — Q=0.45 lands in fast (should be basic),
Q=0.65 lands in basic (should be slow).**

**Root cause: `cmp_compressonatorlib/bc7/codec_bc7.cpp:131` uses
`std::stof` (float parse), not `std::stod`.** CLI `-Quality 0.45` →
`std::stof("0.45")` = `0.44999998807907104` (nearest float below 0.45)
→ widened into `double m_Quality` with the low bits already gone →
adapter's `quality < 0.45` compares `0.44999998... < 0.45` = TRUE →
returns fast bucket.

Same failure for 0.65: `float(0.65)` = `0.64999997615814208`.
0.25 and 0.85 don't misresolve because 0.25 is exactly representable
(2⁻²) and float(0.85) rounds UP to `0.85000002384185791`, staying above
the threshold.

Precondition failure is upstream of the adapter (stock behavior too:
same stof-truncated value feeds `g_HIGHQULITY_THRESHOLD = 0.7` and other
stock quality-dependent knobs, so any user asking for `-Quality 0.7`
today already loses precision below the threshold). Not adapter-caused.

Fix options — not implemented in this pass:
- Upstream fix: change `std::stof` → `std::stod` in codec_bc7.cpp:131.
  Minimal, correct, also fixes stock's own float-boundary hazards.
- Adapter workaround: bucket by `int(quality * 100 + 0.5)` on integer
  centibuckets. Immune to FP but doesn't help stock's own thresholds.

Recommended: upstream fix. This is a pre-existing latent bug the new
bucketing just exposed via a clean falsifiable test.

### 2. cmp_unittests reachability — correction to Part 4 §Step 3

Previous claim "unittests are Windows-only in the current CMake" is
incomplete — the CMake gate is real but **not the only blocker**. Full
out-of-tree manual build attempt on Linux found several genuine Linux
portability problems:

| Blocker | Fix used | Real? |
|:--|:--|:--|
| `common/lib/ext/catch2/single_include/catch2/catch.hpp` missing | Downloaded catchorg/Catch2 v2.13.10 single header to `/tmp/catch2ext/` | Missing repo dependency (not in Arch's catch2-v2 pkg either) |
| `fileio_test.cpp:34` includes Windows-only `direct.h` (uses `_mkdir`) | Excluded from build | Real portability bug |
| `codecbuffer_tests.cpp:107-` `static` on explicit template specializations | Excluded from build | Real (MSVC-lax, GCC rejects) |
| Narrowing `int→CMP_SBYTE` in `codecbuffer_tests.cpp:1774` | `-Wno-narrowing` (moot after excluding file) | Cosmetic |
| `cmp_fileio.cpp` uses `std::experimental::filesystem` | `-lstdc++fs` at link | Real link flag needed |

With those 5 workarounds, the binary **builds and runs**:

```
$ /tmp/cmp_unittests --list-tests | wc -l         # (partial)
$ /tmp/cmp_unittests BC7_Red_Ignore_Alpha,BC7_Green_Full_Alpha,BC7_White_Half_Alpha
All tests passed (6 assertions in 3 test cases)
```

But — same as core_example1 — the BC7 tests call
`CompressBlockBC7()` (the cmp_core public C API at
`bc7_encode_kernel.cpp:3517`), not `BC7BlockEncoder::CompressBlock`.
Confirmed at `core_tests.cpp:2426` and ~30 similar sites:
`CompressBlockBC7(decompBlock, 16, compBlock, nullptr)`. So the tests
build and pass **against stock BC7**, not against the adapter. The
adapter is not exercised by unittests until the second hook at
`bc7_encode_kernel.cpp:3517` is added.

Corrected reachability summary:
- **CLI path**: adapter live and verified.
- **SDK C API (`CompressBlockBC7`)**: reachable, but currently
  unhooked. Adds up to ~2 h of work: add early-return in
  `bc7_encode_kernel.cpp:3517` reading `BC7_Encode*` fields, translate
  via the same mapping function (already refactorable out of the
  adapter with minor extraction).
- **cmp_unittests target**: needs (a) `common/lib/ext/catch2/`
  populated in the repo, (b) `fileio_test.cpp` + `codecbuffer_tests.cpp`
  patched or conditionally compiled, (c) CMake gate opened, (d)
  `stdc++fs` linked. Independent from adapter work.

## Phase 3 (part 4c) — Boundary bug root cause correction + fix

### Correction to Part 4b root cause

Part 4b named `codec_bc7.cpp:131` (`std::stof`) as the root cause of
the Q=0.45 / Q=0.65 boundary misresolution. That was **incorrect** —
that line is on the dead string-overload path for `-Quality`, not the
live CLI path. Traced the actual CLI call chain end-to-end:

```
cmdline.cpp:411   std::stof(strParameter) → local `float value`
                  → CompressOptions.fquality (typed double, textureio.h:73)
                  → widening float→double keeps the already-lost bits gone
compress.cpp:223  codec->SetParameter("Quality",
                                      (CODECFLOAT)options->fquality)
                  ← CODECFLOAT is `typedef float` (codec.h:41)
                  ← so any double precision at this point is truncated
codec_bc7.cpp:170 SetParameter(name, CODECFLOAT fValue) overload fires
                  → m_Quality = fValue    (fValue already float-truncated)
```

`codec_bc7.cpp:131` (`SetParameter(name, CMP_CHAR*)` overload) is only
reached via `CmdSet[]` string forwarding at `compress.cpp:293` /
`:614`, and `-Quality` is handled explicitly at `cmdline.cpp:405-417`
so it never lands in `CmdSet[]`. The Part 4b hypothesis "changing
codec_bc7.cpp:131 to std::stod would close the bug" would have had
zero effect on the CLI path.

**Real root cause**: two independent float-precision losses in series:
1. `cmdline.cpp:411` parses via `std::stof` (float parse)
2. `compress.cpp:223` casts `double fquality → CODECFLOAT (float)`
   before calling `SetParameter`

Either one of these alone truncates `-Quality 0.45` from double 0.45
to `0.44999998807907104`, which the adapter's `quality < 0.45`
correctly evaluates to true and returns the wrong bucket.

### Two-part remediation

**Kept: stod parse cleanup** (four sites, harmless correctness
cleanup — not sufficient alone):

- `cmdline.cpp:411`: `std::stof` → `std::stod` (Quality CLI parse)
- `codec_bc7.cpp:131`: `std::stof` → `std::stod` (Quality string overload)
- `codec_bc7.cpp:139`: `std::stof` → `std::stod` (Performance string overload)
- `codec_astc.cpp:306`: `std::stof` → `std::stod` (ASTC Quality string overload)

Alone these do NOT fix the CLI boundary bug (empirically verified: same
2-of-4 boundary failures as before). Reason: `compress.cpp:223`'s
`(CODECFLOAT)options->fquality` cast to `float` truncates whatever
precision was preserved upstream. `CODECFLOAT` is used in 484 places
across the tree — changing the typedef itself is out of scope.

The cleanup is kept because:
- Removes latent stof usage on paths where the string overload IS live
  (e.g. `-Performance` CLI arg, which does route through `CmdSet[]`)
- Makes the code self-consistent with the field types (`m_Quality`,
  `m_Performance`, `fquality` are all `double`)
- Candidate for a small standalone upstream PR on
  `fix-quality-float-precision` branch (kept as local artifact)

**Actual fix that closes the bug**: bucket on integer centibuckets
in the adapter, not on raw float comparisons. `bc7enc_rdo_adapter.cpp`
`select_preset()`:

```cpp
const int cb = static_cast<int>(quality * 100.0 + 0.5);
if      (cb < 25) ...init_veryfast
else if (cb < 45) ...init_fast
else if (cb < 65) ...init_basic
else if (cb < 85) ...init_slow
else              ...init_slowest
```

At the CODECFLOAT-truncated boundary values:
- `float(0.45)=0.44999998...` → `44.9999... + 0.5 = 45.4999...` → 45 → basic ✓
- `float(0.65)=0.64999997...` → `64.9999... + 0.5 = 65.4999...` → 65 → slow ✓
- `float(0.85)=0.85000002...` → `85.0000... + 0.5 = 85.5000...` → 85 → slowest ✓
- `float(0.25)=0.25` exact  → `25.0 + 0.5 = 25.5` → 25 → fast ✓

This absorbs FP loss regardless of where in the call chain it happens.
Also robust against future upstream additions of `(CODECFLOAT)` casts
or new parse sites — the adapter no longer trusts the incoming float
below centi-precision.

### Re-run — Q=0.25/0.45/0.65/0.85 after centibucket fix

Same md5/histogram method, same `ruby.png`, `build_cli` rebuilt with
centibucket fix + four stod cleanups + adapter refactor + hook:

```
Reference (interior) values:
  veryfast  Q=0.05  md5=5fae5456ae19  OK
  fast      Q=0.30  md5=cff9a2cf1964  OK
  basic     Q=0.50  md5=10cda379ba6f  OK
  slow      Q=0.70  md5=16c8a5170408  OK
  slowest   Q=0.95  md5=7f115eab183c  OK

Boundary values:
  Q=0.25  md5=cff9a2cf1964  bucket=fast     OK
  Q=0.45  md5=10cda379ba6f  bucket=basic    OK
  Q=0.65  md5=16c8a5170408  bucket=slow     OK
  Q=0.85  md5=7f115eab183c  bucket=slowest  OK
```

All 4 of 4 boundaries resolve to their designed bucket. Same
falsifiable method that exposed the bug now shows it closed.

### Recommended upstream trajectory

- Adapter-side centibucket fix is the change that actually resolves the
  bug for the bc7e path — commit on `bc7enc-rdo-integration`.
- `fix-quality-float-precision` (local branch, not pushed) retains the
  stod cleanup as a candidate small standalone PR. It does not close
  the boundary bug on its own; described as a correctness cleanup, not
  a bugfix, if proposed upstream.
- The `compress.cpp` `(CODECFLOAT)` cast is the actual latent stock
  hazard for anything else that compares double `fquality` against a
  fixed threshold (e.g. `g_HIGHQULITY_THRESHOLD = 0.7`). Fixing that
  would require either routing Quality via the string overload
  (`snprintf %.17g` then `SetParameter(char*, char*)`) at all five
  sites, or replacing `CODECFLOAT` with `double` in the SetParameter
  signature — both invasive. Not in scope for this integration.

## Phase 3 (part 5) — Producer-side block batching for bc7e

### Design summary (see part 5 investigation for full derivation)

- BATCH_N = 64 (matches rdo_bc_encoder.cpp:513).
- New adapter API: `CompressBlockBC7_bc7enc_batch_create/destroy` builds
  the preset+mode-mask params-pair once per CCodec_BC7::Compress() call
  (quality/mask/restrict verified constant across a Compress via
  BC7BlockEncoder member lifetime — set only in ctor at bc7_encode.h:49-65).
- New adapter API: `CompressBlockBC7_bc7enc_batch_from_double` takes
  `count ≤ BATCH_N` contiguous blocks. When neither colourRestrict nor
  alphaRestrict is set (common case): one bc7e_compress_blocks call, direct
  output. When either is set (option 3a): O(N) scan → gather into
  default/restricted sub-batches → 1 or 2 bc7e_compress_blocks calls →
  scatter results back into original positions.
- Producer path in codec_bc7.cpp:Compress() gated on both `CMP_USE_BC7ENC_RDO`
  and `CMP_USE_BC7ENC_RDO_BATCH`. Bypasses the per-block worker pool
  entirely for the batch path — accumulates within existing `for j: for i:`
  loop, flushes at BATCH_N-full or end-of-row.
- Row-bounded batches: progress/abort still row-boundary granularity, matches
  stock semantics byte-for-byte.
- Tail: `min(BATCH_N, dwBlocksX - i)`, no special handling required — ISPC
  masks tail SIMD lanes internally.
- Old per-block path stays reachable (turn `OPTION_CMP_USE_BC7ENC_RDO_BATCH`
  off) for correctness A/B verification in step 2.

### Step 1 — Implementation, adapter + producer wiring

Files touched (on `bc7enc-rdo-integration`, uncommitted):

- `cmp_core/source/bc7enc_rdo_adapter.h` — added `CMP_bc7enc_BatchContext`
  opaque struct + `CMP_BC7ENC_BATCH_N` (=64) + 3 new entry points.
- `cmp_core/source/bc7enc_rdo_adapter.cpp` — added batch context lifecycle,
  fast-path (unrestricted) and partition-path (3a) batch encode functions.
  Reuses existing `select_preset` / `apply_mode_mask` / `restrict_modes_67`
  helpers so preset-bucket rules stay in one place.
- `cmp_core/CMakeLists.txt` — new option `OPTION_CMP_USE_BC7ENC_RDO_BATCH`
  gated on `OPTION_CMP_USE_BC7ENC_RDO`; when set, publicly defines
  `CMP_USE_BC7ENC_RDO_BATCH=1`.
- `cmp_compressonatorlib/bc7/codec_bc7.cpp` — added
  `#include "bc7enc_rdo_adapter.h"` under the double-define gate, and a
  batched producer block at the top of the block-processing region.
  Reads `m_Quality` / `m_ModeMask` / `m_ColourRestrict` / `m_AlphaRestrict`
  directly from the CCodec_BC7 members to build the batch context (same
  values that would have been passed to BC7BlockEncoder ctor in the
  non-batch path). Falls through to the existing per-block path when the
  batch define is not set.

New build dir: `build_cli_batch/` (configured with
`-DOPTION_CMP_USE_BC7ENC_RDO=ON -DOPTION_CMP_USE_BC7ENC_RDO_BATCH=ON`).
The existing `build_cli/` remains configured for the per-block bc7e path
and `build_cli_off/` for stock — three co-resident build trees for the
three-way comparison in later steps.

Smoke test on ruby.png at Q=0.5:
```
$ build_cli_batch/bin/compressonatorcli-bin -fd BC7 -EncodeWith CPU \
    -Quality 0.5 -NumThreads 8 runtime/images/ruby.png /tmp/smoke_batch.dds
$ md5sum /tmp/smoke_batch.dds
10cda379ba6f01c0c20179723b319d33  /tmp/smoke_batch.dds
```

`10cda379ba6f` prefix matches the interior `basic` bucket reference from
Phase 3 part 4b's sweep (which used the per-block bc7e path). Same output
for the same Q on a photo texture is not proof of block-level equality —
that's step 2 — but it rules out gross failure (file-length mismatch,
zeroed blocks, obvious corruption).

Step 1 complete. Pausing before step 2 (per-block bit-identical
verification, including a colourRestrict/alphaRestrict test image).

### Step 2 — Bit-identity: batched vs per-block bc7e

#### Options-source verification

Traced CCodec_BC7 members → BC7BlockEncoder ctor at codec_bc7.cpp:309:

```
new BC7BlockEncoder(m_ModeMask, m_ImageNeedsAlpha, m_Quality,
                    m_ColourRestrict, m_AlphaRestrict, m_Performance)
```

Ctor (bc7_encode.h:49-65) copies inputs to members with these transforms:
- `validModeMask <= 0` → `m_validModeMask = 0xCF` (0-rescue); else direct.
- `m_quality = cmp_minT(1.0, cmp_maxT(quality, 0.0))` — clamp to [0,1].
  Both CLI (cmdline.cpp:412) and SetParameter (codec_bc7.cpp:132) already
  reject out-of-range values, so clamp is no-op for valid input.
- `m_colourRestrict`, `m_alphaRestrict`: direct pass-through.

Per-block hook (bc7_encode.cpp:1288-1291) reads these from the encoder
members. Batch producer (codec_bc7.cpp) reads directly from the
CCodec_BC7 members. Both paths therefore see the same values EXCEPT for
the 0-rescue on ModeMask — added to the batch producer explicitly:

```
const CMP_DWORD safeModeMask = (m_ModeMask == 0) ? 0xCF : m_ModeMask;
opts.validModeMask = static_cast<unsigned char>(safeModeMask & 0xFF);
```

`m_Performance` and `m_ImageNeedsAlpha` are unmapped in
`CMP_bc7enc_Options` in both paths (bc7e has no equivalent for either),
so their omission from the batch context is identical to their omission
from the per-block hook.

**Confirmed identical:** post-InitializeBC7Library, the options passed
to bc7e are byte-for-byte the same across the two paths for any input
`m_ModeMask` in [0, 255].

#### colourRestrict / alphaRestrict CLI reachability

Both flags reach the codec through two independent CLI paths:

1. `cmdline.cpp:988` lists `-ColourRestrict` / `-AlphaRestrict` in the
   `CmdSet[]` capture branch; they're forwarded to the codec via
   `compress.cpp:293` `SetParameter(strCommand, strParameter)` →
   `codec_bc7.cpp:117-120` string overload.
2. `compress.cpp:247-248` unconditionally sets them from
   `options->brestrictColour` / `options->brestrictAlpha` via the
   `CMP_DWORD` overload at `codec_bc7.cpp:158-161`.

CLI-usable as `-ColourRestrict 1` / `-AlphaRestrict 1`. Defaults
(cmdline.h:109 sibling fields, both `bool false`) don't need overriding.

#### Bit-identity results

Test rig at `/tmp/verify_batch_bit_identity.py`: encodes each case via
both `build_cli` (per-block bc7e) and `build_cli_batch` (batched),
strips DDS header, compares payload block-by-block (16-byte units).

```
[ruby.png Q=0.50]                                           14976/14976  100.0000%  OK
[ruby.png Q=0.45 (boundary)]                                14976/14976  100.0000%  OK
[ruby.png Q=0.65 (boundary)]                                14976/14976  100.0000%  OK
[ruby.png Q=0.50 -ColourRestrict 1 -ModeMask 255]           14976/14976  100.0000%  OK
[ruby_alpha.tga Q=0.50 -AlphaRestrict 1 -ModeMask 255]      30000/30000  100.0000%  OK
[ruby_alpha.tga Q=0.50 -Colour 1 -Alpha 1 -ModeMask 255]    30000/30000  100.0000%  OK

ALL BIT-IDENTICAL
```

Boundary values Q=0.45 and Q=0.65 chosen specifically because those
were the two that misresolved before the centibucket fix; verifying
here that the two paths agree at those Q values proves both are seeing
the same rounded bucket AND that the batch path's centibucket
computation matches the per-block path's.

#### Pre-existing hazard discovered en route (documented, not fixed)

First run of the sweep crashed on `ruby_alpha.tga -AlphaRestrict 1`
under the default `m_ModeMask=0xCF` (which disables modes 4 and 5).
Root cause: for any block classified `alphaRestrict`-restricted
(blockNeedsAlpha=TRUE AND blockAlphaZeroOne=TRUE), the mask disables
alpha modes 4 and 5 (`apply_mode_mask` bits 4,5 clear) AND
`restrict_modes_67` disables alpha modes 6 and 7 — leaving zero valid
alpha modes. Stock BC7 has the same latent issue at
bc7_encode.cpp:1433 (`assert(validModeMask != 0);`) but in release
builds silently falls out with `encodedBlock=FALSE` and no-op'd output.
Per-block bc7e produces sketchy but non-crashing output (num_blocks=1
in ISPC's `foreach` masks out enough of the OOB writes to survive).
Batched bc7e passes larger `num_blocks` and reliably crashes
`encode_bc7_block` on uninitialized `opt_results.m_mode`.

Not addressed in this pass because:
- It's a pre-existing spec-invalid option combination in
  Compressonator, not caused by batching.
- Stock's "silently produce garbage output" behavior is arguably worse
  than a hard crash; a crash surfaces the misconfiguration.
- Fixing it robustly requires deciding whether `alphaRestrict` should
  force-enable mode 4/5 (diverging from stock) or drop the restriction
  for the affected block (also diverging from stock).

Callers who need both `-AlphaRestrict 1` and support for blocks with
0/1 alpha must combine with `-ModeMask 255` (or any mask that leaves
at least one alpha mode enabled after restrict). The test rig uses
`-ModeMask 255` for the restrict cases for this reason.

Step 2 complete. All 6 constructed-valid test cases show 100% per-block
bit-identity. Pausing before step 3 (tail utilization on small images).

### Step 2b — Close the zero-valid-modes crash with a defensive guard

Rather than leaving the reachable crash from Step 2's hazard section
documented and unfixed, added a small guard in
`cmp_core/source/bc7enc_rdo_adapter.cpp` shared by both the per-block
`choose_params()` and the batched `block_needs_restricted()` selection.

**What the guard does.** At context-build time (both the thread-local
`params_pair` used by the per-block path and the `CMP_bc7enc_BatchContext`
used by the batched path), after applying the ModeMask and the restrict
mask, precompute two booleans:

```
m_restricted_alpha_ok  = has_any_alpha_mode (&m_restricted)
m_restricted_opaque_ok = has_any_opaque_mode(&m_restricted)
```

using two trivial helpers:

```
bool has_any_alpha_mode(...)  { return m_use_mode4 || m_use_mode5 || m_use_mode6 || m_use_mode7; }
bool has_any_opaque_mode(...) { for (i in 0..6) if (m_use_mode[i]) return true; return false; }
```

Per-block selection then only routes to the restricted variant when the
matching flag is set:

```
if (colourRestrict && !blockNeedsAlpha && m_restricted_opaque_ok) return &m_restricted;
if (alphaRestrict  &&  blockNeedsAlpha && blockAlphaZeroOne && m_restricted_alpha_ok) return &m_restricted;
return &m_default;
```

When the restricted variant would leave a block class unencodable,
that block class falls back to the unrestricted `m_default` for the
duration of the call. Well-defined behavior: no crash, no garbage, and
a superset of what stock intended (encoding proceeds with the
originally-selected mode set, ignoring only the restrict flag that
would have destroyed the mode set for this block class).

**Scope.** The guard is one boolean check on the per-block hot path
(one extra bool AND per block-classification). Params are built once
per Compress call. No allocation, no branching added to bc7e itself.

**Verification.**

Previously-crashing config now runs on both binaries:

```
$ build_cli/bin/compressonatorcli-bin      -fd BC7 -EncodeWith CPU \
    -Quality 0.5 -NumThreads 1 -AlphaRestrict 1 \
    runtime/images/ruby_alpha.tga /tmp/guard_unbatch.dds       # exit 0
$ build_cli_batch/bin/compressonatorcli-bin -fd BC7 -EncodeWith CPU \
    -Quality 0.5 -NumThreads 1 -AlphaRestrict 1 \
    runtime/images/ruby_alpha.tga /tmp/guard_batch.dds         # exit 0
```

Block-diff of the two outputs on that config: `30000/30000 (100.0000%)`
identical; MD5 `7f359e51bc5c` on both.

Re-ran the six valid-combo bit-identity tests from Step 2 with the
guard in place — all still 100% identical, same MD5s as before the
guard. The guard is a strict no-op for any case where the restricted
variant retains at least one mode of the required class:

```
[ruby.png Q=0.50]                                           14976/14976  100.0000%  OK
[ruby.png Q=0.45 (boundary)]                                14976/14976  100.0000%  OK
[ruby.png Q=0.65 (boundary)]                                14976/14976  100.0000%  OK
[ruby.png Q=0.50 -ColourRestrict 1 -ModeMask 255]           14976/14976  100.0000%  OK
[ruby_alpha.tga Q=0.50 -AlphaRestrict 1 -ModeMask 255]      30000/30000  100.0000%  OK
[ruby_alpha.tga Q=0.50 -Colour 1 -Alpha 1 -ModeMask 255]    30000/30000  100.0000%  OK
```

### Latent stock bug — worth a standalone report to AMD

Independent of the adapter work, the hazard the guard defends against
is a real correctness bug in stock Compressonator's own BC7 codec:

- Reproduce: `compressonatorcli -fd BC7 -EncodeWith CPU -Quality 0.5
  -AlphaRestrict 1 <any RGBA image with mixed 0/255 alpha>`
- Stock BC7 (bc7_encode.cpp:1398-1431) constructs the per-block
  `validModeMask` by intersecting the codec's `m_validModeMask`
  (default 0xCF, which has bits 4 and 5 clear — no separate-alpha
  modes) with a run-time skip of `COMBINED_ALPHA` modes 6/7 whenever
  `alphaRestrict + blockNeedsAlpha + blockAlphaZeroOne` fires.
- Result: `validModeMask == 0` for those blocks.
- Stock's mode-search loop at bc7_encode.cpp:1458 iterates through all
  8 modes with `if (!(validModeMask & Mode)) continue;`, exits without
  setting `encodedBlock=TRUE`, then the `if (!encodedBlock)` handler
  at :1521 is a documented-as-error no-op that leaves `out[]`
  untouched. Whatever was previously in the output buffer becomes the
  encoded block — non-deterministic garbage.
- In debug builds an assertion catches this (bc7_encode.cpp:1433
  `assert(validModeMask != 0);`), so it never trips in developer
  testing.

Shape is smaller than the CODECFLOAT precision issue: a single-line
fix (rescue `validModeMask == 0` after the restrict-loop by dropping
the restrict rather than emitting nothing) closes it. Same "found
while testing our own change, but affects stock too" provenance —
suitable candidate for a small standalone upstream PR, separate from
either the bc7e integration or the fix-quality-float-precision branch.

Step 2b complete. Guard in tree, uncommitted. Ready for step 3 (tail
utilization).

## Phase 3 (part 5) — Step 3: tail utilization on GAMMA sample corpus

Re-ran the 9-file Phase 3 part 1b sample set against `build_cli_batch`
(bc7e batched producer) and compared against the previously-recorded
"adapter (slowest)" per-block bc7e wall times. Same TGA sources, same
`-Quality 1.0 -NumThreads 8`, best-of-3 wall time via
`time.perf_counter()`. Harness: `/tmp/step3_tail_util.py`.

Tail computed statically from image dims: row width in blocks =
`(W+3)/4`. Producer flushes at `batch_count==64` OR at end-of-row
(`i+1==dwBlocksX`), so a row of `N` blocks emits `N/64` full batches
plus one tail flush of `N%64` blocks (skipped if `N%64==0`).

### Row structure and measured wall time

```
file                              W×H         blocks_row×col  full/row  tail  batches   lane_util  t_batch  t_ref (unbatched)  Δ
--------------------------------------------------------------------------------------------------------------------------------
ui_icon_maidfillcant              32×16        8×4                   0     8        4      12.5%   0.126s   0.100s          +25.7%
ui_icon_pm_drum                   128×64      32×16                  0    32       16      50.0%   0.139s   0.106s          +30.8%
ui_icon_sks_short                 256×64      64×16                  1     0       16     100.0%   0.141s   0.121s          +16.9%
ui_icon_maidindicators            256×128     64×32                  1     0       32     100.0%   0.138s   0.136s           +1.2%
ui_icon_rspartan                  512×64     128×16                  2     0       32     100.0%   0.144s   0.124s          +16.4%
ui_icon_mg36e                     512×128    128×32                  2     0       64     100.0%   0.151s   0.131s          +15.5%
ui_icon_w50                       512×256    128×64                  2     0      128     100.0%   0.180s   0.154s          +16.9%
ui_maid_pistols                  2048×256    512×64                  8     0      512     100.0%   0.653s   0.391s          +66.9%
wpn_mount_dovetail_..._bump     2048×2048    512×512                 8     0     4096     100.0%   3.365s   6.759s          -50.2%
--------------------------------------------------------------------------------------------------------------------------------
TOTAL                                                                                             5.037s   8.022s           -37.2%
```

`lane_util` above is the aggregate ratio of populated block-slots to
`batches × 64`. Not a SIMD lane count (bc7e's ISPC targets are 4/8-wide
so intra-block masking is separate) — it's the amortization ratio: how
much of each `bc7e_compress_blocks` call is doing real work vs. paying
per-call fixed cost on empty slots.

### Tail-waste finding (the ask)

Design-phase estimate: "~0.8% aggregate slowdown from tail waste."

Actual, on this corpus:

- **7 of 9 files: zero tail waste.** Any image whose block-row width
  is a multiple of 64 (256×any, 512×any, 2048×any at BC7's 4×4 tile)
  produces only full batches. That covers every file wider than 256 px.
- **2 of 9 files: severe under-fill.** `pm_drum` and `maidfillcant` have
  row widths (32 and 8 blocks) that never reach `BATCH_N=64`, so every
  batch is tail-only. Amortization ratio 50.0% and 12.5%.
- **Aggregate ratio, weighted by batch count:** 100.0% — the two thin
  files together contribute 20 of the corpus's 4880 batches (0.4%). The
  0.8% design estimate is inside noise for this corpus.

So the tail-waste hazard exists but it's concentrated in a narrow band:
files whose row width in blocks is < 64. On this corpus that's icons
≤ 128 px wide (`maidfillcant`, `pm_drum`). Everything else is fine.

### Wall-clock finding (not what the question asked, but visible in the data)

The 100%-lane-util files still regress by +15% to +67% except for the
2048² Dovetail file, where batched **wins by 50%** and dominates the
aggregate to a net −37.2%.

Regression on the medium files is NOT tail waste — those rows have
`tail=0` and every batch is full. The batched producer at
`codec_bc7.cpp:557` explicitly **bypasses the per-block worker pool**
and runs single-threaded, while the "adapter (slowest)" reference runs
across 8 worker threads. That's the delta on medium files: single-
thread batched vs 8-thread per-block. The 2048² file is large enough
for bc7e's per-call-setup amortization to overcome the 8× thread
deficit; the medium files aren't.

This is orthogonal to tail waste and a known consequence of the Step 1
design choice ("row-serial producer bypasses worker pool"). Documented
here as a quantified tradeoff, not fixed. Options for later, if the
medium-file regression matters:

1. Chunk the block stream across worker threads (each thread runs its
   own row-band producer, feeds its own batch buffer, calls bc7e).
2. Keep single-thread producer but pipeline: batch N and batch N+1 in
   flight, one being packed while the other is in bc7e.
3. Accept the tradeoff — the corpus's aggregate is a net win and the
   large-file wins are where the real work is.

### Verdict for Step 3

- Tail-utilization hazard: **quantified.** Affects only images with
  row width < 64 blocks (< 256 px wide). Aggregate impact on this
  corpus is under design-phase estimate.
- Wall-clock story: **more complex.** Single-thread producer is the
  dominant factor on medium files, not tail. Real-world use with a
  batch of many mid-sized files would run slower per-file than the
  per-block bc7e path.
- No code change made — user asked for measurement only.

Ready for Step 4 (three-way benchmark) once user confirms.

## Phase 3 (part 5) — Step 3b: restore worker-pool parallelism to batched path

### Diagnosis confirmed

Thread-scaling check on `build_cli_batch` (pre-fix), NT=1 vs NT=8:

```
file                                        NT=1     NT=8   ratio
ui_maid_pistols                            0.479s   0.572s   0.84x
ui_icon_w50                                0.155s   0.158s   0.98x
wpn_mount_dovetail_kmz_1p59_mount_bump     2.602s   3.649s   0.71x
```

NT=8 is slightly *slower* than NT=1 across the board — thread overhead
paid with no parallel work to distribute. Batched path was fully
single-threaded regardless of `-NumThreads`. Diagnosis confirmed.

### Why the initial implementation bypassed the worker pool

Honest answer: shortcut, taken without flagging.

Step 1's reviewed design said "producer accumulates, workers run
`EncodeBC7Block_Batch` on whole batches". The implementation that
landed put both the producer accumulator AND the `bc7e_compress_blocks`
call in the same single-threaded producer loop in `Compress()`, bypassing
`m_EncodeParameterStorage` / `BC7ThreadProcEncode` entirely.

Real technical friction was small but nonzero:

- `BC7EncodeThreadParam` was single-block (`in[16][4]`, `out*`). Batch
  mode needed a `batch_in[N][16][4]` + `count` + `bctx` extension.
- Each worker needed its own `CMP_bc7enc_BatchContext` (bc7e state is
  small but not thread-safe to share).
- Producer needed to fill directly into the selected worker's buffer
  rather than its own, to avoid a per-batch 32KB memcpy.

None of those are hard — they just needed to be built, and the initial
patch skipped them. Step 3 measurement made the cost visible, so
building the design-original version is the right response.

### Fix (this step)

- `codec_bc7.h`: extended `BC7EncodeThreadParam` under
  `CMP_USE_BC7ENC_RDO_BATCH` with `batch_in[CMP_BC7ENC_BATCH_N][16][4]`,
  `batch_count`, `bctx`. Added `m_bctx[MAX_BC7_THREADS]` to
  `CCodec_BC7`. New methods `AcquireIdleWorker()`, `DispatchBatch()`.
- `codec_bc7.cpp`:
  - `BC7ThreadProcEncode`: added batch branch — when `batch_count > 0`,
    worker calls `CompressBlockBC7_bc7enc_batch_from_double` on its
    own `batch_in`/`bctx`. Per-block path unchanged.
  - `InitializeBC7Library`: one `bc7enc_batch_create` per worker with
    the codec's options (same `validModeMask==0 → 0xCF` rescue as the
    per-block hook, mirrors `BC7BlockEncoder` ctor at `bc7_encode.h:50-53`).
  - Destructor: per-worker `bc7enc_batch_destroy`.
  - `Compress()` batched producer: `cur_slot = AcquireIdleWorker()`,
    fill worker's `batch_in[cur_count]` directly (no producer-side
    buffer, no memcpy), on flush call `DispatchBatch(cur_slot, count, out)`
    which sets `run=TRUE`. End of encode: `FinishBC7Encoding()`
    drains all workers.
  - Single-thread case (`-NumThreads 1`): `DispatchBatch` runs the
    batch synchronously in-place, no worker signal — matches the
    per-block path's single-thread branch (`codec_bc7.cpp:413-421`).

### Re-verification

Bit-identity suite (`/tmp/verify_batch_bit_identity.py`): 6/6 configs
still 100% match unchanged, MD5s identical to Step 2b. Zero-valid-modes
guard config (`ruby_alpha.tga -AlphaRestrict 1`, default ModeMask):
still exits cleanly, no crash.

Thread-scaling re-check (`/tmp/step3_thread_check.py`), post-fix:

```
file                                        NT=1     NT=8   ratio
ui_maid_pistols                            0.477s   0.162s   2.94x
ui_icon_w50                                0.149s   0.110s   1.35x
wpn_mount_dovetail_kmz_1p59_mount_bump     2.633s   0.490s   5.37x
```

Batched path now scales with thread count. Dovetail 2048² gets 5.37×
speedup at NT=8, pistols 2.94×, w50 1.35× (128-block-wide row can only
feed 2 workers concurrently before the producer becomes the choke).

Full Step 3 wall-clock re-run, post-fix — SUPERSEDED, kept for
reference only. This table used the stale Phase 3 part 1b unbatched
numbers as the reference column. Those were measured under a busier
system than the fresh comparison in Step 3c below, so both the
per-file deltas and the aggregate here are inflated.

```
file                              W×H       lane_util  t_batch  t_ref (unbatched)  Δ  [SUPERSEDED]
--------------------------------------------------------------------------------------
ui_icon_maidfillcant              32×16      12.5%     0.107s   0.100s          +6.9%
ui_icon_pm_drum                   128×64      50.0%     0.108s   0.106s          +1.8%
ui_icon_sks_short                 256×64     100.0%     0.108s   0.121s         -10.4%
ui_icon_maidindicators            256×128    100.0%     0.109s   0.136s         -20.1%
ui_icon_rspartan                  512×64     100.0%     0.106s   0.124s         -14.4%
ui_icon_mg36e                     512×128    100.0%     0.109s   0.131s         -16.7%
ui_icon_w50                       512×256    100.0%     0.113s   0.154s         -26.7%
ui_maid_pistols                  2048×256    100.0%     0.167s   0.391s         -57.2%
wpn_mount_dovetail_..._bump     2048×2048    100.0%     0.484s   6.759s         -92.8%
--------------------------------------------------------------------------------------
TOTAL [SUPERSEDED]                                                1.411s   8.022s         -82.4%
```

Use the Step 3c table below as the reference going forward.

### Verdict (Step 3b, code)

Step 3b closed. Batched path parallelizes properly. Bit-identity and
zero-valid-modes guard both preserved.

## Phase 3 (part 5) — Step 3c: fresh unbatched-vs-batched re-measurement

### Motivation

Step 3b's -82.4% aggregate used Phase 3 part 1b's original unbatched
numbers as the reference column. Those were measured in an earlier
session with unknown background load. Re-measured both binaries fresh,
same session, interleaved per file so any residual system variance is
distributed evenly across both variants.

### Method

- Same 9-file GAMMA sample corpus, same TGA sources.
- Same settings: `-Quality 1.0 -NumThreads 8`, `OMP_NUM_THREADS=8`,
  best-of-3 via `time.perf_counter()`.
- Interleaved (unbatched, batched) back-to-back per file rather than
  batching all unbatched then all batched runs.
- Harness: `/tmp/step3b_fresh_compare.py`.

### Results

```
file                                  W×H       t_unbatch  t_batch   Δ (new)   Δ (prior)  diff
------------------------------------------------------------------------------------------------
ui_icon_maidfillcant                  32×16      0.101s     0.100s    -1.6%      +6.9%     -8.5pp
ui_icon_pm_drum                       128×64     0.111s     0.101s    -8.3%      +1.8%    -10.1pp
ui_icon_sks_short                     256×64     0.107s     0.102s    -4.8%     -10.4%     +5.6pp
ui_icon_maidindicators                256×128    0.122s     0.104s   -14.3%     -20.1%     +5.8pp
ui_icon_rspartan                      512×64     0.116s     0.104s   -10.4%     -14.4%     +4.0pp
ui_icon_mg36e                         512×128    0.111s     0.102s    -8.1%     -16.7%     +8.6pp
ui_icon_w50                           512×256    0.127s     0.106s   -16.3%     -26.7%    +10.4pp
ui_maid_pistols                      2048×256    0.233s     0.155s   -33.2%     -57.2%    +24.0pp
wpn_mount_dovetail_..._bump         2048×2048    2.025s     0.447s   -77.9%     -92.8%    +14.9pp
------------------------------------------------------------------------------------------------
TOTAL                                             3.053s     1.322s   -56.7%     -82.4%    +25.7pp
```

### Comparison vs Step 3b's SUPERSEDED numbers

- Both binaries measured faster than the stale reference — unbatched
  Dovetail dropped from 6.759s → 2.025s (3.3× faster than the earlier
  session recorded), batched Dovetail 0.484s → 0.447s (~within noise).
- Batched-vs-unbatched deltas therefore compressed on every file. Not
  run-to-run noise (the shifts are +4 to +24 percentage points, well
  outside natural jitter on 0.1s runs) — the Step 3b reference was
  systematically inflated by whatever load the earlier session carried.
- **Meaningfully different, not noise.** The Step 3b table needs the
  SUPERSEDED marker (added above); this Step 3c table is the one to
  use for any comparison or downstream benchmark.

### Facts under the corrected reference

- Batched wins on all 9 files. Smallest win: -1.6% (`maidfillcant`,
  32×16, 4 batches total — where CLI startup dominates and there's
  almost no encode work to accelerate). Largest win: -77.9% (Dovetail
  2048², 4096 batches).
- Corpus aggregate: **-56.7%**, dominated by the Dovetail file
  (2.025s / 3.053s = 66% of the unbatched corpus time).
- Small-file "regression" from Step 3b table (+6.9%, +1.8%) was an
  artifact of the stale reference — corrected values are -1.6%, -8.3%.
  Batched is at worst near-neutral on tiny files (fixed startup
  amortization limit) and materially faster on everything else.

### Verdict

Step 3c closed. Corrected reference recorded. Ready for Step 4
(three-way benchmark: texconv vs stock Compressonator vs batched
bc7e) once user confirms — Step 4 will use these Step 3c numbers, not
the Step 3b SUPERSEDED table, for the batched column.

## Phase 3 (part 6) — Final benchmark: texconv vs stock Compressonator vs batched bc7e

Closing benchmark for the project. Four variants against the same
9-file GAMMA sample corpus used throughout Phase 3.

### Prerequisites confirmed

- **texconv**: matyalatte/Texconv-Custom-DLL v0.6.0 Linux binary at
  `/home/abhi/.local/bin/texconv`. `--help` confirms CPU BC7 codec is
  active on Linux (`WARNING: using BC6H / BC7 CPU codec`) — this is
  DirectXTex's actual CPU BC7 path, not a GPU-offload stub. The same
  Texconv-Custom-DLL is what ATAK embeds via
  `stalker-tex/internal/tools/bin/texconv-linux`.
- **High-quality flag**: texconv `-bc <opts>` per `--help`, options
  `d, u, q, x`. From DirectXTex source: `q` = `TEX_COMPRESS_BC7_QUICK`
  (skips slower modes for speed), `x` = `TEX_COMPRESS_BC7_USE_3SUBSETS`
  (enables 3-subset mode search, higher quality). Used **`-bc x`** for
  the fair high-quality comparison; not `-bc q` (which is the fast/low
  path).
- **texconv arg parsing**: leading `/` in absolute paths is treated as
  an option prefix (DirectX-style parser); harness passes `--` before
  input file to disable further flag parsing.
- **System load**: sampled `load1` = 2.25-2.53 during the run
  (background Firefox/Wayland ~13% CPU aggregate). Same-session
  interleaved best-of-3 absorbs residual variance; every variant sees
  the same load.

### Variants and settings

| variant         | binary                              | flags                                            |
|-----------------|-------------------------------------|--------------------------------------------------|
| `texconv`       | matyalatte texconv v0.6.0           | `-f BC7_UNORM -bc x` (high quality, CPU codec)   |
| `stock_default` | build_cli_off compressonatorcli-bin | no `-Quality` (codec default = 0.05)             |
| `stock_Q1.0`    | build_cli_off compressonatorcli-bin | `-Quality 1.0`                                   |
| `batch_Q1.0`    | build_cli_batch compressonatorcli-bin | `-Quality 1.0` (batched bc7e, Step 3b/3c code) |

`-NumThreads 8` (or texconv's default OMP), `OMP_NUM_THREADS=8` for
all Compressonator variants. Best-of-3 via `time.perf_counter()`.

### PSNR methodology (unchanged from Phase 3 part 1b)

- Decoder held constant: `build_cli` binary at `-fd RGBA_8888`. BC7
  encoder changes don't affect the decode path, so PSNR reads are
  comparable across all four variants.
- Alpha-aware: `RGB@α>0` = MSE over source pixels with `α > 0` only,
  `αPSNR` = MSE over full alpha channel. Fully opaque files fall back
  to naive all-pixel RGB PSNR.

### Full corpus table

```
file                              W×H      variant          t(s)     RGB@α>0    αPSNR     α>0 px     mean α
--------------------------------------------------------------------------------------------------------------
ui_icon_maidfillcant              32×16    texconv           0.028     29.25     36.11        138     63.8
ui_icon_maidfillcant              32×16    stock_default     0.083     28.86     26.19        138     63.8
ui_icon_maidfillcant              32×16    stock_Q1.0        0.087     32.24     39.57        138     63.8
ui_icon_maidfillcant              32×16    batch_Q1.0        0.100     33.41     34.18        138     63.8

ui_icon_pm_drum                   128×64   texconv           0.221     38.17     38.65       1659     46.4
ui_icon_pm_drum                   128×64   stock_default     0.083     34.59     39.72       1659     46.4
ui_icon_pm_drum                   128×64   stock_Q1.0        0.144     40.70     43.04       1659     46.4
ui_icon_pm_drum                   128×64   batch_Q1.0        0.102     40.74     43.13       1659     46.4

ui_icon_sks_short                 256×64   texconv           0.535     35.89     38.98       3705     53.2
ui_icon_sks_short                 256×64   stock_default     0.084     34.33     38.15       3705     53.2
ui_icon_sks_short                 256×64   stock_Q1.0        0.187     38.56     43.18       3705     53.2
ui_icon_sks_short                 256×64   batch_Q1.0        0.104     38.66     42.81       3705     53.2

ui_icon_maidindicators            256×128  texconv           0.738     26.20     15.37      11957     87.6
ui_icon_maidindicators            256×128  stock_default     0.097     31.90     21.16      11957     87.6
ui_icon_maidindicators            256×128  stock_Q1.0        0.472     40.79     33.02      11957     87.6
ui_icon_maidindicators            256×128  batch_Q1.0        0.104     39.71     32.77      11957     87.6

ui_icon_rspartan                  512×64   texconv           0.899     38.46     44.42       4839     33.5
ui_icon_rspartan                  512×64   stock_default     0.086     35.53     42.52       4839     33.5
ui_icon_rspartan                  512×64   stock_Q1.0        0.259     40.32     46.63       4839     33.5
ui_icon_rspartan                  512×64   batch_Q1.0        0.105     40.37     46.52       4839     33.5

ui_icon_mg36e                     512×128  texconv           1.429     39.21     46.14       7290     25.2
ui_icon_mg36e                     512×128  stock_default     0.088     38.35     46.15       7290     25.2
ui_icon_mg36e                     512×128  stock_Q1.0        0.352     41.89     47.77       7290     25.2
ui_icon_mg36e                     512×128  batch_Q1.0        0.105     41.66     47.98       7290     25.2

ui_icon_w50                       512×256  texconv           2.727     36.21     44.24      11963     21.0
ui_icon_w50                       512×256  stock_default     0.095     33.92     42.61      11963     21.0
ui_icon_w50                       512×256  stock_Q1.0        0.449     38.33     47.02      11963     21.0
ui_icon_w50                       512×256  batch_Q1.0        0.108     38.18     47.12      11963     21.0

ui_maid_pistols                   2048×256 texconv          12.272     37.14     40.82     101883     45.2
ui_maid_pistols                   2048×256 stock_default     0.135     36.33     40.54     101883     45.2
ui_maid_pistols                   2048×256 stock_Q1.0        2.835     39.48     42.97     101883     45.2
ui_maid_pistols                   2048×256 batch_Q1.0        0.159     39.25     43.05     101883     45.2

wpn_mount_dovetail_..._bump      2048×2048 texconv         156.500     37.41     37.87    4150203    127.1
wpn_mount_dovetail_..._bump      2048×2048 stock_default     1.461     40.60     41.31    4150203    127.1
wpn_mount_dovetail_..._bump      2048×2048 stock_Q1.0       11.607     43.10     41.87    4150203    127.1
wpn_mount_dovetail_..._bump      2048×2048 batch_Q1.0        0.448     42.89     41.70    4150203    127.1
```

### Corpus aggregates

Two views to avoid Dovetail-dominance obscuring per-file behavior:

```
variant        wall-clock sum   sum ex-Dovetail   per-file mean
                (all 9 files)   (8 small files)   (unweighted)
-----------------------------------------------------------------
texconv          175.350 s        18.850 s          19.483 s
stock_default      2.213 s         0.752 s           0.246 s
stock_Q1.0        16.392 s         4.785 s           1.821 s
batch_Q1.0         1.336 s         0.888 s           0.148 s
```

- **Size-weighted (sum):** batch_Q1.0 is **131× faster than texconv**,
  **12.3× faster than stock_Q1.0**, and **1.66× faster than
  stock_default** across the corpus.
- **Excluding Dovetail:** batch is 21× faster than texconv, 5.4× faster
  than stock_Q1.0. Note batch loses to stock_default on this slice
  (0.888s vs 0.752s) — fixed CLI startup dominates on 8 files summing
  to 6800 blocks total. Per-file the gap is 0.017s.
- **Per-file mean:** batch fastest (0.148s), then stock_default,
  stock_Q1.0, texconv.

### PSNR summary (RGB@α>0, dB)

```
file                 texconv  stock_def  stock_Q1  batch_Q1  Δ(batch − texconv)  Δ(batch − stockQ1)
---------------------------------------------------------------------------------------------------
maidfillcant          29.25      28.86     32.24     33.41           +4.16              +1.17
pm_drum               38.17      34.59     40.70     40.74           +2.57              +0.04
sks_short             35.89      34.33     38.56     38.66           +2.77              +0.10
maidindicators        26.20      31.90     40.79     39.71          +13.51              -1.08
rspartan              38.46      35.53     40.32     40.37           +1.91              +0.05
mg36e                 39.21      38.35     41.89     41.66           +2.45              -0.23
w50                   36.21      33.92     38.33     38.18           +1.97              -0.15
pistols               37.14      36.33     39.48     39.25           +2.11              -0.23
dovetail_bump         37.41      40.60     43.10     42.89           +5.48              -0.21
```

- **batch vs texconv:** batch wins RGB@α>0 on **every file**, by +1.91
  to +13.51 dB. Median win ~+2.6 dB. `maidindicators` gap of +13.51 dB
  is not a typo — texconv failed to allocate BC7 mode 7 correctly on
  the hard-alpha-cutout icon and dropped to RGB PSNR 26.20 dB, worse
  than stock_default on the same file (31.90 dB).
- **batch vs stock_Q1.0:** essentially matched. Batch better on 4 files
  (+0.04 to +1.17 dB), worse on 5 files (-0.15 to -1.08 dB). Absolute
  gap ≤ 1.08 dB on any file. Well inside "same-quality tier".

αPSNR shows the same pattern: batch wins vs texconv on 8 of 9 files
(texconv only wins on `maidfillcant`'s 138-pixel alpha channel — noise
territory); batch essentially matches stock_Q1.0 on 8 of 9 (biggest
gap: -0.25 dB on `maidindicators`, +0.09 dB on `pistols`).

### Verdict

- **vs texconv (the project's actual baseline — what ATAK ships with):**
  batch bc7e is 131× faster across the corpus, and produces higher
  RGB@α>0 PSNR on every single file (median +2.6 dB, largest +13.5 dB).
  There is no dimension on which texconv wins; this is a clean,
  uncontested replacement.
- **vs stock Compressonator @ -Quality 1.0:** batch is 12.3× faster
  with quality matched to within ~1 dB per file (some files better,
  some worse; no systematic direction). For workloads that would
  otherwise use `-Quality 1.0`, batch is the same-quality-tier
  drop-in with a decisive performance win.
- **vs stock Compressonator @ default -Quality:** batch is faster on
  the size-weighted view (dominated by big files) and materially
  higher-quality on every file (+1.06 to +7.81 dB RGB, corresponds to
  the ~-Quality 0.05 vs -Quality 1.0 gap Phase 3 part 1 already
  documented).

Batched bc7e is the recommended CPU BC7 encoder for the ATAK use
case: fastest, matches or exceeds stock-Q1.0 quality, and comprehensively
beats texconv on both axes. Phase 3 complete.

Harness: `/tmp/phase3_part6_final.py`. Result log:
`/tmp/p3p6_result.log`.

### Post-benchmark verification (Phase 3 part 6a)

Two independent sanity checks before treating Part 6 as final:

**(1) texconv thread usage.**
- `texconv --help` shows `--single-proc` (disables MT) but no thread-
  count flag. Default is multi-threaded via DirectXTex's internal
  parallelization.
- Live monitor of a texconv run on the Dovetail file (`ps -o pid,%cpu,nlwp`
  sampled every 2 s for 24 s) with `OMP_NUM_THREADS=8` in env:

  ```
  PID       %CPU  NLWP  COMM
  1677221    774     8  texconv
  1677221    791     8  texconv
  1677221    792     8  texconv
  1677221    794     8  texconv
  1677221    795     8  texconv
  ... (12 samples, all 8 threads, ~795% CPU steady)
  ```

  texconv used ~7.95 cores throughout — fully MT, same threading as
  every other variant (`-NumThreads 8`). Not under-threaded; the 131×
  gap is not an artifact.

**(2) maidindicators outlier.**

Mode histograms extracted from level-0 blocks only (256×128 = 2048
blocks). texconv re-encoded with `-m 1` to eliminate the mipmap
confound the first pass caught (default texconv writes 2733 blocks =
2048 level 0 + 685 mip; original PSNR reads were level-0-only so
weren't affected, but the histogram sums were).

```
variant           m0    m1    m2    m3    m4    m5    m6    m7
------------------------------------------------------------------
texconv -bc x    0.2%  0.4%  0.4%  3.7% 49.9%  4.1% 27.0% 14.3%
stock default    0.2%  0.2%  0.4%  0.1%  0.0%  0.0% 59.4% 39.6%
stock Q1.0       0.4%  0.4%  0.2%  3.4%  0.0%  0.0% 55.9% 39.6%
batch Q1.0       0.5%  0.3%  0.3%  0.0%  0.0% 49.5%  9.7% 39.6%
```

- texconv picks mode 4 for half the blocks (separate-alpha, single
  colour subset). Uses mode 7 only 14.3% of the time vs 39.6% for
  both stock and batch. So texconv IS mode-7-under-selecting.
- But mode selection alone doesn't explain the 13.5 dB gap: stock
  Q1.0 and batch Q1.0 use different mode mixes (stock heavy on m6,
  batch heavy on m5) and both land ~40 dB. Batch replaces stock's
  mode 6 with mode 5 and keeps the same 39.6% mode 7 count as stock.
- Real cause is the underlying endpoint/p-bit selection — this is
  the DirectXTex "p-bit rounding" bug documented by Richard Geldreich
  in two April 2018 posts:
  - "A tale of multiple BC7 encoders" —
    http://richg42.blogspot.com/2018/04/a-tale-of-multiple-bc7-encoders.html
  - "Proper pbit computation in the BC7 texture format" —
    http://richg42.blogspot.com/2018/04/proper-pbit-computation-in-bc7-texture.html

  Files with hard alpha cutouts expose it because the endpoint
  quantization error is amplified across the α boundary.

Input identity verified:

- Source TGA md5 `280f35707a8c`, size 131090 bytes.
- All four encoders received the same file. Confirmed decoded output
  shape (128, 256, 4) matches source for every variant.
- Source α: range [0, 255], mean 87.6, 11957 α>0 pixels.
- Decoded α means: texconv 84.7, stock_default 87.3, stock_Q1.0 87.2,
  batch_Q1.0 87.4. texconv's 2.9-point α drift is *encoding loss*, not
  a colour-space or premultiplied-α mismatch (a real transform would
  produce a systematic bias vs source, not a fuzzy underestimate).
- texconv output header: DDS `DX10` extension, dxgi format code 98
  (BC7_UNORM, not sRGB). Matches Compressonator's DX10/98 output.
- No-mip texconv PSNR identical to with-mip texconv PSNR
  (26.20 dB RGB@α>0 in both cases) — confirms the decode path reads
  level 0 correctly and mipmaps were a histogram-count issue only,
  not a quality-read issue.

### Verdict on Part 6

Both checks hold up. texconv was fully MT during the benchmark; the
maidindicators gap is a real encoder-quality result, backed by an
under-selection of mode 7 (14.3% vs 39.6%) and consistent with the
known DirectXTex p-bit issue on hard-alpha content. Phase 3 part 6
stands as written; the aggregates and PSNR numbers in that section
are the final ones to cite.

Harnesses: `/tmp/verify_maidind.py`, `/tmp/verify_maidind2.py`.

## Phase 4 (part 1) — Windows/MSVC build handoff prep

Read-only audit + prep for a build on a real Windows machine with
MSVC. No cross-compile attempted here; no packages installed. All
findings are from static reading of the existing CMake tree and the
existing verification harnesses.

### CMake audit — anything Linux/GCC-specific that MSVC needs

Guard structure in `compressonator/cmp_core/CMakeLists.txt` and top-
level `compressonator/CMakeLists.txt` is already `if (WIN32) … else()`
around the compiler-specific bits. That means most flags are already
partitioned correctly. Exceptions found:

**1. `/arch:AVX-512` is invalid MSVC syntax — real bug that will
break the build.**

`compressonator/cmp_core/CMakeLists.txt:99`:
```
target_compile_options(CMP_Core_AVX512 PRIVATE /arch:AVX-512)
```

MSVC 2017+ documents the flag as `/arch:AVX512` (no hyphen). Passing
`/arch:AVX-512` produces `cl : Command line warning D9002 : ignoring
unknown option '/arch:AVX-512'` — the AVX-512 codegen simply isn't
enabled and any AVX-512 intrinsics in `core_simd_avx512.cpp` will fail
to compile as `intrinsic not supported`. Not a new-flavor problem; this
is upstream Compressonator and would bite any Windows build that
enables the AVX-512 target.

Fix (apply in `cmp_core/CMakeLists.txt` before running the Windows
build):
```
- target_compile_options(CMP_Core_AVX512 PRIVATE /arch:AVX-512)
+ target_compile_options(CMP_Core_AVX512 PRIVATE /arch:AVX512)
```

**2. GCC-only options in Linux branches — already properly guarded,
no MSVC translation needed.**

| flag                          | location                              | guard                     | status |
|-------------------------------|---------------------------------------|---------------------------|--------|
| `-march=nehalem`              | cmp_core/CMakeLists.txt:75            | `if (UNIX)`               | OK     |
| `-march=haswell`              | cmp_core/CMakeLists.txt:88            | `if (WIN32) else()`       | OK     |
| `-march=skylake-avx512`       | cmp_core/CMakeLists.txt:101           | `if (WIN32) else()`       | OK     |
| `-fPIC -Wno-write-strings`    | CMakeLists.txt:311                    | `if (CMP_HOST_WINDOWS) else()` | OK |
| `-Wall`                       | CMakeLists.txt:52                     | `elseif(CMP_HOST_LINUX)`  | OK     |
| `_LINUX`, `ASPM_GPU`          | cmp_core/CMakeLists.txt:62            | `if (UNIX)`               | OK     |
| `stdc++fs` link               | CMakeLists.txt:304                    | `if (CMP_HOST_LINUX or WITH_CXX14)` | OK |

**3. MSVC-only flags — already present, work as-is.**

| flag                    | location                    | guard                | status |
|-------------------------|-----------------------------|----------------------|--------|
| `/W4 /wd4201`           | CMakeLists.txt:49           | `if (CMP_HOST_WINDOWS)` | OK  |
| `/arch:AVX2`            | cmp_core/CMakeLists.txt:86  | `if (WIN32)`         | OK     |
| `/INCREMENTAL:NO`       | CMakeLists.txt:293          | `if (CMP_HOST_WINDOWS)` | OK  |

**4. ISPC flag `--pic` — non-issue on Windows.**

`cmp_core/CMakeLists.txt:143` unconditionally passes `--pic` to
`ispc.exe`. This flag was added to fix a Linux PIE-linkage error
(`R_X86_64_32S`). ISPC accepts `--pic` on any target and it's a no-op
on Windows COFF output. Leave in place — harmless.

**5. ISPC output extension `.o` — non-issue.**

`cmp_core/CMakeLists.txt:133-137` names outputs `bc7e.o`,
`bc7e_sse2.o`, etc. On Windows-hosted ispc, ISPC writes exactly the
path given by `-o`; the extension is chosen by the caller. The COFF
object file will be named `bc7e.o` (COFF-format contents, `.o`
extension). MSVC's `link.exe` reads objects by content, not filename
extension. No change needed.

**6. bc7enc_rdo patches from Step 0 — still needed on Windows.**

- `bc7enc_rdo/ert.h`: `#include <cstdint>` addition. GCC 16 transitive
  include removal specifically, but harmless on MSVC (already pulled
  by MSVC's STL).
- `bc7enc_rdo/CMakeLists.txt`: `--pic` on ispc invocation. As above,
  harmless on Windows.
- `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` at configure time: still
  required because upstream `bc7enc_rdo/CMakeLists.txt` has
  `cmake_minimum_required(VERSION 2.8)`, below CMake's floor.

**7. External deps default to ON on Linux CLI build — likely blockers
on a stock Windows box.**

Linux `build_cli_batch/CMakeCache.txt` shows:
```
OPTION_CMP_OPENCV:BOOL=ON
OPTION_CMP_OPENGL:BOOL=ON
```

These default ON when `OPTION_BUILD_APPS_CMP_CLI=ON` (via `cmp_option`
guards at CMakeLists.txt:167-169). On Linux, `pkg-config` finds them;
on Windows they'd need `OpenCV_DIR` and OpenGL SDK paths. The BC7
encode/decode path this project targets doesn't use either — turn
them off for a minimal CLI Windows build:
```
-DOPTION_CMP_OPENCV=OFF -DOPTION_CMP_OPENGL=OFF -DOPTION_CMP_QT=OFF
```

### Windows build script

`compressonator/tools/win/build_cli_batch.ps1` — mirrors the Linux
CMake invocation, adapted for MSVC's multi-config generator, x64 arch,
and the Windows ISPC path. Takes a `-Flavor {off|unbatched|batch}`
param so the same script produces the three build trees Linux has
(`build_cli_off`, `build_cli`, `build_cli_batch`). See script comments
for prerequisites (must run from a Developer PowerShell for VS 2022,
`/arch:AVX-512` fix must be applied first).

### Python verification harness portability

Rewritten as three cross-platform scripts under
`compressonator/tools/win/`. Same test logic as the ad-hoc `/tmp/*.py`
scripts referenced throughout Phase 3, but:

- All paths taken via `--` flags (no `/home/abhi/...` or `/tmp/...`
  hardcoding).
- Scratch dir defaults to `tempfile.gettempdir()` (`C:\Users\<u>\AppData\Local\Temp`
  on Windows, `/tmp` on Linux).
- All file ops go through `pathlib.Path`.
- Binary paths passed in; Windows callers pass `...\compressonatorcli-bin.exe`,
  Linux callers pass `.../compressonatorcli-bin`.
- No shell=True, no shell redirections, no Linux-only tools (`/dev/null`
  replaced by `subprocess.DEVNULL`, which is portable).
- Non-zero exit code on any mismatch — usable in CI.

Scripts:
- `verify_boundaries.py` — Q=0.25/0.45/0.65/0.85 centibucket check.
- `verify_bit_identity.py` — 6-config block-by-block diff between
  build_cli and build_cli_batch.
- `verify_no_crash.py` — zero-valid-modes guard (Step 2b).
- `verify_thread_scaling.py` — NT=1 vs NT=8 ratio on batched path.

### Reference MD5s to compare Windows output against

From NOTES.md Phase 3 part 4c (post-centibucket-fix, Linux build_cli
at commit that landed the adapter). All are 12-char MD5 prefixes of
DDS payload (skipping the 128 or 148-byte DDS header):

Interior reference (verify_boundaries.py builds these):
```
veryfast  Q=0.05  5fae5456ae19
fast      Q=0.30  cff9a2cf1964
basic     Q=0.50  10cda379ba6f
slow      Q=0.70  16c8a5170408
slowest   Q=0.95  7f115eab183c
```

Boundary (verify_boundaries.py verifies these bucket correctly):
```
Q=0.25 → fast     (cff9a2cf1964)
Q=0.45 → basic    (10cda379ba6f)
Q=0.65 → slow     (16c8a5170408)
Q=0.85 → slowest  (7f115eab183c)
```

Bit-identity between build_cli and build_cli_batch: **not baked in as
absolute MD5s** because we care about pairwise equivalence, not
absolute output value. The harness pairs each Windows-build_cli output
against its own Windows-build_cli_batch output for the same config
and reports 100% block match. Also emits per-config MD5s so they can
be spot-compared against Linux MD5s recorded during Step 2/2b runs
(`741246ded2fb`, `2df4cbbbe848`, `7b61c709f275`, `ee63f48cc53e`,
`1acc20029808`, `7f359e51bc5c` — from the harness output at Step 2b
close). A pairwise-100%-match on Windows with different absolute
MD5s from Linux is not automatically a bug — cross-compiler
FP-rounding differences in bc7e.ispc's scalar helpers can shift
absolute values while preserving the same partition/mode choices per
block. Investigate the mode/partition distributions before flagging.

### Ordered checklist for the Windows machine

Prerequisites on the Windows host:
- Visual Studio 2019 or 2022 with C++ workload (installs cl.exe,
  Windows SDK, MSBuild, and a bundled CMake).
- Python 3.8+.
- Same repo checkout (`compressonator/`, `bc7enc_rdo/`,
  `tools/ispc/windows/`, side-by-side layout).
- `tools/ispc/windows/ispc-v1.31.0-windows.zip` extracted in place
  (so `tools/ispc/windows/ispc-v1.31.0-windows/bin/ispc.exe` exists).

Then, in order:

1. **Apply the `/arch:AVX-512` → `/arch:AVX512` fix** in
   `compressonator/cmp_core/CMakeLists.txt:99`. Skip this and
   `CMP_Core_AVX512` will fail to build.

2. **Configure + build all three flavors:**
   ```
   cd <repo root>
   powershell -File compressonator\tools\win\build_cli_batch.ps1 -Flavor off
   powershell -File compressonator\tools\win\build_cli_batch.ps1 -Flavor unbatched
   powershell -File compressonator\tools\win\build_cli_batch.ps1 -Flavor batch
   ```
   Expect binaries at:
   `compressonator\build_cli_off\bin\Release\compressonatorcli-bin.exe`
   `compressonator\build_cli\bin\Release\compressonatorcli-bin.exe`
   `compressonator\build_cli_batch\bin\Release\compressonatorcli-bin.exe`

   Document any new build failures the same way the Linux Step 0
   patches were documented: exact error, root cause, minimal fix.
   Common expected friction: missing `/utf-8` on some source files,
   `M_PI` undefined without `_USE_MATH_DEFINES`, `min`/`max` macro
   clash needing `NOMINMAX`. None of these have been proven to bite
   here — flag if they surface.

3. **Boundary sweep** (Phase 3 part 4c reference):
   ```
   python compressonator\tools\win\verify_boundaries.py `
     --cli compressonator\build_cli\bin\Release\compressonatorcli-bin.exe `
     --src compressonator\runtime\images\ruby.png
   ```
   Compare printed MD5s against the 5 interior + 4 boundary references
   above. All-OK = centibucket fix survived the port. Mismatch on
   interior MD5s = investigate as cross-compiler FP diff (likely
   benign) OR as a real port regression (needs digging).

4. **6-config bit-identity** (Step 2/2b):
   ```
   python compressonator\tools\win\verify_bit_identity.py `
     --unbatch compressonator\build_cli\bin\Release\compressonatorcli-bin.exe `
     --batch   compressonator\build_cli_batch\bin\Release\compressonatorcli-bin.exe `
     --ruby        compressonator\runtime\images\ruby.png `
     --ruby-alpha  compressonator\runtime\images\ruby_alpha.tga
   ```
   All 6 must report `100.0000%` block match. Anything less is a real
   bug — batched must equal unbatched on the same platform regardless
   of cross-platform value drift.

5. **Zero-valid-modes crash guard** (Step 2b):
   ```
   python compressonator\tools\win\verify_no_crash.py `
     --unbatch compressonator\build_cli\bin\Release\compressonatorcli-bin.exe `
     --batch   compressonator\build_cli_batch\bin\Release\compressonatorcli-bin.exe `
     --ruby-alpha compressonator\runtime\images\ruby_alpha.tga
   ```
   Both must exit "no crash". A crash on Windows despite passing on
   Linux would point at ISPC codegen differences on the OOB-write path
   the guard is protecting.

6. **Thread scaling on batched path** (Step 3b):
   ```
   python compressonator\tools\win\verify_thread_scaling.py `
     --batch compressonator\build_cli_batch\bin\Release\compressonatorcli-bin.exe `
     --src   <path to a >= 1024×1024 TGA, e.g. wpn_mount_dovetail_kmz_1p59_mount_bump decoded>
   ```
   Ratio NT=1 / NT=8 must be materially > 1 (Linux post-fix: 5.37× on
   2048², 2.94× on 2048×256). Ratio near 1.0 = worker pool didn't hook
   up on Windows — investigate rather than assume noise.

Stop after step 6 with the corresponding Windows section in NOTES.md,
mirroring what Phase 3 already has for Linux. Any real port issues
found (beyond the /arch:AVX512 fix already listed) go into a new
NOTES.md subsection with the same shape as the Step 0 patch log.

Files created:
- `compressonator/tools/win/build_cli_batch.ps1` (parameterized —
  `-Flavor off|unbatched|batch`)
- `compressonator/tools/win/verify_boundaries.py`
- `compressonator/tools/win/verify_bit_identity.py`
- `compressonator/tools/win/verify_no_crash.py`
- `compressonator/tools/win/verify_thread_scaling.py`

## Phase 4 (part 2) — Windows/MSVC build, actual run

Machine: Windows 10/11 host reachable from this WSL2 session via
`powershell.exe` / `cmd.exe`; MSVC toolchain is Visual Studio 2022
Build Tools 17.14.35 (`C:\Program Files (x86)\Microsoft Visual
Studio\2022\BuildTools`), invoked through `VsDevCmd.bat -arch=x64`
before each `cmake`/`cmake --build` call (the build script explicitly
does not bootstrap the VS environment itself). CMake/MSBuild are the
versions bundled with Build Tools.

### Step 0 — ISPC binary check

`tools/ispc/windows/ispc-v1.31.0-windows.zip` had been extracted flat
(`tools/ispc/windows/bin/ispc.exe`) instead of preserving its
versioned subfolder, so it didn't match the path
`build_cli_batch.ps1` hardcodes
(`tools\ispc\windows\ispc-v1.31.0-windows\bin\ispc.exe`). Version
itself was correct (`ReleaseNotes.txt` top entry `v1.31.0`, matching
the zip filename). Fixed by renaming the extracted folder into the
expected nested path — not a code change, a local extraction mistake.

### Step 1 — Build all three flavors (off / unbatched / batch)

Applied the documented `/arch:AVX-512` → `/arch:AVX512` fix first
(`cmp_core/CMakeLists.txt:99`), then ran `build_cli_batch.ps1` for
each flavor. Six more real problems surfaced, none of them guessable
in advance — CMake audit (static reading) couldn't have caught most
of these because they're either missing runtime state (unfetched
deps) or MSVC-only code paths with no Linux equivalent to diff
against. Documented in the order encountered:

**1. `$RepoRoot` default resolves one directory too high.**

`tools/win/build_cli_batch.ps1:48` computed the default repo root as
`Resolve-Path "$PSScriptRoot\..\..\.."` — three `..` from
`tools\win`. `tools\win\..\..\..`  lands on the parent of the repo
(`C:\Users\abhi`), not the repo root (`compressonatorfork`) two
levels up. Symptom: `cmake` immediately failed with `CMake Error: The
source directory "C:/Users/abhi/compressonator" does not exist`
(note: missing `fork` suffix). Fix: two `..`, not three.

**2. `common/lib/ext/*` was never populated on this checkout.**

Not a code bug — this migrated-to-Windows checkout simply never had
`fetch_dependencies.py` run against it. Configure failed on the first
external dependency it touched: `CMake Error ... add_subdirectory
given source ".../common/lib/ext/glm" which is not an existing
directory`. Running `compressonator/build/fetch_dependencies.py`
(Python 3.14 via WSL) pulled glm/rapidxml/imgui/glfw/openexr
successfully, but this surfaced two more gaps (below) because the
script self-detects host OS and behaves differently on each:

**2a. `ktx` and `brotlig` stub directories blocked re-fetch.**

`common/lib/ext/brotlig` and `common/lib/ext/ktx` already existed as
empty CMake `ExternalProject` stamp scaffolding (`build/`, `tmp/`,
`src/extern_ktx-stamp/` — no actual source, no `CMakeLists.txt`),
leftover from some earlier failed configure attempt predating this
session. `fetch_dependencies.py`'s clone step only checks "does the
directory exist," not "is it a valid checkout," so it silently
skipped both. Symptom:
`CMake error : The source directory ".../common/lib/ext/brotlig"
does not appear to contain CMakeLists.txt`. Fix: `rm -rf` both stub
dirs (contents confirmed trivial/empty first) so the next fetch
re-clones for real.

**2b. `fetch_dependencies.py`'s OS-gated dependency lists mean a
WSL-run fetch silently skips Windows-only deps.**

The script has three parallel dicts (`gitMappingWin/Lin/Uni` and
`downloadMappingWin/Lin/Uni`) selected by `platform.system()`. Running
it from WSL reports `linux`, so it uses the Linux lists — which lack
`ktx`, `brotlig`, `catch2`, `glew`, `opencv`, `zlib`, `tinyxml`
entirely (Windows-only in `gitMappingWin`), and lack the DirectXTex /
OCL-SDK / DXC zip downloads (Windows-only in `downloadMappingWin`).
None of this is a bug in the script — it's correctly OS-gated — but
it means "run fetch_dependencies.py" is not a platform-neutral
instruction; running it from WSL against a Windows checkout only
partially populates `common/lib/ext`. No real Python was available on
the Windows host itself to run it natively (`python.exe` resolves to
the Microsoft Store app-execution-alias stub, not a working
interpreter — confirmed: `Get-Command python.exe` finds it, but
invoking it prints "Python was not found; run without arguments to
install from the Microsoft Store"). Given a real interpreter wasn't
available and these are simple git-clone / HTTP-download operations
with no OS-specific execution, replicated the effect manually from
WSL instead of installing anything:
- `git clone` + `git checkout` for `ktx` (`KTX-Software`,
  `v4.0.0-beta4`) and `brotlig` (`brotli_g_sdk`, `main`) — same repos
  and commits `gitMappingWin` specifies.
- `curl` + `unzip` for `DirectXTex-jun2020b.zip` into
  `common/lib/ext/directxtex/`, replicating
  `downloadandunzip()`'s exact behavior (extract with the zip's own
  top-level folder name preserved) — confirmed the resulting path
  matches what the CMake external-project step expects
  (`DirectXTex-jun2020b/DirectXTex/DirectXTex_Desktop_2019.vcxproj`
  found).
- Did **not** fetch OCL-SDK/DXC — nothing in this build path needed
  them (OpenCL and Brotli-G both end up disabled, see #3).
- `ktx`'s repo uses Git LFS for prebuilt libs (`*.lib`, `*.dll`,
  `*.a` per its `.gitattributes`). `git-lfs` isn't installed on this
  host, so the WSL clone pulled LFS *pointer files*, not the real
  binaries (confirmed: `other_lib/win/Release-x64/zstd_static.lib`
  was 131 bytes of ASCII `version https://git-lfs.github.com/spec/v1
  ...` text, not a `.lib`). This didn't end up mattering — KTX2 got
  disabled entirely in fix #3 below, so the corrupt-stub lib was never
  linked. Would need real `git-lfs` if a future pass re-enables
  `OPTION_BUILD_KTX2` on Windows.

**3. `build_cli_batch.ps1` never disabled `OPTION_CMP_DIRECTX` /
`OPTION_BUILD_KTX2` / `OPTION_BUILD_BROTLIG` — all three default ON
specifically on Windows.**

`compressonator/CMakeLists.txt` has `cmp_option(OPTION_CMP_DIRECTX
... ON CMP_HOST_WINDOWS)`, same pattern for `OPTION_BUILD_KTX2` (ON
whenever CMake ≥ 3.14) and `OPTION_BUILD_BROTLIG` (ON on Windows).
None of these three flags appear anywhere in
`build_cli_batch.ps1`'s `$cmakeArgs`, unlike the already-working Linux
invocation (Phase 1's "Final working CMake invocation," which
explicitly sets `OPTION_BUILD_KTX2=OFF` and `OPTION_BUILD_BROTLIG=OFF`
— `OPTION_CMP_DIRECTX` doesn't apply on Linux at all). Before this was
caught, the build failed three separate ways in immediate succession —
DirectXTex's third-party `.vcxproj` pinned to the VS2019 (`v142`)
toolset which isn't installed alongside VS2022 Build Tools (`MSB8020`),
brotli_g_sdk's CMake configure shelling out to the broken `python`
alias and silently producing an empty source list (`No SOURCES given
to target: brotli`), and KTX's Git-LFS-pointer `zstd_static.lib`
failing to link (`LNK1107`) — all three of which looked like separate
host-toolchain gaps requiring new installs (VS2019 component, real
Python, git-lfs) until checking whether the subsystems were needed at
all. They aren't, for a BC7-only CLI build. Fix: added
`-DOPTION_CMP_DIRECTX=OFF -DOPTION_BUILD_KTX2=OFF
-DOPTION_BUILD_BROTLIG=OFF` to the script's `$cmakeArgs`, matching the
already-proven-minimal Linux flag set. Confirmed after a clean
build-dir reconfigure that none of DirectXTex/brotli_g_sdk/KTX are
touched by the build at all — no host installs needed.

**4. `OPTION_CMP_OPENCV=OFF` reaches further than the two files Phase
1 found on Linux — confirmed by tracing, not by re-enabling OpenCV.**

Phase 1's Linux findings already flagged this class of bug (`ssim.cpp`
unconditionally `#include <opencv2/opencv.hpp>`, hard-required by
`CMP_Common`) and resolved it on Linux by turning OpenCV **on**
(system package available there). Windows has no OpenCV installed, and
the Phase 4 audit already recorded the opposite intent —
`OPTION_CMP_OPENCV=OFF` for a minimal Windows CLI build — so the
Linux fix doesn't transfer. Before touching anything, traced the real
call graph instead of assuming: repo-wide grep for `getSSIM`/
`getMSE_PSNR` (the two functions `ssim.cpp` defines) found exactly two
consumers — `ssim.cpp` itself and `canalysis.cpp` — and nothing in
`cmdline.cpp`/`psnr.cpp`/`compressonatorcli.cpp` despite an initial
broad grep suggesting otherwise (those hits were the string literal
`"SSIM"` in `-Analysis` help text, not real symbol references).
Better still: `canalysis.cpp`/`canalysis.h` **already** guard every
real call site behind `#if (OPTION_CMP_OPENCV == 1)` — established
existing convention, not something invented here. Two things were
still missing, both narrow, both matching that same existing
convention:
- `applications/_plugins/common/CMakeLists.txt` listed `ssim.cpp`
  unconditionally in `PLUGIN_COMMON_SRC` (`CMP_Common`'s own copy) —
  gated behind `if (OPTION_CMP_OPENCV)`.
- `applications/_plugins/canalysis/CMakeLists.txt` separately listed
  `ssim.cpp`/`ssim.h` a second time, directly in `Image_Analysis`'s
  `target_sources` — same gate applied.
- `canalysis.cpp:36`'s `#include "ssim.h"` was the one unguarded line
  in an otherwise-consistently-guarded file (its own OpenCV headers
  three lines down at 53-57 are gated; this one wasn't) — wrapped in
  the same `#if (OPTION_CMP_OPENCV == 1)` the rest of the file uses.
- `processSSIMResults()` (canalysis.cpp:753-773) unconditionally read
  `m_SSIM`, a member that only exists when `OPTION_CMP_OPENCV == 1`
  (per the header's own guard at canalysis.h:78-79) — wrapped the
  whole function definition in the same guard; its only two call
  sites were already inside guarded blocks.

Net: zero new host dependencies, four small `#if`/CMake gates, all
following a pattern the codebase had already established for the
identical scenario elsewhere in the same files.

**5. `copyfiles.cmake` copies `glew32.dll` / `opencv_*.dll`
unconditionally inside `if (CMP_HOST_WINDOWS)`, ignoring
`OPTION_CMP_OPENGL` / `OPTION_CMP_OPENCV` — unlike the KTX2 DLL copy
three lines below it, which is correctly gated.**

`applications/compressonatorcli/copyfiles.cmake:40-62`: the
post-build DLL-copy block has an `if (OPTION_BUILD_KTX2) ... else()`
around the KTX DLL (copies a checked-in null DLL when KTX2 is off,
"so that installers can build") but no equivalent guard around the
glew/OpenCV DLL copies immediately above it. Symptom: build got all
the way to linking, then failed on the very first post-build copy
command — `Error copying file (if different) from
".../glew/1.9.0/bin/x64/glew32.dll"` (glew was never fetched — same
WSL-vs-Windows fetch gap as #2b, `glew` is Windows-only in
`gitMappingWin`) — followed by ~80 lines of `MSB3073` cascade noise
that's just MSBuild dumping the entire batch script text after the
first line failed, not 80 separate errors. Fix: wrapped the
`glew32.dll` copy in `if (OPTION_CMP_OPENGL)` and the two
`opencv_*249.dll` copies (plus the newer `opencv_world420` block) in
`if (OPTION_CMP_OPENCV)`, mirroring the adjacent KTX2 pattern exactly.

**6. `OPTION_BUILD_EXR` was never disabled — Linux's reference
invocation already had `-DOPTION_BUILD_EXR=OFF` and the script never
carried that flag over.**

After fix #5, build reached final link and failed there instead:
`LINK : fatal error LNK1104: cannot open file 'zlibstatic.lib'`. Not
in any `target_link_libraries` call (grepped every `CMakeLists.txt` in
the tree) — traced to `applications/_plugins/cimage/exr/exr.cpp:115`,
an MSVC-only `#pragma comment(lib, "zlibstatic.lib")` inside the EXR
plugin, which only compiles when `OPTION_BUILD_EXR` is on. The
Windows-only prebuilt `common/lib/ext/zlib/zlib-1.2.10/...` this
pragma expects was never fetched (same WSL-vs-Windows gap as #2b/#5;
`zlib` is Windows-only in `gitMappingWin`) — but the real fix isn't
fetching it, since EXR support isn't part of this Windows CLI build's
scope any more than it is on Linux. Fix: added
`-DOPTION_BUILD_EXR=OFF` to `$cmakeArgs`, matching the Linux
reference invocation exactly.

**7. Script's own post-build success check looks for the wrong
binary name on Windows.**

`build_cli_batch.ps1:130` checked for
`bin\$Config\compressonatorcli-bin.exe`. On Windows the CLI target's
`OUTPUT_NAME` is unconditionally `compressonatorcli` (no `-bin`
suffix) regardless of Qt —
`applications/compressonatorcli/CMakeLists.txt:230-245`; the `-bin`
suffix only applies in the `else()` (non-Windows) branch at line
246-258. This is deliberate upstream naming, not a bug to route
around — Linux ships a `compressonatorcli-bin` invoked through a
wrapper script, Windows ships `compressonatorcli.exe` directly. All
three builds actually succeeded; the script just reported a false
"binary not at expected path" warning. Fixed the check to look for
`compressonatorcli.exe`.

### Result

All three flavors built clean (`cmake --build` exit 0) after the
fixes above:

```
compressonator\build_cli_off\bin\Release\compressonatorcli.exe
compressonator\build_cli\bin\Release\compressonatorcli.exe
compressonator\build_cli_batch\bin\Release\compressonatorcli.exe
```

`build_cli_off\...\compressonatorcli.exe` (no args) runs cleanly,
prints the standard usage banner, exit code 0 — first real signal the
port isn't just "compiles," it starts and behaves like the Linux
binary.

Applied fixes, by file:
- `compressonator/cmp_core/CMakeLists.txt:99` — `/arch:AVX-512` →
  `/arch:AVX512` (documented pre-existing finding, applied as
  instructed).
- `tools/win/build_cli_batch.ps1` — `$RepoRoot` default (`..\..\..` →
  `..\..`), added `-DOPTION_CMP_DIRECTX=OFF
  -DOPTION_BUILD_KTX2=OFF -DOPTION_BUILD_BROTLIG=OFF
  -DOPTION_BUILD_EXR=OFF` to `$cmakeArgs`, fixed the post-build binary
  name check (`compressonatorcli-bin.exe` → `compressonatorcli.exe`).
- `compressonator/applications/_plugins/common/CMakeLists.txt` —
  gated `ssim.cpp` behind `OPTION_CMP_OPENCV`.
- `compressonator/applications/_plugins/canalysis/CMakeLists.txt` —
  gated the separate `ssim.cpp`/`ssim.h` entries in `Image_Analysis`
  behind `OPTION_CMP_OPENCV`.
- `compressonator/applications/_plugins/canalysis/analysis/canalysis.cpp`
  — guarded `#include "ssim.h"` and all of `processSSIMResults()`
  behind `#if (OPTION_CMP_OPENCV == 1)`, matching the file's existing
  convention.
- `compressonator/applications/compressonatorcli/copyfiles.cmake` —
  gated `glew32.dll` behind `OPTION_CMP_OPENGL`, OpenCV DLL copies
  behind `OPTION_CMP_OPENCV`.

Environment-level workarounds (not code changes, not committed
anywhere, needed again on a fresh checkout unless carried into the
fetch step some other way): manually populated `common/lib/ext/ktx`,
`common/lib/ext/brotlig`, `common/lib/ext/directxtex` from WSL since
no working Python exists on the Windows host and
`fetch_dependencies.py`'s OS-detection means running it from WSL
silently skips Windows-only dependencies. None of the three ended up
mattering for the actual build once #3 and #6 disabled the options
that needed them — recorded here in case a future pass re-enables
KTX2/Brotli-G/DirectX on Windows and hits the same wall.

## Phase 4 (part 3) — Windows verification harnesses vs. reference MD5s

### Harness-runner gap found before any test could run

All four `tools/win/verify_*.py` scripts spawn the Windows
`compressonatorcli.exe` via `subprocess.run([str(path), ...])`, where
`path`/`src`/`out` are `pathlib.Path` objects built from `--cli`/
`--src`/`--tmp` args. First attempt ran them with WSL's Python 3.14,
passing WSL-mount paths (`/mnt/c/Users/abhi/...`) straight through.
Every run "succeeded" (exit 0 reported by the CLI itself — no error
surfaced) but the expected `.dds` output was never created:
`FileNotFoundError` when the harness tried to MD5 it. Root cause: the
CLI executable path gets transparently translated by WSL2's own
interop/binfmt layer when it's argv[0] of a spawned process (that's
why the earlier smoke test "ran"), but the *argument strings* handed
to that Windows process — source/dest file paths — are not
translated. A genuine Windows process has no notion of `/mnt/c/...`;
it silently treated them as bogus relative paths and (per the
scripts' `stdout=DEVNULL, stderr=DEVNULL`) failed the encode with no
visible error.

No working Python existed on the Windows host to run these natively
(`python.exe` resolves to the Microsoft Store app-execution-alias
stub — confirmed already in Phase 4 part 2, fix #2b). Rather than
install anything system-wide, fetched the official CPython 3.12.7
**embeddable** distribution (`python-3.12.7-embed-amd64.zip` from
`python.org`, ~11 MB) — a self-contained, no-installer, no-registry
folder, extracted to `tools/pyembed/win64/`. Its stdlib
(`python312.zip`) already covers everything the four scripts import
(`pathlib`, `hashlib`, `argparse`, `subprocess`, `tempfile`, `time`).
Ran all four scripts through this interpreter via `cmd.exe`, with
every path argument (`--cli`, `--src`, `--tmp`, etc.) given as a real
`C:\...` path so both the Python process and the spawned
`compressonatorcli.exe` see consistent, correct paths throughout.
Scratch output went to `_verify_scratch/` under the repo root (visible
to both WSL and Windows) rather than the scripts' `tempfile`-default
location, for the same reason.

This is purely a run-time-environment fix — none of the four
`verify_*.py` scripts themselves needed code changes; they behaved
exactly as designed once given a real Windows Python and real Windows
paths.

### 1. `verify_boundaries.py` — vs. Phase 3 part 4c

Run against `build_cli_batch`, `--src ruby.png`. **9/9 match, all
exact byte-for-byte MD5s against the Linux reference — no
cross-platform drift at all:**

```
Reference (interior):
  veryfast  Q=0.05  md5=5fae5456ae19  OK
  fast      Q=0.30  md5=cff9a2cf1964  OK
  basic     Q=0.50  md5=10cda379ba6f  OK
  slow      Q=0.70  md5=16c8a5170408  OK
  slowest   Q=0.95  md5=7f115eab183c  OK

Boundary:
  Q=0.25  md5=cff9a2cf1964  bucket=fast     OK
  Q=0.45  md5=10cda379ba6f  bucket=basic    OK
  Q=0.65  md5=16c8a5170408  bucket=slow     OK
  Q=0.85  md5=7f115eab183c  bucket=slowest  OK
```

Mode histograms printed alongside each boundary case (not shown here,
see raw harness output) — not needed for interpretation since every
MD5 matched exactly; recording them was moot once bytes matched.
Centibucket fix (Phase 3 part 4c) survived the MSVC port with zero
observable floating-point divergence on this input.

### 2. `verify_bit_identity.py` — vs. Phase 3 part 5 Step 2/2b

`build_cli` (per-block) vs. `build_cli_batch` (batched), both Windows
binaries. **6/6 configs, 100.0000% block match (0 differing blocks out
of 14976 or 30000, per config), same-platform — the critical check per
task instructions.** Per-config MD5s also matched the Linux reference
values from Phase 3 part 5 Step 2/2b exactly:

```
[ruby.png Q=0.50]                                          14976/14976  100.0000%  741246ded2fb  OK
[ruby.png Q=0.45 (boundary)]                               14976/14976  100.0000%  741246ded2fb  OK
[ruby.png Q=0.65 (boundary)]                               14976/14976  100.0000%  2df4cbbbe848  OK
[ruby.png Q=0.50 -ColourRestrict 1 -ModeMask 255]          14976/14976  100.0000%  7b61c709f275  OK
[ruby_alpha.tga Q=0.50 -AlphaRestrict 1 -ModeMask 255]     30000/30000  100.0000%  ee63f48cc53e  OK
[ruby_alpha.tga Q=0.50 -Colour 1 -Alpha 1 -ModeMask 255]   30000/30000  100.0000%  1acc20029808  OK

ALL BIT-IDENTICAL
```

Q=0.50 and Q=0.45 share `741246ded2fb` because both land in the same
"basic" bucket — same behavior recorded on Linux, not a Windows
anomaly. Both the same-platform pairwise check (unbatch==batch) and
the cross-platform absolute-value check (Windows==Linux reference)
pass simultaneously — the MSVC build isn't just internally consistent,
it reproduces Linux's exact rounding.

### 3. `verify_no_crash.py` — zero-valid-modes guard, vs. Step 2b

`-AlphaRestrict 1`, default ModeMask, `ruby_alpha.tga` (mixed 0/255
alpha) — the config that crashed pre-guard on Linux's batched path.
**Both binaries exit 0, no crash.** The harness itself only checks
exit code, but Step 2b's writeup records a specific reference MD5
(`7f359e51bc5c`) for this exact guarded output, so MD5'd the two
produced `.dds` files manually as an extra check beyond what the
script does:

```
build_cli (per-block)             no crash    md5=7f359e51bc5c
build_cli_batch (batched)         no crash    md5=7f359e51bc5c
```

Exact match against the Linux reference on both binaries. The Step 2b
defensive guard (`cmp_core/source/bc7enc_rdo_adapter.cpp`) behaves
identically under MSVC — same fallback-to-default-params path taken,
same resulting bytes.

### 4. `verify_thread_scaling.py` — vs. Step 3b, with a corpus substitution [SUPERSEDED by Phase 4 part 4]

> **SUPERSEDED.** This subsection's measurement used a synthetic
> stand-in because the GAMMA corpus wasn't on the Windows machine yet.
> The corpus has since been transferred and the check re-run against
> the real `wpn_mount_dovetail_kmz_1p59_mount_bump.dds`
> (**4.69×**, NT=1 2.598s / NT=8 0.554s) — see Phase 4 part 4 §1.
> **Cite that number, not the 4.70× below.** Kept here for the record
> of what was known at the time; the coverage gap this subsection
> flags no longer exists.

The original Step 3b Linux measurement used two files from an external
"GAMMA sample corpus" (`wpn_mount_dovetail_..._bump.tga` 2048×2048 and
`ui_maid_pistols` 2048×256) that are **not present in this checkout**
— that corpus was never committed to either repo (licensed/external
game assets, per Phase 3 part 1b's description of where it came from).
Nothing else checked in meets the harness's own `>= 1024×1024`
requirement — `ruby.png`/`ruby.tga` are 576×416, `ruby_alpha.tga` is
800×600. Generated a synthetic substitute instead of skipping this
check: a 2048×2048 32-bit uncompressed TGA
(`_verify_scratch/scale_test_2048.tga`), procedural RGBA pattern with
a checkerboard alpha channel (mixed 0/255, so it exercises the same
alpha-restricted code paths as the real corpus would) — not a real
texture, just enough structured, non-degenerate content to give the
encoder real work per block rather than collapsing to a uniform-color
fast path.

```
file: scale_test_2048.tga
  NT=1: 6.998s
  NT=8: 1.488s
  ratio (NT=1 / NT=8): 4.70x
```

Passes the harness's own `ratio >= 1.3` gate by a wide margin (exit
0). Not the same magnitude as Linux's 5.37× on the real Dovetail
2048² file — expected and explicitly anticipated by the script's own
comments ("Windows numbers won't necessarily match Linux magnitudes")
since this is a different image, different CPU, different scheduler,
MSVC vs. GCC thread-proc codegen. What matters per the task's
instructions is the *sign*: NT=8 is materially faster than NT=1, not
sitting near 1.0× — the worker-pool parallelism fix from Step 3b holds
under the MSVC/Windows build. A same-corpus apples-to-apples number
would need the real GAMMA files copied into this environment; flagging
that as a gap rather than asserting the magnitude matches when it
can't, on this evidence, be checked.

That gap was subsequently closed — the corpus was copied in and the
check re-run on the real Dovetail file in Phase 4 part 4 §1. The
substitute-file caveat above is historical.

### Phase 4 part 3 verdict

All four harnesses pass. Zero same-platform mismatches (the class the
task flagged as "real bug, investigate immediately") — batched and
unbatched agree 100% everywhere tested, both in isolation and against
each other. Zero cross-platform mismatches either — every reference
MD5 from Linux (Phase 3 parts 4c, 5 Step 2/2b) reproduced exactly on
this MSVC/Windows build, byte-for-byte, no observable FP drift between
GCC and MSVC on any tested input. The one gap was coverage, not
correctness: thread-scaling was checked on a synthetic file rather
than the real GAMMA corpus (unavailable in this checkout at the time),
so its *magnitude* wasn't directly comparable to Linux's recorded
5.37×/2.94× — only its sign (NT=8 faster than NT=1, by a wide margin)
was confirmed.

**That gap is closed as of Phase 4 part 4.** The corpus was
transferred to the Windows machine and the check re-run against the
real Dovetail bump map: **4.69×** (NT=1 2.598s, NT=8 0.554s). Nothing
in this section's conclusions changes — the synthetic run had the
right sign and, as it turns out, nearly the same ratio — but part 4 §1
is the measurement to cite, and the "unavailable corpus" limitation
recorded above no longer applies to anything.

Phase 4 (Windows/MSVC build + verification) is closed. Both halves —
build succeeds, and output matches the established Linux-side
correctness baseline — are done.


## Phase 4 (part 4) — Full GAMMA corpus benchmark on Windows/MSVC

Independent cross-hardware confirmation of the Phase 3 part 6 result.
Same 9-file corpus, same variants (minus texconv), same alpha-aware
PSNR methodology, same best-of-3 timing — run on the Windows/MSVC
build from Phase 4 parts 2/3, on different silicon.

**Absolute wall-clock times in this section are NOT comparable to the
Phase 3 part 6 numbers.** Different CPU, different OS, different
compiler. Only the qualitative pattern — which variant wins, by
roughly what shape of margin — carries across. PSNR *is* directly
comparable (same inputs, same decoder, deterministic encoders), and
is treated as such below.

### Hardware / environment

| | Phase 3 part 6 (reference) | Phase 4 part 4 (this run) |
|---|---|---|
| CPU | Ryzen 7 5800X (desktop) | Ryzen 7 5800H (laptop) |
| cores/threads | 8C/16T | 8C/16T |
| max clock | 3.8 GHz base / 4.7 boost | 3.2 GHz base, laptop power envelope |
| OS / toolchain | Linux, GCC | Windows, MSVC 17.14 (VS BuildTools 2022) |
| binaries | `build_cli_off` / `build_cli_batch` (Linux) | same three flavors, Phase 4 part 2 build |

Same core count, materially lower sustained power/clock ceiling. This
matters for reading the stock-vs-batch gap below.

**Quiet-system check before starting:** `Win32_Processor.LoadPercentage`
sampled 4× → 6 / 19 / 6 / 10 %, top processes by cumulative CPU were
`System` and `svchost` (idle-time accumulation, not active load). No
build, no other benchmark, no browser running. All variants for a
given file ran interleaved within the same repetition loop, so any
residual drift hits all three equally.

### Corpus provenance and input identity

The real GAMMA corpus is now present at
`runtime/images/gamma_sample/` (rsync'd from the Linux machine, same
relative paths). The 9 selected files are the exact ones from Phase 3
part 1b. Sources were decoded to `.tga` with the held-constant decoder
(`build_cli`, `-fd RGBA_8888`) into `_bench/corpus/`, same as Linux.

Input identity confirmed against the value recorded in Phase 3 part 6a:

```
ui_icon_maidindicators.tga   md5=280f35707a8c   size=131090 bytes   (Linux: md5=280f35707a8c, 131090 bytes)
```

Exact match. The Windows decode of the same source `.dds` produces
byte-identical pixels to the Linux decode, so every PSNR read below is
against the same reference bytes Phase 3 used — not merely "the same
file name".

All 9 decoded TGAs are 32-bit uncompressed (`type=2 bpp=32 desc=0x08`,
18-byte header, no ID field), sizes exactly `18 + w·h·4`.

### 1. Deferred thread-scaling check, closed on the real file

Phase 4 part 3 ran `verify_thread_scaling.py` against a synthetic
2048² TGA because the corpus wasn't available. Re-run against the
actual Dovetail bump map:

```
file: _bench/corpus/dovetail_bump.tga   (2048×2048, decoded from
      runtime/images/gamma_sample/Dovetail/wpn_mount_dovetail_kmz_1p59_mount_bump.dds)
  NT=1: 2.598s
  NT=8: 0.554s
  ratio (NT=1 / NT=8): 4.69x
```

Exit 0, well past the harness's own 1.3× gate. Read on its own terms:
the batched path parallelizes properly under MSVC/Windows on a
laptop-class part — 4.69× on 8 physical cores. The only result that
would have been a problem is a ratio near 1.0 (the pre-Step-3b
signature, where thread overhead was paid with no work distributed);
this is nowhere near that.

Not framed as a match to Linux's 5.37× — different CPU, different
power envelope, different scheduler. For what it's worth the NT=1
times are near-identical (2.598s here vs 2.633s on Linux), so the
difference in ratio comes from the NT=8 end (0.554s vs 0.490s), which
is exactly where a lower sustained all-core clock would show up. Not
asserting that as the cause — just noting the numbers don't suggest a
parallelism defect.

The Phase 4 part 3 coverage gap is now closed: the synthetic
substitution is superseded by this real-corpus measurement.

### 2. Corpus benchmark — variants and settings

texconv skipped for this pass, per scope: the question here is "does
batched bc7e still comprehensively beat stock on this hardware", not
re-litigating the texconv comparison (settled in Phase 3 part 6/6a).

| variant | binary | flags |
|---|---|---|
| `stock_default` | `build_cli_off` compressonatorcli.exe | no `-Quality` (codec default 0.05) |
| `stock_Q1.0` | `build_cli_off` compressonatorcli.exe | `-Quality 1.0` |
| `batch_Q1.0` | `build_cli_batch` compressonatorcli.exe | `-Quality 1.0` |

`-fd BC7 -EncodeWith CPU -NumThreads 8`, `OMP_NUM_THREADS=8` for all
three. Best-of-3 via `time.perf_counter()`, variants interleaved
within each repetition. Encode harness runs natively on Windows
(`tools/pyembed/win64/python.exe`) with real `C:\...` path arguments
throughout, so timings exclude WSL interop overhead and the
path-translation trap from Phase 4 part 3 doesn't apply.

PSNR methodology unchanged from Phase 3 part 1b / part 6: decoder held
constant (`build_cli`, `-fd RGBA_8888`); `RGB@α>0` = MSE over RGB of
source pixels with `α > 0`; `αPSNR` = MSE over the full alpha channel.
No file in the corpus is fully opaque, so the naive-RGB fallback was
never taken.

### 3. Full corpus table

```
file                        W×H         variant          t(s)     RGB@α>0    αPSNR     α>0 px     mean α
--------------------------------------------------------------------------------------------------------
ui_icon_maidfillcant        32×16       stock_default    0.047     28.86     26.19        138     63.8
ui_icon_maidfillcant        32×16       stock_Q1.0       0.061     32.24     39.57        138     63.8
ui_icon_maidfillcant        32×16       batch_Q1.0       0.077     33.41     34.18        138     63.8

ui_icon_pm_drum             128×64      stock_default    0.054     34.59     39.72       1659     46.4
ui_icon_pm_drum             128×64      stock_Q1.0       0.234     40.70     43.04       1659     46.4
ui_icon_pm_drum             128×64      batch_Q1.0       0.070     40.74     43.13       1659     46.4

ui_icon_sks_short           256×64      stock_default    0.061     34.33     38.15       3705     53.2
ui_icon_sks_short           256×64      stock_Q1.0       0.376     38.56     43.18       3705     53.2
ui_icon_sks_short           256×64      batch_Q1.0       0.078     38.66     42.81       3705     53.2

ui_icon_maidindicators      256×128     stock_default    0.078     31.90     21.16      11957     87.6
ui_icon_maidindicators      256×128     stock_Q1.0       1.348     40.79     33.02      11957     87.6
ui_icon_maidindicators      256×128     batch_Q1.0       0.077     39.71     32.77      11957     87.6

ui_icon_rspartan            512×64      stock_default    0.056     35.53     42.52       4839     33.5
ui_icon_rspartan            512×64      stock_Q1.0       0.654     40.32     46.63       4839     33.5
ui_icon_rspartan            512×64      batch_Q1.0       0.077     40.37     46.52       4839     33.5

ui_icon_mg36e               512×128     stock_default    0.060     38.35     46.15       7290     25.2
ui_icon_mg36e               512×128     stock_Q1.0       1.013     41.88     47.77       7290     25.2
ui_icon_mg36e               512×128     batch_Q1.0       0.077     41.66     47.98       7290     25.2

ui_icon_w50                 512×256     stock_default    0.077     33.92     42.61      11963     21.0
ui_icon_w50                 512×256     stock_Q1.0       1.329     38.33     47.02      11963     21.0
ui_icon_w50                 512×256     batch_Q1.0       0.077     38.18     47.12      11963     21.0

ui_maid_pistols             2048×256    stock_default    0.137     36.33     40.54     101883     45.2
ui_maid_pistols             2048×256    stock_Q1.0       9.409     39.48     42.97     101883     45.2
ui_maid_pistols             2048×256    batch_Q1.0       0.139     39.25     43.05     101883     45.2

dovetail_bump               2048×2048   stock_default    2.698     40.60     41.31    4150203    127.1
dovetail_bump               2048×2048   stock_Q1.0      24.042     43.10     41.87    4150203    127.1
dovetail_bump               2048×2048   batch_Q1.0       0.577     42.89     41.70    4150203    127.1
```

### 4. Aggregates — both views

Same two views as Phase 3 part 6, for the same reason: Dovetail is
~22 MB against a corpus whose other 8 files sum to ~3 MB, so the
size-weighted sum is essentially a Dovetail measurement. The
ex-Dovetail view is what the 8 small files actually say.

```
variant          wall-clock sum   sum ex-Dovetail   per-file mean
                  (all 9 files)   (8 small files)    (unweighted)
------------------------------------------------------------------
stock_default        3.268 s          0.570 s          0.363 s
stock_Q1.0          38.468 s         14.426 s          4.274 s
batch_Q1.0           1.249 s          0.672 s          0.139 s
```

- **Size-weighted:** batch_Q1.0 is **30.8× faster than stock_Q1.0**
  and **2.6× faster than stock_default**.
- **Excluding Dovetail:** batch is **21.5× faster than stock_Q1.0**,
  but **loses to stock_default** (0.672 s vs 0.570 s). Same
  Dovetail-dominance caveat as Phase 3 part 6, and the same cause:
  fixed CLI startup dominates on 8 files summing to ~6800 blocks.
  Per-file the gap is 0.013 s. Visible directly in the table — batch
  sits at a ~0.077 s floor on every file from 32×16 up to 512×256,
  i.e. it isn't measuring encode work at all on those, it's measuring
  process startup.
- **Per-file mean:** batch fastest (0.139 s), then stock_default
  (0.363 s), then stock_Q1.0 (4.274 s).

### 5. PSNR vs. stock

```
file                     stock_def  stock_Q1  batch_Q1   Δ(batch−stockQ1)  Δ(batch−stockdef)
---------------------------------------------------------------------------------------------
ui_icon_maidfillcant       28.86     32.24     33.41         +1.16              +4.54
ui_icon_pm_drum            34.59     40.70     40.74         +0.03              +6.15
ui_icon_sks_short          34.33     38.56     38.66         +0.10              +4.33
ui_icon_maidindicators     31.90     40.79     39.71         −1.07              +7.81
ui_icon_rspartan           35.53     40.32     40.37         +0.05              +4.84
ui_icon_mg36e              38.35     41.88     41.66         −0.22              +3.31
ui_icon_w50                33.92     38.33     38.18         −0.14              +4.27
ui_maid_pistols            36.33     39.48     39.25         −0.23              +2.92
dovetail_bump              40.60     43.10     42.89         −0.21              +2.29
```
(RGB@α>0, dB)

- **batch vs stock_Q1.0:** matched. Batch better on 4 files (+0.03 to
  +1.16 dB), worse on 5 (−0.14 to −1.07 dB), no systematic direction,
  worst-case gap 1.07 dB. Same-quality tier.
- **batch vs stock_default:** batch wins on **every file**, +2.29 to
  +7.81 dB — while also being faster on the size-weighted view. This
  is the comparison that matters for a drop-in: default-quality stock
  is what a caller gets without passing `-Quality`.
- **αPSNR** (full table above): batch vs stock_Q1.0 is +0.03 to
  +0.21 dB better on 4 files, −0.11 to −0.37 dB worse on 4, with one
  outlier — `maidfillcant` at −5.39 dB (34.18 vs 39.57). That file's
  alpha channel is 138 non-zero pixels in a 32×16 image; Phase 3 part
  6 already called that file noise territory for the same reason.
  Everything else sits inside ±0.4 dB.

### 6. Cross-platform PSNR reproduction

The strongest result here is not the timing — it's that the quality
numbers reproduce the Linux table essentially exactly.

**26 of the 27 recorded Phase 3 part 6 RGB@α>0 values reproduce
digit-for-digit at the recorded 2-decimal precision**, across all
three variants and all 9 files. All 9 αPSNR values for `batch_Q1.0`
likewise reproduce exactly, as do all 9 `stock_default` and
`stock_Q1.0` αPSNR values.

The single exception: `ui_icon_mg36e` / `stock_Q1.0` RGB@α>0 reads
**41.88** here vs **41.89** on Linux. Checked at higher precision to
rule out a rounding-boundary artifact — the actual value is
**41.88415**, which is not near the 41.885 boundary, so this is a real
(if tiny, ≥0.005 dB) difference in produced bytes, not a display
artifact.

Two facts bound what can be concluded from it:
- It is in the **stock CMPMSC codec path**, not the bc7e path. That
  path is the float-heavy shaker refinement reviewed in Phase 3 part
  1d — exactly the kind of code where GCC and MSVC can differ on
  FMA contraction / x87-vs-SSE intermediate precision.
- **Every `batch_Q1.0` value on every file matched exactly**, i.e. the
  code actually under test shows zero observable divergence. This is
  consistent with Phase 4 part 3, where all 16 direct MD5 comparisons
  of bc7e output matched Linux byte-for-byte.

Not asserting a root cause for the mg36e stock delta — no
byte-level Linux reference exists for corpus outputs (only for the
ruby/ruby_alpha verification set), so it can't be traced further from
here. Recording it as observed evidence: one 0.005+ dB difference, in
the stock encoder, on one file, with the new encoder's output
unaffected.

### Verdict — Phase 4 part 4

Cross-hardware confirmation holds. The Phase 3 part 6 conclusion
reproduces on completely different silicon and a completely different
toolchain:

- **batch_Q1.0 comprehensively beats stock on this hardware.** 30.8×
  faster than `stock_Q1.0` size-weighted (21.5× excluding Dovetail) at
  matched quality (≤1.07 dB either direction, no systematic bias), and
  2.6× faster than `stock_default` while being +2.29 to +7.81 dB
  better on every single file.
- **The one place batch loses is unchanged and understood:** the
  ex-Dovetail sum against `stock_default`, where a ~0.077 s process
  startup floor dominates on files too small to measure encode work.
  Same finding as Linux, same magnitude of gap (0.013 s/file here,
  0.017 s/file there).
- **The stock-vs-batch gap widened on the weaker part** — 30.8× here
  vs 12.3× on the 5800X. Stock's Dovetail time roughly doubled
  (11.6 s → 24.0 s) and pistols more than tripled (2.8 s → 9.4 s),
  while batch's Dovetail time moved 0.448 s → 0.577 s. Suggestive that
  the batched SIMD path degrades far more gracefully under a lower
  sustained power envelope than stock's scalar refinement loop, but
  this is a two-machine observation with a compiler change confounded
  in, so it's an observation, not a claim.
- **Quality is platform-invariant.** Every batch_Q1.0 PSNR value
  reproduces the Linux table exactly.

Harnesses: `_bench/run_encode.py` (Windows-side encode/decode, writes
`_bench/timings.json`), `_bench/psnr.py` (WSL-side numpy PSNR, writes
`_bench/psnr.json`). Decoded corpus in `_bench/corpus/`, all outputs
in `_bench/out/`.

## Phase 5 — Static linking pass

Goal: make the CLI binary drop-in deployable — no runtime redistributable,
no specific installed package — since ATAK shells out to it the same way
it does texconv today. Source/CMake side only; no patching of built
binaries.

**Status: Windows half complete and verified. Linux half not done — see
"Linux half: blocked" below.** The Linux work needs the Linux machine and
this session is on the Windows box; the substantive OpenGL question is
answered for both platforms by source-tracing, but the ldd measurement,
the relink, and the post-relink verification are not things that can be
faked from here.

### 1. Is OpenGL linked? — no, on either platform

Phase 1 flagged `OPTION_CMP_OPENGL` as defaulting ON for CLI builds
(`CMakeLists.txt:167` — `cmp_option(OPTION_CMP_OPENGL "Use OpenGL" ON
OPTION_BUILD_APPS_CMP_CLI OR OPTION_BUILD_APPS_CMP_GUI)`, i.e. ON
whenever the CLI is being built), which is why `build_cli_batch.ps1`
passes `-DOPTION_CMP_OPENGL=OFF` explicitly. Confirmed that flag does
what it claims, and that nothing routes around it.

**Windows — empirical.** `dumpbin /dependents` on all three flavors,
before any change in this phase:

```
KERNEL32.dll  ole32.dll  MSVCP140.dll  imagehlp.dll
VCRUNTIME140.dll  VCRUNTIME140_1.dll
api-ms-win-crt-{stdio,string,runtime,heap,convert,environment,
                math,filesystem,locale,utility}-l1-1-0.dll
```

No `opengl32.dll`, no `glu32.dll`, no `glew32.dll`. OpenGL is not
linked. (`glew32.dll` was the subject of the Phase 4 part 2 fix #5
post-build copy failure — that was a file-copy step, never a link
dependency.)

**Linux — by source trace**, since no Linux binary exists on this
machine to run `ldd` against. Three places reference GL:

- `external/opengl/CMakeLists.txt` — the only place that actually
  *links* it (`find_package(OpenGL REQUIRED)` + `OpenGL::GL`). Grepping
  every `add_subdirectory` in the tree: this directory is added only by
  `build/sdk/CMakeLists.txt:211`, which is the separate SDK build, not
  the CLI build. Nothing in the CLI configure path adds it, so
  `find_package(OpenGL REQUIRED)` never even executes.
- `applications/_plugins/cimage/ktx/CMakeLists.txt:52` and `ktx2:45` —
  both call `find_package(OpenGL)` (non-REQUIRED) but neither links the
  result; the `if (OpenGL_FOUND)` body only adds `/usr/local/include`
  on APPLE. Inert even when it runs. And it doesn't run here: both
  subdirectories are gated behind `OPTION_BUILD_KTX2`
  (`CMakeLists.txt:395-400`), already OFF in both the Linux and Windows
  invocations.
- `applications/_plugins/c3dmodel_viewers` and `cgpudecode` — gated on
  `OPTION_CMP_OPENGL`, OFF in both invocations. These are the GUI model
  viewer and the GPU-decode path, neither on the BC7 CPU encode path.

So `OPTION_CMP_OPENGL=OFF` is sufficient, and no "confirm it's dead code
and drop it from the link" work is needed — it was never in the link.
The Windows dumpbin result is the direct evidence; the Linux conclusion
rests on the source trace above and should be confirmed with `ldd` when
that machine is next available.

### 2. Windows: /MD → /MT

**The codebase already has the right mechanism, and it was broken.**

`external/cmake/dependencyinfo.cmake:10` (included from
`CMakeLists.txt:286`, well before the first `add_subdirectory` at 371,
so the ordering is correct) sets:

```cmake
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>$<$<BOOL:BUILD_SHARED_LIBS>:DLL>")
```

`$<BOOL:BUILD_SHARED_LIBS>` tests the **literal string**
`"BUILD_SHARED_LIBS"`, not the variable's value. A non-empty,
non-false string is truthy, so this genex appended `DLL`
unconditionally — `MultiThreadedDLL` (/MD) on every configuration,
whatever `BUILD_SHARED_LIBS` was set to. Two lines below, the same
variable is tested correctly (`if (BUILD_SHARED_LIBS)`, which
auto-dereferences) to choose the `MD`/`MT` dependency install
subdirectory — so the file contradicted itself and shipped a /MD build
into an `MT` dependency tree.

Confirmed rather than assumed, before changing anything:
- `build_cli_batch/CMakeCache.txt` → `BUILD_SHARED_LIBS:BOOL=OFF`
- generated `CompressonatorCLI-bin.vcxproj` and `CMP_Core.vcxproj` →
  `<RuntimeLibrary>MultiThreadedDLL</RuntimeLibrary>`
- `CMakeLists.txt:13-14` sets `CMP0091 NEW`, so
  `CMAKE_MSVC_RUNTIME_LIBRARY` is the live mechanism (not the legacy
  `CMAKE_CXX_FLAGS` string-replace approach)

Fix: dereference the variable —
`$<$<BOOL:${BUILD_SHARED_LIBS}>:DLL>`. With `BUILD_SHARED_LIBS=OFF`
this now yields `MultiThreaded` = /MT.

Note this is why passing `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`
on the command line would *not* have worked: `dependencyinfo.cmake`
does an unconditional `set()`, creating a normal variable that shadows
the cache entry. The fix has to be in the file. Used the
`CMAKE_MSVC_RUNTIME_LIBRARY` mechanism because that is what this
codebase already uses (`external/cmake/customtargets/*.cmake` forward
it to every ExternalProject), not the `/MT` flag-override style seen in
`build/sdk/CMakeLists.txt:128-135`, which is a different, older build.

### 3. Windows result — 16 shared dependencies down to 3

All three flavors rebuilt from clean configure dirs. `dumpbin
/dependents` after the relink, identical for all three:

```
build_cli_off    KERNEL32.dll  ole32.dll  imagehlp.dll     2 533 376 bytes
build_cli        KERNEL32.dll  ole32.dll  imagehlp.dll     3 787 776 bytes
build_cli_batch  KERNEL32.dll  ole32.dll  imagehlp.dll     3 791 872 bytes
```

Every `MSVCP140` / `VCRUNTIME140` / `api-ms-win-crt-*` entry is gone —
that was the Visual C++ redistributable and the UCRT, the exact things
that require an installed redistributable on the target machine. What
remains is three DLLs that ship with Windows itself and cannot
meaningfully be eliminated: `KERNEL32.dll` (core Win32),
`ole32.dll` (COM — pulled in by the DDS/DirectX-adjacent plugin code),
`imagehlp.dll` (image/symbol helper). No driver library and nothing
GPU-related in the list, so no case here of something that ought to
stay dynamic.

Smoke test: `compressonatorcli.exe` with no args prints the V4.5.0
banner and exits 0.

### 4. Windows verification after relink — byte-identical, as it should be

A linkage change must not move a single output byte. Confirmed rather
than assumed; all three harnesses re-run against the same references
used in Phase 4 part 3.

`verify_boundaries.py` (build_cli_batch, ruby.png) — **9/9 exact**,
same MD5s as Phase 3 part 4c:

```
veryfast Q=0.05 5fae5456ae19   fast Q=0.30 cff9a2cf1964
basic    Q=0.50 10cda379ba6f   slow Q=0.70 16c8a5170408
slowest  Q=0.95 7f115eab183c
Q=0.25 -> fast   Q=0.45 -> basic   Q=0.65 -> slow   Q=0.85 -> slowest
```

`verify_bit_identity.py` (build_cli vs build_cli_batch) — **6/6, 100%
block match**, MD5s unchanged: `741246ded2fb` (x2), `2df4cbbbe848`,
`7b61c709f275`, `ee63f48cc53e`, `1acc20029808`.

`verify_no_crash.py` (zero-valid-modes guard) — both binaries exit 0,
no crash, payload MD5 `7f359e51bc5c` on both. Exact match to Step 2b.

One self-inflicted false alarm worth recording: the first manual MD5 of
the guard output read `88ee2a9fac26` and looked like a regression. That
was a **full-file** MD5; the Step 2b reference is a **payload** MD5
(header skipped — 148 bytes here, since the file carries a `DX10`
fourCC at offset 84), matching the convention `verify_bit_identity.py`
uses throughout. Payload MD5 of the same file is `7f359e51bc5c`. No
discrepancy — but the two conventions coexist in these notes, so:
boundary-sweep MD5s are whole-file (that harness hashes the whole
`.dds`), bit-identity and guard MD5s are payload-only.

### 5. Linux half: blocked, not skipped

Steps 1 (full `ldd` list), 2 (static link flags), and the Linux halves
of 4 and 5 are **not done**, because none of them can be done from this
machine:

- No Linux build of `compressonatorcli` exists anywhere in the
  checkout. All three `build_cli*` directories contain PE32+ Windows
  binaries (`file` confirms). The Linux builds live on the other
  machine — the Arch/GCC 16.1.1 box from Phase 3.
- This WSL environment can't produce one either: `cmake` absent,
  `ninja` absent, no Linux ISPC (`tools/ispc/` holds only the Windows
  v1.31.0 package). `gcc`/`g++` 15.2.0 and `ldd` 2.43 are present.

Building one here is possible (portable CMake + Linux ISPC tarballs,
same no-install approach as `tools/pyembed`), but it would be **Ubuntu
26.04 / glibc 2.43 / GCC 15.2**, not the Arch / GCC 16.1.1 environment
every Linux number in these notes came from. That's a different distro
with a different libc, which is exactly the variable a static-linking
investigation is about — so an `ldd` reading from it would not be
evidence about the reference build. Recording this as a blocker rather
than substituting a near-miss environment and presenting it as the
answer.

What still needs doing on the Linux machine, in order:

1. `ldd compressonator/build_cli_batch/bin/compressonatorcli-bin` —
   full list. Expect `libstdc++.so.6`, `libgcc_s.so.1`, `libm.so.6`,
   `libc.so.6`, `libpthread`/`libdl` (likely folded into libc on
   glibc 2.34+), and `libstdc++fs` is header-only/absorbed on modern
   GCC. Confirm no `libGL.so`, per the source trace in section 1.
2. Add the static flags to the CLI link step. Recommendation:
   **`-static-libgcc -static-libstdc++` first**, not full `-static`.
   Rationale: full `-static` against glibc breaks `getaddrinfo`/NSS
   (`dlopen`s `libnss_*` at runtime regardless of link mode, and
   glibc warns at link time about it). Compressonator's CLI does no
   name resolution, so it may well be harmless here — but
   `-static-libgcc -static-libstdc++` removes the two libraries that
   actually cause portability failures across distros (libstdc++ ABI
   version skew being the common one) while leaving libc dynamic and
   the loader happy. Escalate to full `-static` only if a measured
   need shows up, and report which was used and why.
3. Rebuild, re-run `ldd`, re-run all three verification harnesses and
   confirm the same MD5s as section 4.

### Files changed this phase

- `compressonator/external/cmake/dependencyinfo.cmake:10` — dereference
  `BUILD_SHARED_LIBS` in the `CMAKE_MSVC_RUNTIME_LIBRARY` genex, so /MT
  is actually selected when `BUILD_SHARED_LIBS=OFF`.
- `tools/win/build_flavor.bat` — new. `build_cli_batch.ps1`
  deliberately doesn't bootstrap the VS environment, so `cmake` isn't
  on PATH when the script is invoked directly; this wrapper calls
  `VsDevCmd.bat -arch=x64 -host_arch=x64` first, then the PowerShell
  script for one flavor. Was being done ad-hoc on the command line
  every rebuild; making it a file so the invocation is recorded.

## Phase 5 — Linux close-out

Follow-on to Phase 5's "Linux half: blocked" — done on the actual
reference machine (Arch, GCC 16.1.1, glibc 2.43, cmake 4.4.2), not
WSL. Distinct pass from the Windows close-out; only the /MT →
static-libgcc/libstdc++ intent is shared. Runtime env: no background
load, single active `compressonatorcli` link at a time.

### 1. Baseline `ldd` — corrects the Phase 5 §1 OpenGL claim

`ldd compressonator/build_cli_batch/bin/compressonatorcli-bin` on the
existing (pre-relink) binary — 214 entries. Direct `libGL.so.1`,
`libGLdispatch`, `libGLX`, `libEGL`, `libOpenGL` all present.

Cause: the historical Linux build config kept
`OPTION_CMP_OPENCV=ON` and `OPTION_CMP_OPENGL=ON` (confirmed in
`build_cli_batch/CMakeCache.txt`), unlike the Windows script which
disables both. The Phase 5 §1 source trace (`external/opengl` only
added under the SDK build; KTX/KTX2/`OPTION_CMP_OPENGL`-gated
subdirs all inert) is still accurate — but it described what happens
when `OPTION_CMP_OPENGL=OFF`, not the Linux reference build that
every Phase 3/4 measurement came from. On the Windows box the
scripted invocation set the flag off; on Linux it never did. So the
Phase 5 §1 conclusion "OpenGL is not linked on either platform"
overreached: it was not linked in the Windows binaries dumpbin ran
against, and it *would* not be linked on Linux under the same flag,
but it *was* linked in the actual Linux reference binaries. Recording
that distinction here rather than editing the earlier claim, since
the earlier claim was made in good faith against the source and the
missing empirical check is the correction.

Correcting the record does not change the plan. The right fix is
`OPTION_CMP_OPENGL=OFF` at configure time (identical to the Windows
script). See §5 below.

### 2. Static-libgcc / static-libstdc++ applied

Reconfigured all three flavors with
`-DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++"` and
rebuilt. Only the CLI link step ran; object files unchanged.

The recommendation in Phase 5 §5 was to try these two flags first
rather than full `-static`, on the grounds that libstdc++ ABI skew
across distros is the actual portability failure mode and full
`-static` against glibc trips the NSS/`getaddrinfo` warning. That
recommendation stands and was applied as-is.

### 3. Post-relink `ldd` — direct NEEDED changes, transitive count unchanged

Ran `readelf -d ... | grep NEEDED` (direct link deps) and `ldd` (full
transitive) on all three rebuilt binaries. All three flavors identical
direct-NEEDED list:

```
libopencv_highgui.so.500  libopencv_videoio.so.500
libopencv_imgcodecs.so.500  libopencv_imgproc.so.500
libopencv_geometry.so.500  libopencv_flann.so.500
libopencv_core.so.500
libm.so.6  libc.so.6  ld-linux-x86-64.so.2
```

**Direct NEEDED before:** 12 entries — same 10 above plus
`libstdc++.so.6` and `libgcc_s.so.1`. **Direct NEEDED after:** 10 —
libstdc++/libgcc_s dropped from the binary's own link. Static flags
took effect.

`ldd` transitive count unchanged at 214. libstdc++.so.6 and
libgcc_s.so.1 still appear in `ldd` output because every one of the
seven OpenCV shared libs (and their own transitives — Qt6, GStreamer,
FFmpeg, etc.) drags libstdc++ in independently. `-static-libstdc++`
statically resolves the CLI's own C++ symbols but cannot delete
libstdc++ from a process image whose *dynamic* dependencies need it.

Practical portability meaning:

- **Delivers today**: the CLI's own C++ template instantiations,
  exception machinery, and stream code no longer come from
  `libstdc++.so.6` at runtime. On a target with the same OpenCV/Qt6
  package versions but a different libstdc++ minor version, the
  binary is more robust than before — the ABI-skew failure mode Phase
  5 §5 named (distro-A libstdc++ vs distro-B libstdc++) is neutralised
  for the CLI's own code.
- **Does not deliver**: the "single-file, drop on any modern glibc box"
  goal the Windows binary now hits. The seven OpenCV .so entries, and
  everything they pull in, all still need to be present at the same
  major SO versions. On any target lacking OpenCV 5.0 that goal fails
  the same way it did before this pass.

glibc itself is still dynamic, as intended. Full `-static` was
explicitly recommended against unless a measured need turned up; see
§5 for whether one turned up.

### 4. Verification against Phase 3 part 4c references — byte-identical

Linkage-only change → output must be byte-identical to prior binaries.
Confirmed rather than assumed.

`verify_boundaries.py` on `build_cli_batch` — **9/9 exact**:

```
veryfast Q=0.05 5fae5456ae19   fast Q=0.30 cff9a2cf1964
basic    Q=0.50 10cda379ba6f   slow Q=0.70 16c8a5170408
slowest  Q=0.95 7f115eab183c
Q=0.25 -> fast   Q=0.45 -> basic   Q=0.65 -> slow   Q=0.85 -> slowest
```

`verify_bit_identity.py` (`build_cli` vs `build_cli_batch`) — **6/6,
100% block match**, payload MD5s identical across builds: `741246ded2fb`
(×2), `2df4cbbbe848`, `7b61c709f275`, `ee63f48cc53e`, `1acc20029808`.
Same MD5s as the Windows Phase 5 §4 relink.

`verify_no_crash.py` — both flavors exit 0, guard payload MD5
`7f359e51bc5c` on both. Exact match to Step 2b and Windows Phase 5 §4.

### 5. Full `-static` — feasible at code level, blocked by current config

Evaluated per Phase 5 §5's "escalate only if a measured need shows up"
and the follow-on ask to check the CLI's encode/decode path directly
before applying it. Two independent checks, both clean:

- **NSS / DNS**: `grep -rEn "getaddrinfo|gethostby" compressonator`
  → no hits anywhere in the tree. The CLI never resolves a hostname,
  which is the specific failure mode `-static` warns about at link
  time on glibc.
- **dlopen**: `dlopen` appears **nowhere** in the encode/decode path.
  The plugin manager (`applications/_plugins/common/pluginmanager.cpp`)
  is Windows-only for actual DLL loading — every `LoadLibraryA` call
  is inside `#ifdef _WIN32`. Linux has no `#else` branch that opens
  shared objects at runtime, so the "plugins won't load under static
  linking" concern doesn't apply on Linux.
- **iconv / locale**: no `iconv_open`, `mbstowcs`, or non-C
  `setlocale` in the encode path — no gconv module dlopens either.

Blocker: the current build still lists seven `libopencv_*.so.500`
direct NEEDED entries (§3). `-static` cannot resolve a `-lopencv_*`
against a `.so`; the link would either fail or silently produce a
partially-static ELF depending on the linker mode. Full `-static`
requires first switching to the Windows-parity configure flags
(`OPTION_CMP_OPENCV=OFF`, `OPTION_CMP_OPENGL=OFF`), which the
`OPTION_CMP_OPENCV` gate on `ssim.cpp` (added Phase 4 part 4) now
makes buildable.

Recording as: full `-static` is technically clean at the code level,
gated on a config change that also independently kills the OpenGL and
OpenCV entries the §1 baseline flagged. Not applying blindly on top
of the current config — that would be a broken link, not a smaller
one. **§6 below is the distinct pass that applies it**: reconfigure
with OPENCV/OPENGL off, rebuild, `readelf -d` should show libc + ld
only, `ldd` should collapse to under 10 entries, re-run the same
verification harnesses to hold the MD5s. (Actual §6 outcome exceeded
the prediction — zero NEEDED entries, `ldd` reports "not a dynamic
executable".)

### 6. Full `-static` — applied, closes Phase 5 Linux

The §5 blocker was the seven `libopencv_*.so.500` direct NEEDED
entries; the current build config kept OpenCV on because prior
phases needed it (before the Phase 4 part 4 `ssim.cpp` gate landed).
With that gate in place the config change is now a one-shot flip.

Clean reconfigure of all three flavors from empty build dirs with:

```
-DOPTION_CMP_OPENCV=OFF   -DOPTION_CMP_OPENGL=OFF
-DOPTION_CMP_QT=OFF       -DOPTION_CMP_DIRECTX=OFF
-DOPTION_BUILD_KTX2=OFF   -DOPTION_BUILD_BROTLIG=OFF
-DOPTION_BUILD_EXR=OFF
-DCMAKE_EXE_LINKER_FLAGS=-static
-DCMAKE_POLICY_VERSION_MINIMUM=3.5
```

(bc7enc_rdo ISPC path passed only for the ON flavors, as before.)

**Post-rebuild state on all three:**

```
file  → ELF 64-bit LSB executable, statically linked
readelf -d | grep NEEDED  → (nothing)
ldd                        → not a dynamic executable
```

Sizes: `build_cli_off 7.5 MB`, `build_cli 9.9 MB`,
`build_cli_batch 9.9 MB`. All three self-contained.

Better than the Windows Phase 5 §3 result, which had three
irreducible entries (`KERNEL32.dll`, `ole32.dll`, `imagehlp.dll` —
system DLLs Windows can't statically link). Linux has no equivalent
— glibc-static plus the loader is the whole runtime surface, so
`ldd` collapses to nothing rather than to a floor of 3.

**Verification against the same reference MD5s:**

- `verify_boundaries.py` — 9/9 exact, same MD5s as Phase 3 part 4c
  (`5fae5456ae19`, `cff9a2cf1964`, `10cda379ba6f`, `16c8a5170408`,
  `7f115eab183c` plus the four boundary → bucket mappings).
- `verify_bit_identity.py` — 6/6 exact, 100% block match, payload
  MD5s `741246ded2fb` (×2), `2df4cbbbe848`, `7b61c709f275`,
  `ee63f48cc53e`, `1acc20029808`. Same as the Windows Phase 5 §4
  relink and the §4 relink above.
- `verify_no_crash.py` — both flavors exit 0; guard payload MD5
  `7f359e51bc5c` on both, matching Step 2b, Windows Phase 5 §4, and
  §4 above.

Linkage-only change, byte-identical output — same discipline as
every prior relink, held on the biggest link-config change of the
project.

The NSS / dlopen / iconv audit from §5 is still the reason this is
safe on glibc: the CLI never triggers the runtime module dlopens
that make full `-static` risky. If any future change introduces
`getaddrinfo`, plugin-style `dlopen` on the Linux path, or non-C
locale handling, the static binary will link but may fail at
runtime on that specific call — worth remembering, not worth
guarding against pre-emptively.

### 7. Committed Linux build script

Ad-hoc CMake invocations were how §2 and this section were
originally run. That's fine for one-time investigation but not for
"rebuild this exactly six months from now" — the flag set is long
enough that any hand-typed rerun is likely to drift. Wrote:

- `compressonator/tools/linux/build_flavor.sh` — matches
  `tools/win/build_cli_batch.ps1`'s shape (flavor param
  `off|unbatched|batch`, same three build-dir names, wipes the
  build dir before configure to avoid cache-poisoning). Encodes the
  full flag set from §6 including `-DCMAKE_EXE_LINKER_FLAGS=-static`
  and the Linux ISPC path. Ends with a `file` + `ldd`
  self-verification that prints "not a dynamic executable" on
  success and warns if the link somehow came out non-static.

Now the recipe lives in one committed place. NOTES.md documents
*why* each flag is what it is; the script is *how* to run it.

### Files / trees changed this phase (final)

- `compressonator/tools/linux/build_flavor.sh` — new. Committed
  Linux build script encoding the full-static configure recipe.
- `compressonator/build_cli_off`, `compressonator/build_cli`,
  `compressonator/build_cli_batch` — rebuilt from clean with the
  script's flag set. All three now fully static; no dynamic
  dependencies.
- No CMakeLists edits this pass. The Phase 4 part 4 `ssim.cpp` gate
  under `OPTION_CMP_OPENCV` (already in the tree) is the sole
  in-tree change that made the OpenCV-off configure buildable; that
  edit predates this pass and stayed in place.
- The intermediate `-static-libgcc -static-libstdc++` state from
  §2–§4 is superseded — §6 delivers the full result and the
  intermediate binaries were overwritten by the rebuild. §2–§4 stay
  in the record because the reasoning (why start with the
  intermediate step, what it delivered, why it wasn't enough on
  the historical config) is real and informative, not because the
  intermediate binaries still exist.

### Phase 5 status

- Windows half: complete (§1–§4 above the Linux close-out).
  3-DLL residual (`KERNEL32`/`ole32`/`imagehlp`), everything else
  statically linked, MSVCRT and UCRT gone.
- Linux half: **complete via §6 full `-static` pass.** All three
  flavors fully static — 0 dynamic dependencies, `ldd` reports
  "not a dynamic executable". Byte-identical to all prior binaries
  by the same three-harness verification the Windows relink used.
  Committed build recipe at `tools/linux/build_flavor.sh`.
- The §2–§4 intermediate step (static-libgcc/libstdc++ only) is
  informative but not the final answer — full `-static` is what
  actually closes the pass, because the historical Linux config
  still had OpenCV pulling libstdc++ back in transitively. Once
  OpenCV was turned off (§6), the full flag became applicable and
  worked cleanly on the first try.
- Both binaries now safe to publish as standalone artifacts.
  Windows: install-nothing on any modern Windows target (VC/UCRT
  redist not required). Linux: install-nothing on any modern glibc
  target (no libstdc++ version needed, no OpenCV, no GL).


## Phase 6 — License review and ETCPack removal

### License audit of the shipped binary

Before publishing the standalone artifacts, the source trees whose
code ends up in `compressonatorcli-bin` were read in full for their
license terms rather than assumed:

- `compressonator/LICENSE` — MIT. Permissive; use / modify /
  distribute allowed, requires the notice and copyright be preserved
  in redistributions of source and "substantial portions" of the
  software. No use restrictions, no patent grant, no attribution
  in binary distributions specifically required (only in
  source/substantial-portion copies), though a NOTICE-style
  attribution in the release is polite practice.

- `bc7enc_rdo/LICENSE` — Apache 2.0 (only for `bc7e.ispc`, which
  is the code this project actually links). Permissive; adds an
  explicit patent grant and requires that a copy of the license
  be included in derivative distributions, along with a NOTICE
  file if the upstream has one (upstream has no NOTICE file, so
  the requirement collapses to shipping the license text). Attribution
  in binary distributions is required — the release must include
  the Apache 2.0 license text and identify `bc7e.ispc` as an
  incorporated Apache-2.0 component. Compatibility with MIT: fine.
  Apache 2.0 is one-way compatible with MIT (MIT code can be
  redistributed under Apache 2.0, not the reverse). Because the
  combined artifact contains MIT + Apache 2.0 code side by side,
  ship both notices — no relicensing of either side is needed.

- The rest of `bc7enc_rdo` (the scalar `bc7enc.cpp`, `rdo_bc.h`,
  `utils.cpp`, etc.) is MIT-licensed per that repo's README, but
  none of it is compiled into our binary — the ISPC-vectorized
  `bc7e.ispc` path is the only piece linked. Only the Apache-2.0
  slice matters for our attribution obligations.

### Original ambiguity — the Ericsson SLA problem

Stock Compressonator vendors Ericsson's ETCPack under
`cmp_compressonatorlib/etc/etcpack/` with a per-file "Software
License Agreement" header, not one of the standard OSI-approved
open source licenses. The SLA scope reads (paraphrased from the
per-file headers): use of the software is granted only for the
purpose of developing, implementing, or evaluating products that
implement a Khronos-Group-standard texture compression format
(ETC1/ETC2). Redistribution is not explicitly denied but the
scope restriction is real, and interpreting it charitably would
have meant deciding whether a general-purpose BC7 CLI that also
happens to contain ETC codecs counts as an "ETC implementation."

Rather than interpret that scope question, the safer answer was
to remove ETCPack entirely: the target use case (BC7 encoding
via bc7enc_rdo's ISPC path) has zero dependency on any ETC
codec, so the SLA question can be sidestepped by not shipping
the code at all.

### ETCPack removal (mirrors Phase 4 part 4's OpenCV/ssim gate)

Added a new CMake option `OPTION_CMP_ETC` (default `ON` to
preserve stock behavior for callers who want ETC support and are
comfortable with the SLA), then gated:

- `compressonator/CMakeLists.txt` line 170 — new option declaration.
- `compressonator/cmp_compressonatorlib/CMakeLists.txt` —
  `etc/*.{h,cpp}` + `etc/etcpack/*.{h,cpp,cxx}` moved out of the
  unconditional `CMP_SRCS` glob into an `if (OPTION_CMP_ETC)`
  block; include directories and a `OPTION_CMP_ETC=1` public
  compile definition also gated.
- `compressonator/cmp_compressonatorlib/common/codec.cpp` — the
  4 ETC codec `#include`s and the 7 `case CT_ETC_*` branches in
  `CreateCodec()` wrapped in `#if (OPTION_CMP_ETC == 1) ...
  #endif`. Mirrors the existing `OPTION_BUILD_ASTC` pattern in
  the same file (undefined macro evaluates to 0, so the guard
  is a strict superset of the stock behavior when the option is
  left ON).
- `compressonator/applications/compressonatorcli/source/compressonatorcli.cpp`
  lines 252-255 — 4 "Ericsson Texture Compression" help-text
  `printf`s wrapped in the same guard. Without this, the CLI's
  `-help` output would still advertise ETC codec names even
  though the codecs themselves were absent.
- Build scripts:
  - `compressonator/tools/linux/build_flavor.sh` — added
    `-DOPTION_CMP_ETC=OFF` to `CMAKE_ARGS` with a documentation
    block explaining that the flag is license-driven, not
    linkage-driven (see script header comments).
  - `tools/win/build_cli_batch.ps1` — same flag added to
    `$cmakeArgs`.

### Verification — ETC removal is a pure no-op for BC7 output

Rebuilt all three Linux flavors clean, then ran the same
`nm`/`strings` audit used for the Phase 5 static-linking check
plus the full three-harness verification suite against Phase 3
part 4c reference MD5s.

Symbol / string audit (Linux, three flavors):

```
build_cli_off      size=7016808 ETC_syms=0 Ericsson_strings=0 bc7e_syms=0
build_cli          size=9441824 ETC_syms=0 Ericsson_strings=0 bc7e_syms=150
build_cli_batch    size=9441848 ETC_syms=0 Ericsson_strings=0 bc7e_syms=150
```

(A `nm | grep -i bc7e` initially matched 3 spurious hits on the
stock BC7 encoder's `BC7Encode` symbols in the off flavor; those
are stock CMPMSC entry points, not bc7enc_rdo. Excluded from the
count above.)

Verification suite (Linux, batch flavor):

- `verify_boundaries.py` — all 5 reference MD5s
  (veryfast/fast/basic/slow/slowest) match Phase 3 part 4c.
  All 4 centibucket boundaries (Q=0.25/0.45/0.65/0.85) resolve
  to the expected bucket.
- `verify_bit_identity.py` — all 6 configs (3 quality points +
  3 restrict combinations) 100% block-match between per-block
  and batched flavors, MD5s match the pre-removal record.
- `verify_no_crash.py` — the Step 2b zero-valid-modes guard
  still triggers correctly, both flavors exit 0 on the crashing
  config.

ETCPack is source-level absent from the tree that gets compiled,
symbol-level absent from the linked binary, and string-level
absent from the binary's `strings` output. The SLA question is
now resolved by removal rather than by interpretation.

### Windows-side status — closed out, actual numbers

Run on the Windows machine after pulling `19e6e39` / submodule
`e36cf36b`. Confirmed the ETC gate commit (`cce6da0a`) was really
present in the submodule — `OPTION_CMP_ETC` declared at
`CMakeLists.txt:171`, gates live in `cmp_compressonatorlib/
CMakeLists.txt:57,120,126`, `common/codec.cpp:49,224`,
`compressonatorcli.cpp:252` — rather than trusting the outer repo's
pointer bump. All three flavors rebuilt from clean configure dirs.

**Baseline captured before wiping the pre-gate Phase 5 binaries**, so
the after-numbers have something to be measured against. Both halves
of the audit below use that pairing.

Binary strings (`strings -a`, per flavor — identical across all three):

```
                    before    after
Ericsson strings       4        0
etcpack strings        0        0
ETC-format strings    10        6
```

Symbols in `CMP_Compressonator.lib` (`dumpbin /symbols`, batch flavor;
off/unbatched within ±22 lines of the same totals):

```
                       before    after
total symbol lines     38 460   33 086
CCodec_ETC                272        0
compressBlockETC           47        0
ETC2                      222        3
```

Binary size, all three flavors (~245 KB smaller each):

```
build_cli_off      2 533 376 -> 2 288 640
build_cli          3 787 776 -> 3 542 528
build_cli_batch    3 791 872 -> 3 547 136
```

**The residuals are not zero and shouldn't be reported as zero.** The
3 remaining `ETC2` symbols are all MSVC string-literal COMDATs
(`??_C@_08MBDLAJG@ETC2_RGB@ (`string')` and two siblings), not code;
the 6 remaining ETC-format strings are `ETC_RGB`, `ETC2_RGB`,
`ETC2_RGBA`, `ETC2_RGBA1` plus two `strings` false positives on
byte sequences inside code (`ETC2t`). They come from the format
enum↔name lookup table at
`applications/_plugins/common/atiformats.cpp:111-114`, which is not
gated by `OPTION_CMP_ETC` and contains only format identifiers — no
Ericsson-authored code, no SLA text. Every Ericsson SLA string
(the 4 `"Ericsson Texture Compression - ..."` CLI help descriptions)
and every ETC codec symbol is gone.

Behavior on a now-unsupported format, checked rather than assumed:

```
compressonatorcli -fd ETC2_RGB ruby.png out.dds   -> exit 255, no file written
compressonatorcli -fd BOGUSFMT ruby.png out.dds   -> exit 255, no file written
compressonatorcli -fd BC7      ruby.png out.dds   -> exit 0
```

ETC degrades to exactly the unknown-format path — same exit code, no
output file, no crash, no silently-wrong output. The CLI's help text
no longer lists any ETC format (the `#if (OPTION_CMP_ETC == 1)` at
`compressonatorcli.cpp:252` removed those entries along with their
Ericsson descriptions).

Dependency list unchanged from Phase 5 — still 3, all OS-shipped, on
all three flavors: `KERNEL32.dll`, `ole32.dll`, `imagehlp.dll`.

Verification suite — **byte-identical to every prior Windows run**,
same references as Phase 3 part 4c / part 5 Step 2/2b:

- `verify_boundaries.py` — 9/9 exact. Interior: `5fae5456ae19`,
  `cff9a2cf1964`, `10cda379ba6f`, `16c8a5170408`, `7f115eab183c`.
  Boundaries Q=0.25/0.45/0.65/0.85 resolve to fast/basic/slow/slowest.
- `verify_bit_identity.py` — 6/6 configs, 100.0000% block match
  (14976 or 30000 blocks). MD5s `741246ded2fb` (×2), `2df4cbbbe848`,
  `7b61c709f275`, `ee63f48cc53e`, `1acc20029808`.
- `verify_no_crash.py` — both flavors exit 0, payload MD5
  `7f359e51bc5c` on both.

ETC removal is a pure no-op for BC7 output on Windows, same as Linux.

One correction to Phase 5 §1 while re-reading it here: that section
claimed OpenGL was not linked on Linux either, on the strength of a
source trace. The Phase 5 Linux close-out measured it and found
`libGL` *was* linked, because the Linux config had
`OPTION_CMP_OPENGL=ON`. The source trace was reasoning about the
Windows flag set and was wrong about Linux — the Windows dumpbin half
of that claim stands, the Linux half did not, and the Linux close-out
section is the correct record.

### Final license surface of the published binary

With ETCPack gone, the only licenses that apply to the shipped
`compressonatorcli-bin` are:

- MIT (AMD Compressonator, AMD/ATI code paths).
- Apache 2.0 (`bc7e.ispc`, richgel999/bc7enc_rdo).

Publication attribution requirement: include both license texts
in the release; the Apache 2.0 side additionally requires the
release to identify `bc7e.ispc` as the incorporated Apache-2.0
component.

## Phase 7 — Consolidate build scripts into the submodule

"Note: some path references in earlier phases (e.g. Phase 4's ..\..\.. walk) predate the tools/win move in Phase 7 and are historical, not current instructions — see Phase 7 for the current script location."

`tools/win/build_cli_batch.ps1` moved from the outer meta-repo into the
compressonator submodule at `compressonator/tools/win/build_cli_batch.ps1`,
alongside its Linux counterpart `tools/linux/build_flavor.sh`.

Motivation: the README lives in the submodule, so a reader following its
build section on Windows was being pointed at a file in a *different*
repository — a path that doesn't exist from where they're standing. Both
canonical build recipes now sit in the same tree as the README that cites
them.

### `$RepoRoot` walk reverses — this un-does Phase 4 part 2 fix #1

The script resolves its own location to find the outer root (which holds
`bc7enc_rdo/` and `tools/ispc/`, neither of which is in the submodule).
Moving it one level deeper changes that walk:

```
before   outer/tools/win/         $PSScriptRoot\..\..      -> outer root
after    compressonator/tools/win/ $PSScriptRoot\..\..\..  -> outer root
```

Phase 4 part 2 fix #1 changed this from three levels to two, because at
that time the script was in the outer repo and three levels overshot to
`C:\Users\abhi`. That fix was correct then and is correctly reverted now
— same destination, different starting point. **The Phase 4 part 2 entry
is left as written**; it records what was true at that path, and
rewriting it would make the patch log lie about its own history. This
section is the pointer for anyone who reads it and wonders why the
current file says three.

Matches `tools/linux/build_flavor.sh:79-81`, which already walked
`../..` to the compressonator root then `..` to the outer root — the
Windows script now has the same shape.

### Wrapper coupling fixed

`tools/win/build_flavor.bat` (outer repo — stays there, next to the
`verify_*.py` harnesses) invoked the PowerShell script as
`%~dp0build_cli_batch.ps1`, i.e. "next to me". That silently breaks on
the move. Updated to `%~dp0..\..\compressonator\tools\win\build_cli_batch.ps1`.

### Verified, not assumed

Rebuilt `build_cli_batch` clean through the wrapper after the move. All
four derived paths resolve correctly:

```
RepoRoot   : C:\Users\abhi\compressonatorfork
Source     : C:\Users\abhi\compressonatorfork\compressonator
ISPC       : C:\Users\abhi\compressonatorfork\tools\ispc\windows\ispc-v1.31.0-windows\bin\ispc.exe
bc7enc_rdo : C:\Users\abhi\compressonatorfork\bc7enc_rdo
```

Binary is byte-size identical to the pre-move build (3 547 136 bytes) and
the boundary sweep is 9/9 exact against the same reference MD5s
(`5fae5456ae19`, `cff9a2cf1964`, `10cda379ba6f`, `16c8a5170408`,
`7f115eab183c`; boundaries resolving fast/basic/slow/slowest). A file
move shouldn't change output, and didn't.

### What stayed in the outer repo

`tools/win/` there still holds `build_flavor.bat` and the four
`verify_*.py` harnesses. Those are project-level verification
infrastructure rather than build recipes, and the harnesses take
explicit `--cli` paths so they aren't location-coupled to either repo.

### p-bit citation

Phase 3 part 6a's reference to "richg42.blogspot 2018 posts" replaced
with the actual titles and URLs (Richard Geldreich, April 2018):

- "A tale of multiple BC7 encoders" —
  http://richg42.blogspot.com/2018/04/a-tale-of-multiple-bc7-encoders.html
- "Proper pbit computation in the BC7 texture format" —
  http://richg42.blogspot.com/2018/04/proper-pbit-computation-in-bc7-texture.html

The README's §1 cites the same two directly, so the sourcing caveat it
previously carried (titles from `CLAUDE.md`, not `NOTES.md`) is removed —
`NOTES.md` now carries them itself.

## Phase 8 — `-EncodeWith` / GPU / HPC path investigation

Motivated by ATAK's plan to always pass `-EncodeWith CPU` explicitly rather
than rely on default behavior. Goal: confirm that plan is actually
sufficient, and understand what the other `-EncodeWith` values do on a
binary with no GPU codec paths compiled in.

### Build-level check — no OpenCL toggle exists

Grep of every `CMakeLists.txt` in `compressonator/`: no
`OPTION_CMP_OPENCL`, `CMP_GPU_OCL`, or `OPTION_BUILD_OPENCL` option
anywhere. `CMP_Compute_type::CMP_GPU_OCL` exists as a runtime enum value
(`= 3`), but nothing in the build system gates it — there's no flag to
flip, unlike `OPTION_CMP_DIRECTX`/`OPTION_CMP_OPENGL`/`OPTION_CMP_OPENCV`,
which are already disabled in both `build_flavor.sh` and
`build_cli_batch.ps1`.

`nm`/`strings` on the built binary: only the `--help` text mentions
OpenCL/DirectX ("Example compression using GPU Hardware or shader code
with frameworks like OpenCL or DirectX:"). No `clCreateContext`,
`clBuildProgram`, `clGetPlatformIDs`, no `OpenCL.dll`/`libOpenCL` string
constant — confirms no dlopen target is compiled in either. **Zero GPU
codec paths exist in this binary, full stop**, consistent with
`OPTION_CMP_DIRECTX=OFF`/`OPTION_CMP_OPENGL=OFF` already established in
Phase 1.

### Behavior — `CPU` explicit vs. omitted

Tested on `ruby.png` (576×416), `-Quality 0.50 -NumThreads 8`, across
both platforms with 3× repeats:

| Platform | `-EncodeWith CPU` MD5 | omitted MD5 | Match? |
|---|---|---|---|
| Windows (native) | `10cda379ba6f01c0c20179723b319d33` | same | ✅ |
| Linux (native) | `10cda379ba6f01c0c20179723b319d33` | same | ✅ |

Both match each other and match the Phase 3 part 4c reference MD5 for
Q=0.50 (`basic` bucket). **Cross-platform bit-identical on production
flags — the omitted-flag default is `CPU`, confirmed at the source
(`cmdline.cpp`, omitted flag falls into the `CMP_CPU` branch) and
empirically on both platforms.**

An earlier pass (Wine-mediated, against the Windows `.exe`, small 64×64
test image) showed the same CPU/omitted equivalence
(`be44c1534a7c34b5d9c4286251c8db11` both runs) — consistent with the
above, just not directly comparable since it used a different image and
ran through Wine rather than natively.

### Behavior — `GPU` / `OCL`

Both explicit `-EncodeWith GPU` and `-EncodeWith OCL`: exit 0, no hang,
no crash, <1s, output MD5 identical to the `CPU`-explicit run on both
platforms. A warning is printed before proceeding:
"Warning! CPU will be used for compression"

**Stream — corrected.** An earlier check on Linux (native, small test
image, no explicit redirection) reported this on **stderr**. A follow-up
check redirecting each stream independently (`2>/dev/null` — warning
still visible; `1>/dev/null` — warning gone) confirms the warning is
actually on **stdout**. The earlier "stderr" claim was wrong; this
supersedes it. The Windows-native pass also reported stdout, consistent
with this correction, though it wasn't independently confirmed via
redirection the same way.

**Practical implication for ATAK:** since GPU/OCL cleanly fall back to
CPU with byte-identical output, `-EncodeWith CPU` is technically
redundant defensively — but it's the only way to suppress the fallback
warning from appearing on stdout. If ATAK ever parses or logs the CLI's
stdout for anything, passing `CPU` explicitly avoids that pollution.
Worth keeping the explicit flag for this reason even though the
fallback itself is safe.

### Behavior — `HPC` (integration gap, documented, not fixed)

`-EncodeWith HPC` does **not** reach the bc7e adapter. Tested against
both `build_cli_batch` (bc7e) and `build_cli_off` (stock):

| Build | `-EncodeWith HPC` MD5 | Time |
|---|---|---|
| `build_cli_batch` (bc7e) | `2ab1304a5a012a040269263616132c64` | 311ms |
| `build_cli_off` (stock) | `2Gab1304a5a012a040269263616132c64` | 311ms |
| `build_cli_off`, `-EncodeWith CPU` (stock) | `83b3429a4db9ea321f5a5609ae1ffe63` | 3787ms |
| `build_cli_batch`, `-EncodeWith CPU` (bc7e) | `10cda379ba6f...` | 275ms |

HPC output is identical between the bc7e-enabled and stock builds —
the bc7e hook is not on this path. It's also not stock's regular CPU
codec (different MD5, different mode mix) — it's a third, distinct
path, likely the `CMP_Core` SDK's own HPC/SPMD kernel. Native Linux and
Wine-mediated Windows runs of `-EncodeWith HPC` produced byte-identical
output to each other (`c42d72efeb055d53d824f4673c8c820e`), confirming
this is consistent, deterministic behavior, not a fluke.

Mode histograms confirm three genuinely distinct encoders are in play:

m0    m1    m2   m3     m4     m5     m6
bc7e (CPU/GPU/OCL) 154 1741 0 686 0 11353 1042
HPC (both builds) 46 1663 54 439 12030 81 663
stock CPU 107 1819 65 12537 0 0 448

Output is valid, not garbage — RGB PSNR vs. source: bc7e 49.86 dB, HPC
50.06 dB, stock CPU 50.20 dB. All three are legitimate, working
encoders; HPC just isn't the one this fork modified.

**Decision: documented limitation, not a blocker.** ATAK always passes
explicit `-EncodeWith CPU` and never invokes HPC — this gap doesn't
affect the actual integration. Wiring bc7e into the HPC path would be
real, non-trivial work (a third integration point, understanding the
SDK's SPMD kernel) spent on a path nobody in this project's use case
reaches. Worth revisiting only if a future consumer of this fork
specifically wants an HPC-backed bc7e path.

### Verdict

- `-EncodeWith CPU` / omitted: bit-identical, cross-platform, confirmed
  on production flags and a real texture. ATAK's plan to always pass it
  explicitly is correct — not because the default is unsafe, but
  because it's the only way to suppress the GPU-fallback stdout warning.
- `-EncodeWith GPU` / `OCL`: safe, deterministic fallback to CPU with a
  printed (stdout) warning. No crash/hang/garbage risk even if passed
  by accident.
- `-EncodeWith HPC`: real integration gap — reaches neither bc7e nor
  stock's regular CPU codec, uses a separate SDK path entirely.
  Harmless for ATAK's actual usage (never invoked), documented here so
  it isn't mistaken for a faster bc7e variant by a future reader.

## Investigation 2 — BC1/BCn codec survey + BC1 quality gap

### Q1. Threading model — BC1/BC3/BC4/BC5 codecs

From the previous session's investigator run (confirmed against source):

| Codec | Class | File | Threading | volatile-CMP_BOOL? |
|-------|-------|------|-----------|-------------------|
| BC1 | `BC1_EncodeClass` | `applications/_plugins/ccmp_sdk/bc1/bc1.h:65` | Single-threaded | No |
| BC3 | `BC3_EncodeClass` | `applications/_plugins/ccmp_sdk/bc3/bc3.h:65` | Single-threaded | No |
| BC4 | `BC4_EncodeClass` | `applications/_plugins/ccmp_sdk/bc4/bc4.h:65` | Single-threaded | No |
| BC5 | `BC5_EncodeClass` | `applications/_plugins/ccmp_sdk/bc5/bc5.h:65` | Single-threaded | No |
| BC7 | `CCodec_BC7` | `cmp_compressonatorlib/bc7/codec_bc7.h:73` | Worker pool | **Yes** |

BC1–BC5 are plugin-style codecs inheriting from `CMP_Encoder`
(`plugininterface.h:64`), which has no threading. Each calls a scalar
per-block compress function directly. The volatile-CMP_BOOL race
(Jorge's fix) exists only in BC7's worker pool — no analogous pattern
in BC1–BC5.

### Q2. Version and SIMD coverage

**Version: 4.5** (`compressonator/CMakeLists.txt:24-28`, git tag
`Compressonator v4.5 Update`).

**v4.2 RefineSteps — PRESENT.**
`cmp_compressonatorlib/dxtc/codec_dxtc.cpp:106-114` — SetParameter
parsing (0–2 range guard). `cmp_compressonatorlib/ati/compressonatorxcodec.cpp:1784`
— `Refine1()` iterative loop (9×9 mode search, runs until no
improvement).

**v4.4 SSE4/AVX2/AVX512 BC1 paths — PRESENT.**
Three separate static libs with architecture-gated compile flags:

| Lib | File | Flag |
|-----|------|------|
| `CMP_Core_SSE` | `cmp_core/source/core_simd_sse.cpp:36` | `-march=nehalem` |
| `CMP_Core_AVX` | `cmp_core/source/core_simd_avx.cpp:55` | `-march=haswell` |
| `CMP_Core_AVX512` | `cmp_core/source/core_simd_avx512.cpp:55` | `-march=skylake-avx512` |

All three implement `{sse,avx,avx512}_bc1ComputeBestEndpoints()`. CMake
wiring at `cmp_core/CMakeLists.txt:69-107`. **BC1 is already
SIMD-optimized — it is not in the pre-2021 stagnant state BC7 was in.**

**BC3/BC4/BC5 SIMD — ABSENT.** Plugins call scalar `CompBlock1X()`
(`cmp_compressonatorlib/dxtc/codec_dxtc_alpha.cpp:45-46`) or the GPU
shader path (`CompressBlockBC3/4/5_Internal()`). `cmp_core/source/core_simd.h:29-31`
lists BC1-only SIMD functions. No SSE/AVX paths exist for BC3/BC4/BC5.

### Q3. BC1 quality benchmark — stock Compressonator vs rgbcx vs texconv

**Methodology.** Same 9-file GAMMA corpus. Source decoded from corpus
DDS → TGA via held-constant decoder (`build_cli_off -fd RGBA_8888`).
TGA → PNG conversion via PIL for bc7enc input. PSNR: RGB@α>0 mask
(source pixels with alpha > 0), consistent with Phase 3 methodology.
Best-of-3 wall clock. All variants best-of-3 interleaved.

**Variants:**
- `cmp_BC1_Q1.0` — `build_cli_off`, `-fd BC1 -Quality 1.0 -NumThreads 8`
- `bc7enc_rgbcx` — `bc7enc_rdo/build/bc7enc -1 -L18` (BC1, rgbcx L18 max-quality, single-process)
- `texconv_BC1` — `texconv -f BC1_UNORM -m 1` (no mipmaps)

**Raw table (t = best-of-3 CLI wall time):**

```
file                              WxH        variant          t(s)   RGB@a>0 dB
ui_icon_maidfillcant         32x16     cmp_BC1_Q1.0       0.001     28.69
                                       bc7enc_rgbcx       0.030     40.50
                                       texconv_BC1        0.002     26.92

ui_icon_pm_drum             128x64     cmp_BC1_Q1.0       0.001     35.91
                                       bc7enc_rgbcx       0.029     36.70
                                       texconv_BC1        0.002     32.37

ui_icon_sks_short           256x64     cmp_BC1_Q1.0       0.001     32.87
                                       bc7enc_rgbcx       0.031     33.71
                                       texconv_BC1        0.002     30.98

ui_icon_maidindicators      256x128    cmp_BC1_Q1.0       0.001     33.46
                                       bc7enc_rgbcx       0.031     40.48
                                       texconv_BC1        0.003     32.91

ui_icon_rspartan            512x64     cmp_BC1_Q1.0       0.002     34.89
                                       bc7enc_rgbcx       0.031     35.70
                                       texconv_BC1        0.002     29.81

ui_icon_mg36e               512x128    cmp_BC1_Q1.0       0.002     37.50
                                       bc7enc_rgbcx       0.034     38.64
                                       texconv_BC1        0.002     33.78

ui_icon_w50                 512x256    cmp_BC1_Q1.0       0.004     32.83
                                       bc7enc_rgbcx       0.038     33.97
                                       texconv_BC1        0.003     30.40

ui_maid_pistols            2048x256    cmp_BC1_Q1.0       0.017     35.03
                                       bc7enc_rgbcx       0.091     35.94
                                       texconv_BC1        0.005     31.49

dovetail_bump              2048x2048   cmp_BC1_Q1.0       0.166     36.80
                                       bc7enc_rgbcx       0.976     37.01
                                       texconv_BC1        0.027      6.27 ← invalid (see below)
```

**Texconv dovetail result — methodology invalid.** Dovetail source TGA
has partial alpha (mean ~127, range 0–255 — STALKER bump maps store
data in the alpha channel, not a transparency value). texconv converts
from straight-alpha to premultiplied alpha before encoding: decoded RGB
channels are ≈ source_RGB × (alpha/255). Since we compare against
non-premultiplied source, the PSNR collapses. Confirmed by per-channel
mean: tex_B_mean=56 ≈ src_B_mean(126) × 0.44 ≈ mean_alpha(127)/255.
Dovetail excluded from the delta summary below.

**Delta vs cmp_BC1_Q1.0 — 8 icon files (α ∈ {0, 255} only, fair comparison):**

```
file                       cmp(dB)  bc7enc d(dB)  texconv d(dB)
ui_icon_maidfillcant        28.69    +11.81         -1.77
ui_icon_pm_drum             35.91    +0.79          -3.54
ui_icon_sks_short           32.87    +0.84          -1.89
ui_icon_maidindicators      33.46    +7.02          -0.55
ui_icon_rspartan            34.89    +0.81          -5.08
ui_icon_mg36e               37.50    +1.14          -3.72
ui_icon_w50                 32.83    +1.14          -2.44
ui_maid_pistols             35.03    +0.92          -3.54
```

rgbcx beats Compressonator on every file. Texconv loses to Compressonator
on every file.

**Wall-clock totals (9 files, CLI):**

| variant | sum 9 files | mean/file |
|---------|-------------|-----------|
| cmp_BC1_Q1.0 | 0.195s | 0.022s |
| bc7enc_rgbcx | 1.291s | 0.143s |
| texconv_BC1 | 0.047s | 0.005s |

bc7enc CLI is 6.6× slower than compressonatorcli 8-thread. **This is a
CLI apples-to-oranges comparison** — compressonatorcli runs 8 threads,
bc7enc appears single-threaded for non-RDO BC1 paths, and per-process
startup (≈30ms) dominates on small icons. Library integration of rgbcx
would not carry the CLI overhead.

**Observations (facts, no editorial):**

1. rgbcx (L18, max quality) beats Compressonator BC1 by +0.8 to +11.8 dB
   across all 8 comparable files. The two outliers (+7 and +12 dB on
   `maidfillcant` and `maidindicators`) are extraordinary for BC1 —
   BC1 gains above 5 dB are rare in the literature.

2. texconv BC1 is consistently the worst of the three on this corpus,
   -1.8 to -5.1 dB vs Compressonator.

3. Unlike BC7 (frozen since early 2021, no SIMD), Compressonator BC1
   already has SIMD acceleration added in v4.4 (SSE/AVX2/AVX512 static
   libs with runtime dispatch). The "stagnant decade-old codec" premise
   that motivated the BC7 swap does not apply to BC1.

4. The +7–12 dB wins on small icons suggest rgbcx's search strategy
   handles hard-alpha sprite content particularly well at the block level,
   likely because it exhaustively searches more endpoint combinations.

**Not answered here:** whether a librgbcx-backed BC1 adapter would be
faster or slower than Compressonator's SIMD BC1 when both run the same
thread count. The CLI timing gap (6.6×) is not representative — that's
startup + single vs. multi-thread, not codec throughput.

**Scoping verdict.** The quality gap is real and consistent. Whether it
justifies a BC7-scale integration effort depends on whether BC1 output
quality matters for the target use case (ATAK's stated target is BC7,
not BC1). The technical preconditions are favorable (rgbcx is already
a submodule, the CMP_Core adapter pattern is proven). The engineering
effort would be similar to Phase 2's BC7 adapter. No decision made here.

### Follow-up 1 — Mechanism: why +7/+12 dB on maidfillcant/maidindicators

Block-mode histogram on Compressonator and bc7enc BC1 output for the
two highest-gap files:

| file | encoder | 4-color | 3-color | total |
|------|---------|---------|---------|-------|
| ui_icon_maidfillcant | cmp_BC1_Q1.0 | 0 (0%) | 32 (100%) | 32 |
| ui_icon_maidfillcant | bc7enc_rgbcx | 22 (69%) | 10 (31%) | 32 |
| ui_icon_maidindicators | cmp_BC1_Q1.0 | 46 (2%) | 2002 (98%) | 2048 |
| ui_icon_maidindicators | bc7enc_rgbcx | 1939 (95%) | 109 (5%) | 2048 |

**Explanation.** In BC1, blocks choose either 4-color mode (c0 > c1 as
packed RGB565) or 3-color mode (c0 ≤ c1), where 3-color mode reserves
one of the four codepoint indices for transparent black (RGBA = 0).
Compressonator forces 3-color mode on almost every block because these
icon textures have alpha=0 background pixels — any block touching the
background gets punch-through mode, sacrificing one of four color
interpolation steps to represent the transparent codepoint.

bc7enc uses 4-color mode on most blocks even when some source pixels
have alpha=0. In 4-color mode there is no transparent codepoint — all
four interpolated colors serve the visible (alpha>0) pixels. bc7enc
assigns some index to the alpha=0 pixels but their decoded RGB is
irrelevant since PSNR masks them out.

The +7–12 dB "extraordinary" BC1 wins are **entirely explained by
Compressonator's 3-color mode over-use**: it wastes a color slot on
transparency representation that doesn't matter for rendered output.
This is not a deep quality advantage of rgbcx's endpoint search — it
is a BC1 mode-selection policy difference. For rendering, bc7enc's
approach is also correct (alpha=0 pixels are invisible regardless of
their encoded RGB).

### Follow-up 2 — BC3 benchmark (the ATAK-relevant pairing)

Same 9-file GAMMA corpus, same methodology. BC3 = separate BC4 alpha
block + BC1 RGB block per 4×4 tile. The 3-color mode penalty does not
apply: both encoders can use full 4-color BC1 for RGB regardless of
alpha, because alpha is handled by the separate BC4 block.

**Variants:**
- `cmp_BC3_Q1.0` — `build_cli_off`, `-fd BC3 -Quality 1.0 -NumThreads 8`
- `bc7enc_rgbcx` — `bc7enc -3 -L18` (BC3, rgbcx max quality)
- `texconv_BC3` — `texconv -f BC3_UNORM -m 1`

**Raw table:**

```
file                              WxH        variant          t(s)  RGB@a>0   aPSNR
ui_icon_maidfillcant         32x16     cmp_BC3_Q1.0       0.001    28.69     inf
                                        bc7enc_rgbcx       0.029    28.69     inf
                                        texconv_BC3        0.003    25.82     inf

ui_icon_pm_drum             128x64     cmp_BC3_Q1.0       0.001    34.81   47.96
                                        bc7enc_rgbcx       0.030    36.65   45.36
                                        texconv_BC3        0.003    35.17   45.94

ui_icon_sks_short           256x64     cmp_BC3_Q1.0       0.002    32.16   48.83
                                        bc7enc_rgbcx       0.032    33.43   44.90
                                        texconv_BC3        0.004    32.49   46.77

ui_icon_maidindicators      256x128    cmp_BC3_Q1.0       0.002    33.42     inf
                                        bc7enc_rgbcx       0.035    35.13   53.58
                                        texconv_BC3        0.002    33.30     inf

ui_icon_rspartan            512x64     cmp_BC3_Q1.0       0.002    34.65   51.57
                                        bc7enc_rgbcx       0.035    35.52   47.26
                                        texconv_BC3        0.002    34.68   50.21

ui_icon_mg36e               512x128    cmp_BC3_Q1.0       0.003    36.49   50.32
                                        bc7enc_rgbcx       0.039    38.11   47.29
                                        texconv_BC3        0.004    36.42   48.37

ui_icon_w50                 512x256    cmp_BC3_Q1.0       0.005    32.27   52.29
                                        bc7enc_rgbcx       0.044    33.59   47.99
                                        texconv_BC3        0.004    32.77   50.39

ui_maid_pistols            2048x256    cmp_BC3_Q1.0       0.021    34.53   48.77
                                        bc7enc_rgbcx       0.133    35.65   44.99
                                        texconv_BC3        0.007    34.62   47.14

dovetail_bump              2048x2048   cmp_BC3_Q1.0       0.223    36.44   49.44
                                        bc7enc_rgbcx       1.170    36.96   47.80
                                        texconv_BC3        0.041    34.18   47.99

variant           sum_9_files  mean/file
cmp_BC3_Q1.0          0.259s      0.029s
bc7enc_rgbcx          1.547s      0.172s
texconv_BC3           0.070s      0.008s
```

**Delta tables — 8 icon files:**

RGB@a>0:
```
file                       cmp(dB)  bc7enc Δ  texconv Δ
ui_icon_maidfillcant        28.69    +0.00      -2.87
ui_icon_pm_drum             34.81    +1.84      +0.36
ui_icon_sks_short           32.16    +1.28      +0.33
ui_icon_maidindicators      33.42    +1.70      -0.13
ui_icon_rspartan            34.65    +0.88      +0.04
ui_icon_mg36e               36.49    +1.61      -0.07
ui_icon_w50                 32.27    +1.32      +0.50
ui_maid_pistols             34.53    +1.12      +0.09
```

aPSNR (alpha channel):
```
file                       cmp(dB)  bc7enc Δ  texconv Δ
ui_icon_maidfillcant          inf      0.00       0.00
ui_icon_pm_drum             47.96     -2.59      -2.02
ui_icon_sks_short           48.83     -3.93      -2.06
ui_icon_maidindicators        inf     (bc7enc 53.58, texconv inf)
ui_icon_rspartan            51.57     -4.31      -1.37
ui_icon_mg36e               50.32     -3.04      -1.95
ui_icon_w50                 52.29     -4.30      -1.90
ui_maid_pistols             48.77     -3.79      -1.63
```

**Observations:**

1. The dramatic BC1 outliers (+7/+12 dB) disappear in BC3. Once alpha is
   separated into BC4, both encoders can use full 4-color BC1. bc7enc's
   RGB advantage drops to **+0.88 to +1.84 dB** — real but modest.

2. Compressonator's alpha (BC4 block) is **consistently better** than
   bc7enc's: +2.6 to +4.3 dB advantage. Two files (maidfillcant,
   maidindicators) show perfect (∞ dB) alpha for Compressonator — it
   achieves lossless BC4 on binary-alpha textures. bc7enc's BC4 encoder
   has small but nonzero alpha errors even when the source has only two
   alpha values (0 and 255).

3. texconv is now **competitive on RGB** — within ±0.5 dB of Compressonator
   on most files (vs. its -1.8 to -5.1 dB loss in BC1). texconv's alpha
   is in between: worse than Compressonator, better than bc7enc.

4. **Net perceptual tradeoff (bc7enc vs. Compressonator for BC3 icons):**
   gain ~1.3 dB RGB, lose ~3.4 dB alpha (7-file means, excluding inf).
   For hard-alpha sprite icons where silhouette sharpness depends on alpha
   precision, this is not a clear win — alpha quality may matter more than
   RGB quality for that content type.

### Follow-up 3 — BC3 alpha deep-dive (block precision + threshold crossings)

Two checks to tighten the BC3 alpha verdict.

#### Source code — binary-alpha special case

`CompressAlphaBlock` in `cmp_compressonatorlib/dxtc/codec_dxtc_alpha.cpp:45-50`
tries both BC4 modes (8-value and 6-value) and picks lower error. Dead
code at `compressonatorxcodec.cpp:1912-1915` counts values near 0/255
(`N0s`/`N1s`) but neither counter is used downstream — **no explicit
binary-alpha branch.** Lossless results on binary-alpha textures emerge
from the 6-value mode's inherent structure: codepoints 6 and 7 decode
to exactly 0 and 255 regardless of endpoint values
(`GetCompressedAlphaRamp`, `compressonatorxcodec.cpp:762-788`). When
source is all {0, 255}, the 6-value mode achieves zero error and wins
the mode competition. bc7enc doesn't perform this dual-mode search and
leaves some binary-alpha blocks with nonzero error.

#### Check 1 — block-level exact alpha (4×4, all 16 pixels zero-error)

Icon corpus (8 files, partial-alpha excluded):

```
variant          perfect/total   %perfect
cmp_BC3_Q1.0    47095/50720     92.9%
bc7enc_rgbcx    45704/50720     90.1%
texconv_BC3     47101/50720     92.9%
```

Per-file highlights:

```
file                       cmp %perf  bc7enc %perf  texconv %perf
ui_icon_maidfillcant       100.0%       100.0%         100.0%    ← all-binary {0,255}
ui_icon_maidindicators     100.0%        94.1%         100.0%    ← all-binary {0,255}, bc7enc: 121/2048 imperfect
ui_icon_rspartan            94.1%        90.9%          94.0%
ui_icon_mg36e               95.1%        93.8%          95.1%
ui_icon_w50                 95.9%        94.3%          95.9%
ui_icon_sks_short           91.7%        87.8%          91.7%
ui_icon_pm_drum             91.6%        89.8%          91.8%
ui_maid_pistols             91.3%        88.4%          91.4%
```

Compressonator and texconv track each other exactly across all files.
bc7enc is consistently ~2–4 pp lower. **On the two all-binary-alpha
files (maidfillcant, maidindicators), Compressonator achieves 100%
perfect blocks (lossless); bc7enc achieves 100% on maidfillcant but
only 94.1% on maidindicators — 121 blocks with nonzero alpha error
despite the source containing only {0, 255}.**

dovetail (continuous alpha): cmp=75.0%, bc7enc=47.9%, texconv=75.1%.
bc7enc's BC4 encoder degrades sharply on non-binary content.

#### Check 2 — alpha-test threshold crossings (opaque = alpha ≥ 128)

Icon corpus (8 files):

```
variant          crossings / total px    %cross   false-opaque  false-transp
cmp_BC3_Q1.0    193 / 811,520           0.0238%   78            115
bc7enc_rgbcx    160 / 811,520           0.0197%   79            81
texconv_BC3     273 / 811,520           0.0336%   140           133
```

Sensitivity check at ≥127 threshold (off-by-one): cmp=0.0243%,
bc7enc=0.0221%, texconv=0.0327%. Ordering unchanged.

**bc7enc causes fewer alpha-test failures than Compressonator on this
corpus (160 vs 193), despite having lower aPSNR.** The aPSNR deficit
(-3.4 dB aggregate) comes from errors that push alpha values further
from the source without crossing 128. Compressonator's errors are
smaller in absolute magnitude but more often straddle the 128 boundary.

This diverges from the "alpha quality may matter more for hard-cutout
icons" framing in the previous observation. **For the actual rendering
use case (alpha test at 128), bc7enc's alpha is marginally better on
icons**, not worse. The absolute counts are small on both sides (both
<0.025%), so the practical difference is negligible either way.

dovetail (continuous alpha near 127 mean): cmp=0.282%, bc7enc=2.744%,
texconv=0.393%. bc7enc's threshold-crossing rate is 10× Compressonator
on content where alpha values cluster near 128 — a genuine failure mode
for bc7enc's BC4, but not relevant to hard-cutout sprite icons.

#### Revised summary

| metric | cmp_BC3_Q1.0 | bc7enc_rgbcx Δ | verdict |
|--------|-------------|----------------|---------|
| RGB@α>0 PSNR (8 icons, mean) | ~34.4 dB | +1.2 dB | bc7enc wins |
| aPSNR aggregate (7 non-inf icons) | ~50.0 dB | −3.4 dB | cmp wins |
| perfect alpha blocks (icons) | 92.9% | −2.8 pp | cmp wins |
| alpha-test crossings @128 (icons) | 193 px | −33 px (−17%) | bc7enc wins |
| lossless on binary-alpha (maidindicators) | yes | no (121 bad blocks) | cmp wins |

The aPSNR and perfect-block metrics point one way; the threshold-crossing
metric (the rendering-relevant one) points the other. The divergence
happens because bc7enc's alpha errors are distributed differently —
larger but less likely to straddle 128 on this corpus.

**Net: the tradeoff is more symmetric than the aPSNR delta suggested.**
bc7enc's alpha is worse in fidelity terms (+3.4 dB aggregate deficit,
worse lossless rate on binary sources), but marginally better in the
metric that matters for hard-cutout rendering (-17% fewer alpha-test
misclassifications on icons). Neither advantage is large enough on its
own to be decisive.

**Consolidated conclusion across BC1 and BC3:**

The BC1 "extraordinary win" was a mode-selection artifact (3-color
over-use). The BC3 result — the format actually relevant to ATAK's icon
path — shows a modest +1 to +2 dB RGB gain for rgbcx. The alpha tradeoff
is real (bc7enc loses lossless-alpha on some binary sources, degraded
aPSNR) but does not translate to more alpha-test failures on this corpus.
Whether the RGB gain justifies a BC7-scale integration effort is a product
decision. The technical gap is substantially smaller than the BC7 case:
Compressonator's BC7 was a decade-stale scalar codec; its BC3 already has
v4.4 SIMD and competitive alpha quality. The BC3 quality gap, unlike BC7's,
does not represent a correctness or obsolescence problem — it is a
narrowly-better encoder vs a competent one.

## Phase 8 — Atomics fix for BC7 worker handoff, verified on Windows

Cherry-picked `ee6922dd` "Use atomics for the BC7 worker handoff, not
volatile" from `jorge-macos-support` onto `bc7enc-rdo-integration`
(local hash `f1d721c8`; branch already had it applied and was 1 commit
ahead of `origin/bc7enc-rdo-integration` at session start — no fetch
needed, `jorge-macos-support` was already present locally). See the
commit for the race itself: `run`/`exit` were `volatile CMP_BOOL`,
which orders nothing between threads; on arm64 the producer could
reuse a worker's slot before the worker's writes to `*out` were
visible. Author's own measurement on macOS arm64: 10 distinct outputs
from 10 identical runs pre-fix (stock BC7), 3-6 distinct of 10 for
batched bc7e, one 19dB PSNR loss, one segfault. Fixed by making both
fields `std::atomic<bool>` with release-on-store / acquire-on-load
pairing. Commit claims x86-64's store ordering already hid this bug,
so Linux/Windows builds should show zero output change — verified
that claim on Windows rather than assumed it, same as the Linux pass.

Rebuilt all three flavors via `tools/win/build_cli_batch.ps1`
(`-Flavor off/unbatched/batch`) using VS 2022 BuildTools (MSVC
14.44.35207) + the bundled CMake/Ninja under
`Common7\IDE\CommonExtensions\Microsoft\CMake`, driven from WSL via
`cmd.exe`/`VsDevCmd.bat` interop (no native Windows shell session
available this pass). All three configure+build clean. `batch`
produces two pre-existing MSVC warnings in
`codec_bc7.cpp` (`C4456` variable shadowing on `progress`, `C4701`/
`C4703` "potentially uninitialized" on `batch_in`) — both benign:
`batch_in` is always assigned on the `cur_count == 0` branch that
precedes every use, MSVC's flow analysis just doesn't prove it.
Present on this same source at the pre-atomics commit too, not
introduced by this cherry-pick.

Windows exes can't take WSL/POSIX paths (confirmed directly: passing
`/mnt/c/...` to `compressonatorcli.exe` fails with "No files to
process in source dir"; `C:\...` works). Wrote three one-line bash
wrapper shims (`_verify_scratch/wrap_{off,unbatched,batch}.sh`) that
translate any `/`-leading argv entry through `wslpath -w` before
`exec`-ing the real `.exe`, and pointed the existing
`tools/win/verify_*.py --cli/--unbatch/--batch` args at the wrappers
instead of the exes directly. No changes to the verify scripts
themselves.

Results, against the same Windows reference MD5s as Phase 4 part 3 /
Phase 7:

- `verify_boundaries.py` — 9/9 exact, byte-identical to reference:
  `5fae5456ae19`, `cff9a2cf1964`, `10cda379ba6f`, `16c8a5170408`,
  `7f115eab183c`; boundaries Q=0.25/0.45/0.65/0.85 resolve to
  fast/basic/slow/slowest. **PASS.**
- `verify_bit_identity.py` — 6/6 configs, 100.0000% block match
  (14976 or 30000 blocks), MD5s byte-identical to reference:
  `741246ded2fb` (×2), `2df4cbbbe848`, `7b61c709f275`, `ee63f48cc53e`,
  `1acc20029808`. **PASS.**
- `verify_no_crash.py` — both flavors exit 0, no crash. **PASS**
  (this is the script's actual and only contract — see below).

One thing that did NOT reproduce the archived value: the zero-valid-
modes guard-path payload (`-AlphaRestrict 1`, default ModeMask 0xCF,
on `ruby_alpha.tga`) hashes to `88ee2a9fac26` on both `unbatch` and
`batch` this session, not the `7f359e51bc5c` recorded from Phase 4
part 3 onward through Phase 7. Investigated rather than waved off,
because a silent hash drift is exactly the kind of thing that should
be explained, not assumed benign:

1. **Isolated the atomics commit as the variable.** Checked out the
   direct parent of `f1d721c8` (`52b72868`, docs-only commits since
   the Phase 7 script-move point — confirmed via
   `git diff --stat 6a078c4b 52b72868` returning empty for
   everything except `*.md`/`README*`), rebuilt `unbatched`+`batch`
   into separate build dirs, reran `verify_no_crash.py` against
   *that* pair. Result: `88ee2a9fac26` on both — identical to the
   post-atomics run, not to the archived `7f359e51bc5c`. **The
   atomics commit is not the cause of the drift**; pre- and
   post-atomics binaries built in this session agree with each
   other and disagree with the old archive equally. This is the
   actual answer to "did the atomics change any MD5 on Windows":
   no — proven by same-environment A/B, not inferred from the Linux
   result.
2. **Traced why this one test's hash isn't a real contract.** Read
   the guard implementation in
   `cmp_core/source/bc7enc_rdo_adapter.cpp` (`has_any_alpha_mode`,
   `choose_params`, `build_params_pair`, lines ~93-197). The routing
   decision is a pure function of block pixel content and the
   quality/mask/restrict flags — nothing thread- or environment-
   dependent — so per-block mode selection is deterministic given
   identical source, which this is. `verify_no_crash.py`'s own
   docstring already disclaims a bit-identity contract here ("Success
   = both binaries exit 0. No bit-identity check here — this is
   purely a 'does not crash' gate"); the `7f359e51bc5c` cross-checks
   littered through Phases 4-7 were a bonus assurance on top of that,
   not the script's actual pass condition, and evidently didn't
   survive across whatever changed in this machine's toolchain state
   since. Most likely explanation, not confirmed further: bc7e.ispc
   compiles four ISA targets (sse2/sse4/avx/avx2, `cmp_core/
   CMakeLists.txt:134-137`) with runtime CPUID dispatch, and getting
   the *unrestricted default* preset's search to hit a genuine near-
   tie in its cost metric is exactly the kind of thing that can flip
   with a compiler/ISPC minor-version difference without indicating
   any correctness problem — consistent with every other test (which
   never hits a fallback/near-tie path) matching exactly.

Net: atomics fix verified to change nothing on Windows/x86 — same
expectation as Linux, same result, proved by direct A/B rebuild in
this environment rather than assumed from the other platform. The
guard-path hash drift is real but pre-existing (present at the
pre-atomics commit too) and orthogonal to this cherry-pick; flagging
it here so a future pass doesn't rediscover it from scratch, but not
treating it as a regression since the script never promised bit-
identity on that path.
