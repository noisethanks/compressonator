# Compressonator + bc7enc_rdo (BC7 CPU codec swap)

A fork of [AMD Compressonator](https://github.com/GPUOpen-Tools/compressonator)
that replaces the CPU-side BC7 codec with the `bc7e.ispc` encoder from
[richgel999/bc7enc_rdo](https://github.com/richgel999/bc7enc_rdo).

> This README section describes the fork. **Everything below the horizontal
> rule is AMD's original README, unmodified.** The full investigation —
> every measurement, dead end, and correction — lives in
> [`NOTES.md`](https://github.com/noisethanks/compressonator/blob/bc7enc-rdo-integration/NOTES.md).

---

## 1. What this fork is

Compressonator's DDS I/O, mip generation, batch processing and CLI are
excellent and kept entirely intact. What changed is one thing: the BC7
block encoder underneath them.

The motivation is a documented endpoint **p-bit rounding** issue in
DirectXTex/texconv — its endpoint quantization doesn't properly compensate
rounding for the chosen parity bit. Microsoft partially fixed the
correctness bug in 2018 but never adopted the fully optimal "search all
p-bit combinations with compensated rounding" approach. `bc7e.ispc`
implements the correct approach and vectorizes it through ISPC, which also
sidesteps the second problem: there is no cross-vendor, cross-platform
GPU-accelerated BC7 path that behaves identically on AMD, NVIDIA and
machines with no usable GPU at all. A CPU SIMD encoder doesn't need one.

The p-bit issue is documented by Richard Geldreich in two April 2018
posts:

- ["A tale of multiple BC7 encoders"](http://richg42.blogspot.com/2018/04/a-tale-of-multiple-bc7-encoders.html)
- ["Proper pbit computation in the BC7 texture format"](http://richg42.blogspot.com/2018/04/proper-pbit-computation-in-bc7-texture.html)

This is built on two existing projects, not written from scratch:

- **AMD Compressonator** — the surrounding tool, all container/format
  handling, the CLI. MIT.
- **bc7enc_rdo / `bc7e.ispc` by Richard Geldreich** — the BC7 encoder
  doing the actual block compression. Apache 2.0.

## 2. Usage

**The codec is selected at build time, not at runtime.** There is no CLI
flag to switch encoders — the selection is a compile-time `#ifdef`
(`CMP_USE_BC7ENC_RDO` / `CMP_USE_BC7ENC_RDO_BATCH`, see
`cmp_compressonatorlib/bc7/codec_bc7.cpp`). Build the flavor you want:

| CMake options | Encoder used |
|---|---|
| *(neither set)* | Stock Compressonator BC7 (unchanged upstream behavior) |
| `-DOPTION_CMP_USE_BC7ENC_RDO=ON` | bc7e.ispc, one block per call |
| `-DOPTION_CMP_USE_BC7ENC_RDO=ON -DOPTION_CMP_USE_BC7ENC_RDO_BATCH=ON` | bc7e.ispc, SIMD-batched — **the recommended build** |

Once built, invocation is ordinary Compressonator:

```
compressonatorcli -fd BC7 -EncodeWith CPU -Quality 1.0 in.png out.dds
```

### Existing flags still work — and were verified, not assumed

`-Quality`, `-ModeMask`, `-ColourRestrict` and `-AlphaRestrict` all map
onto bc7e's parameters and were checked against the stock codec's
behavior. This mattered because the first implementation **got it wrong**:

- The Q→preset bucketing was verified by MD5-comparing encodes at
  interior quality values against the four bucket boundaries
  (Q = 0.25 / 0.45 / 0.65 / 0.85). **2 of 4 boundaries initially
  misresolved** — Q=0.45 landed in `fast` instead of `basic`, Q=0.65 in
  `basic` instead of `slow`. See *Phase 3 part 4b* in `NOTES.md`.
- Root cause turned out to be two float-precision truncations in series
  on the CLI path — `std::stof` at `cmdline.cpp:411` and a
  `(CODECFLOAT)` cast at `compress.cpp:223` (`CODECFLOAT` is
  `typedef float`). *Phase 3 part 4b* first blamed `codec_bc7.cpp:131`;
  that was traced and **corrected** in *Phase 3 part 4c* — that line sits
  on a dead string-overload path the CLI never reaches.
- Post-fix the boundary sweep is **9/9 exact** and the per-block and
  batched paths are **bit-identical across 6 configurations, 100.0000%
  block match** (14 976 or 30 000 blocks per config), including the
  `-ColourRestrict` / `-AlphaRestrict` / `-ModeMask 255` combinations.

## 3. What's different from stock, and why

### Omitted from this build

| Feature | Why |
|---|---|
| Image analysis (`-Analysis`, SSIM) | Requires OpenCV, which drags shared-library dependencies back in. Not on the BC7 encode path. |
| KTX2 | Requires Git LFS assets and a working host Python at configure time. Not needed for DDS output. |
| Brotli-G | Same — its configure step shells out to Python. |
| GPU / DirectCompute encoding | This fork's whole premise is a CPU encoder that behaves identically everywhere. |
| **ETC / ETC2** | **License scope — see below.** |

**On ETC/ETC2:** Compressonator bundles ETCPack, which ships under an
Ericsson SLA whose scope restricts use to Khronos-standard texture
compression development. A general-purpose BC7 CLI that also happens to
contain ETC codecs sits in ambiguous territory relative to that scope.
Rather than interpret the SLA, this build removes the code: ETCPack is
gated out at compile time behind `OPTION_CMP_ETC=OFF`. Verified by
symbol and string audit on the built binaries — `CCodec_ETC` symbols
**272 → 0**, `compressBlockETC` **47 → 0**, Ericsson SLA strings
**4 → 0**. Requesting an ETC format now behaves exactly like requesting
an unknown one (exit 255, no file written), rather than crashing or
emitting garbage.

*(Full honesty, per the audit: 3 `ETC2` symbols and 4 ETC format-name
strings do survive. They are string literals from the format
enum↔name lookup table at `applications/_plugins/common/atiformats.cpp:111-114`
— format identifiers only, no Ericsson-authored code, no SLA text.)*

### What you get in exchange

Fully static, zero-runtime-dependency binaries on both platforms:

| Platform | Result |
|---|---|
| **Linux** | **0 dynamic dependencies.** `ldd` reports *"not a dynamic executable"*. No libstdc++ version requirement, no OpenCV, no GL. |
| **Windows** | **3 DLLs**, all shipped with the OS: `KERNEL32.dll`, `ole32.dll`, `imagehlp.dll`. No Visual C++ redistributable, no UCRT — `MSVCP140`, `VCRUNTIME140`, `VCRUNTIME140_1` and all ten `api-ms-win-crt-*` entries are gone (16 → 3). |

Install-nothing on any modern glibc or Windows target. That is the point:
this binary is meant to be shipped inside another tool and shelled out to.

> **If you need the omitted features, run stock Compressonator alongside
> this build.** They coexist fine — this fork is a specialized BC7
> encoder, not a replacement for the full toolchain.

## 4. Building

Three canonical, tested build recipes. Prefer them over assembling flags by
hand — they encode a long tail of platform-specific fixes.

| Platform | Script |
|---|---|
| Linux | `tools/linux/build_flavor.sh [off\|unbatched\|batch]` |
| Windows | `tools/win/build_cli_batch.ps1 -Flavor <off\|unbatched\|batch>` |
| macOS | `tools/macos/build_flavor.sh [off\|unbatched\|batch] [arm64\|x86_64\|universal]` |

All three live in this repository, and all three expect to be run from a
checkout where `compressonator/` and `bc7enc_rdo/` sit side by side — they
resolve the outer root by walking up from their own location. The macOS
script also accepts `ISPC=` and `BC7ENC=` if your layout differs.

The flavor parameter selects the encoder and the build directory:

| Flavor | Encoder | Build dir |
|---|---|---|
| `off` | Stock Compressonator BC7 | `build_cli_off` |
| `unbatched` | bc7e.ispc, per-block | `build_cli` |
| `batch` | bc7e.ispc, SIMD-batched | `build_cli_batch` |

`batch` is the default and the recommended build.

macOS builds one slice per run and appends the architecture to the build
directory, as in `build_cli_batch_macos_arm64`. Its second argument selects
the slice, and `arm64` is the default. Every run ad-hoc signs its output with
`--identifier compressonatorcli` and honours `OUTPUT=`, so one run already
produces a shippable binary. `universal` builds both slices and joins them
with `lipo -create` before signing.

### Prerequisites

- **bc7enc_rdo checkout** next to this repository — the build validates
  that `bc7e.ispc` is present and fails early if not.
- **External dependencies**, via `python3 build/fetch_dependencies.py`.
  `external/CMakeLists.txt` includes `glm` and `rapidxml` for any CLI
  build, whatever `OPTION_CMP_OPENGL` and `OPTION_CMP_QT` are set to, so
  this is required and not optional. On macOS the script ends in a
  traceback on its last item, an OpenEXR tarball from a plain-HTTP host
  that no longer answers; `OPTION_BUILD_EXR` is OFF in these recipes, so
  that one is not needed. The macOS script checks for the two directories
  the CLI actually resolves and names this command if they are missing.
- **ISPC v1.31.0**, pinned. Linux expects it unpacked at
  `tools/ispc/linux/bin/ispc`, macOS at `tools/ispc/macos/bin/ispc`, and the
  Windows script expects the equivalent Windows package. The version is
  pinned deliberately — `bc7e.ispc` is compiled by it.
- A C++ toolchain. Verified on GCC (Linux), MSVC 17.14 / Visual Studio
  2022 Build Tools with Windows SDK 10.0.26100 (Windows), and Apple clang
  from the Xcode Command Line Tools (macOS).
- CMake 3.13 or later, for `-S`/`-B` and `--build --parallel`. On macOS,
  installing CMake.app puts nothing on `PATH`; the script looks in
  `/Applications` and in the Homebrew prefix before giving up, and `CMAKE=`
  overrides it.

**On macOS the ISPC host architecture decides whether the encoder is
correct.** An aarch64 *host* of ispc 1.19 or later silently miscompiles `--`
on a varying unsigned int into a no-op
([ispc#3882](https://github.com/ispc/ispc/issues/3882)), which corrupts
bc7e's bit packing
([bc7enc_rdo#23](https://github.com/richgel999/bc7enc_rdo/issues/23)) for
every target, not only arm64. This recipe disables assertions, so the
failure is silent. Either remedy works, and the script accepts both: apply
[bc7enc_rdo#29](https://github.com/richgel999/bc7enc_rdo/pull/29), which
rewrites the five affected sites as `x -= 1`, or use the x86_64 ISPC
package under Rosetta 2. The script refuses only the unsafe combination.

Separately, which architectures an ISPC can emit depends on the LLVM it was
built against, not on its own Mach-O slice, and bc7enc_rdo#29 does not change
that. The official macOS packages carry both backends, so
`ispc-v1.31.0-macOS.arm64` cross-compiles the x86_64 slice. Homebrew's `ispc`
links `llvm@22` and rejects `--arch=x86-64` outright. The script compiles a
throwaway kernel for each requested slice before starting any build, so a
mismatch fails in the first second rather than minutes into `make`.

On Windows, `build_cli_batch.ps1` deliberately does **not** bootstrap the
Visual Studio environment. Run it from a Developer PowerShell, or wrap it with
`VsDevCmd.bat` yourself.

For the same reason, the macOS script stops at a printed path and does not
fetch ISPC, clone bc7enc_rdo, apply bc7enc_rdo#29, or install Rosetta 2. It
detects each and prints the exact command.

## 5. Results

Headline benchmark: 9-file corpus of real game textures (hard-alpha UI
cutouts plus a 2048×2048 normal map), best-of-3 wall clock, alpha-aware
PSNR with the decoder held constant across every variant.

| Variant | Corpus wall clock | vs. batched bc7e |
|---|---:|---|
| texconv (DirectXTex CPU BC7, `-bc x`) | 175.350 s | **131× slower** |
| Stock Compressonator `-Quality 1.0` | 16.392 s | **12.3× slower** |
| Stock Compressonator, default quality | 2.213 s | 1.66× slower |
| **Batched bc7e `-Quality 1.0`** | **1.336 s** | — |

Quality, RGB PSNR restricted to pixels with source alpha > 0:

- **vs. texconv:** batched bc7e wins on **every one of the 9 files**, by
  **+1.91 to +13.51 dB** (median ≈ +2.6 dB). No dimension on which
  texconv wins. The +13.51 dB outlier is a hard-alpha cutout icon where
  texconv under-selects BC7 mode 7 (14.3% of blocks vs. 39.6% for both
  stock and this fork) — consistent with the p-bit issue in §1.
- **vs. stock at `-Quality 1.0`:** matched. Better on 4 files, worse on 5,
  worst case 1.08 dB, no systematic direction. Same quality tier, 12.3×
  faster.

**Independently reproduced on a second machine, OS and compiler.** The
above was measured on Linux/GCC (Ryzen 7 5800X); the full corpus was
re-run on Windows/MSVC (Ryzen 7 5800H) and **26 of 27 recorded PSNR
values reproduced digit-for-digit**. The single exception is in the
*stock* codec's float path, not this fork's — see §7. Absolute times
aren't comparable across those machines; the qualitative result is.

Full tables, methodology and the investigation behind them:
*Phase 3 part 6* and *Phase 4 part 4* in [`NOTES.md`](https://github.com/noisethanks/compressonator/blob/bc7enc-rdo-integration/NOTES.md).

## 6. License and attribution

Two licenses apply to the shipped binary:

| Component | License |
|---|---|
| AMD Compressonator (AMD/ATI code paths) | MIT |
| `bc7e.ispc` (richgel999/bc7enc_rdo) | Apache 2.0 |

Both license texts must be included in any release. **The Apache 2.0
side additionally requires the release to identify the incorporated
Apache-2.0 component**, which is satisfied here:

> This software incorporates **`bc7e.ispc`** from
> [richgel999/bc7enc_rdo](https://github.com/richgel999/bc7enc_rdo),
> © Richard Geldreich, licensed under the Apache License, Version 2.0.

ETCPack and its Ericsson SLA are **not** part of this build's license
surface — see §3.

## 7. Known upstream issues found during this work

These are bugs in **stock Compressonator**, found while testing this
fork's changes. They affect upstream regardless of this work.

| # | Issue | Status |
|---|---|---|
| 1 | **Zero-valid-modes crash.** `-AlphaRestrict 1` with the default `-ModeMask` (0xCF) on mixed 0/255 alpha yields `validModeMask == 0` for affected blocks. Stock's search loop exits without setting `encodedBlock`, and the `if (!encodedBlock)` handler is a documented-as-error no-op — leaving the previous buffer contents as the encoded block. Non-deterministic garbage. A debug `assert` catches it, so it never trips in developer testing. | **Not reported upstream** |
| 2 | **`CODECFLOAT` quality-precision truncation.** `-Quality` loses precision twice on the CLI path (`std::stof` at `cmdline.cpp:411`, then a `(CODECFLOAT)` cast at `compress.cpp:223`; `CODECFLOAT` is `typedef float`). `-Quality 0.45` arrives as `0.44999998807907104`, landing on the wrong side of a threshold comparison. `CODECFLOAT` is used in 484 places, so the fix needs care. | **Not reported upstream** |
| 3 | **MSVC-vs-GCC discrepancy in the stock codec.** One file in the corpus (`ui_icon_mg36e`) reads 41.884 dB under MSVC vs. 41.89 dB recorded under GCC, in stock's float-heavy shaker refinement path. Checked at higher precision to rule out a rounding-boundary artifact — it's a real, tiny (≥0.005 dB) difference. | **Not reported upstream** — and not root-caused. No byte-level Linux reference exists for corpus outputs, so it couldn't be traced further. |

## 8. Platform support

| Platform | Status |
|---|---|
| **Linux** | Built, verified, fully static (0 dynamic dependencies). |
| **Windows** | Built, verified, statically linked (3 OS-shipped DLLs). |
| **macOS** | Built, verified. Universal (x86_64 + arm64), ad-hoc signed, 3 OS-shipped dylibs. |

**Linux and Windows correctness is backed by byte-identical output**, not by
assertion. Every verification MD5 produced by the Windows/MSVC build
matches the Linux/GCC reference exactly:

| Check | Result |
|---|---|
| Centibucket boundary sweep | **9/9 exact MD5 match** |
| Per-block vs. batched bit-identity | **6/6 configs, 100.0000% block match** |
| Zero-valid-modes guard output | payload MD5 `7f359e51bc5c` on both platforms |

The same three harnesses were re-run after every relink and code-removal
pass in this project — the static-linking change and the ETC removal
both had to prove they were byte-level no-ops before being accepted.

**macOS does not join that byte-identity claim, and cannot.** The arm64
slice encodes through bc7e's NEON target and the scalar BC1/BC3/BC4/BC5
kernels built for arm64, both of which differ in the low bits from the
SSE/AVX build. Measured on a mixed corpus, 18 of 38 format/mip
configurations differ byte-wise between the two macOS slices, while PSNR
tracks to within ±0.1 dB. Output stays reproducible *within* a slice: the
same input gives the same bytes on every run. Treat the MD5 harnesses above
as a Linux/Windows contract and macOS as quality-equivalent, not
bit-equivalent.

macOS also carries one fix the other two platforms never needed to expose: a
data race in the BC7 worker handoff, which `volatile` does not order. x86-64
store ordering hides it completely. On arm64 it produced 10 distinct outputs
from 10 identical runs of the **stock** codec, so it is an upstream defect
that the macOS port merely made visible.

---


# Compressonator
[![CMake](https://github.com/GPUOpen-Tools/compressonator/actions/workflows/cmake.yml/badge.svg)](https://github.com/GPUOpen-Tools/compressonator/actions/workflows/cmake.yml)
![download](https://img.shields.io/github/downloads/GPUOpen-Tools/Compressonator/total.svg)
![download](https://img.shields.io/github/downloads/GPUOpen-Tools/Compressonator/V4.5.52/total.svg)

*Download the latest revision for changes that have been made since the last major release by clicking the CMake button above or the link [here](https://github.com/GPUOpen-Tools/compressonator/actions/workflows/cmake.yml). Currently, only Compressonator Framework and Compressonator CLI are built every revision.*

Compressonator is a set of tools to allow artists and developers to more easily create compressed texture assets or model mesh optimizations and easily visualize the quality impact of various compression and rendering technologies.  It consists of a GUI application, a command line application and an SDK for easy integration into a developer tool chain.

Compressonator supports Microsoft Windows® and Linux builds.

For more details goto the online Compressonator Documents: http://compressonator.readthedocs.io/en/latest/ 

## Build System Updates ##
The code is undergoing a build setup update. This notice will be removed when the changes are completed!
Currently: To use the sln builds run build\fetch_dependencies.py to fetch required external lib dependencies into a Common folder
above this repository.


Get Prebuilt Binaries and Installer here:
---------------------------------------------------
<div>
  <a href="https://github.com/GPUOpen-Tools/Compressonator/releases/latest/"><img src="http://gpuopen-librariesandsdks.github.io/media/latest-release-button.svg" alt="Latest release" title="Latest release"></a>
</div>

To build the source files follow the instructions in http://compressonator.readthedocs.io/en/latest/build_from_source/build_instructions.html

## CMake Build Configuration ##
As of v4.2, The cmake command line options have settings to build specific libs and applications

Examples: Generating Visual Studio Solution File

```c++
Enable building all
    cmake -G "Visual Studio 15 2017 Win64"  
    
Disable all builds except external libs, minimal cmake base setup     
    cmake -DOPTION_ENABLE_ALL_APPS=OFF -G "Visual Studio 15 2017 Win64"
    
Enable only CLI app build    
    cmake -DOPTION_ENABLE_ALL_APPS=OFF -DOPTION_BUILD_APPS_CMP_CLI=ON -G "Visual Studio 15 2017 Win64"
```

For more details reference the CMakeList file on the root folder.

## Style and Format Change ##

The source code of this product is being reformatted to follow the Google C++ Style Guide https://google.github.io/styleguide/cppguide.html

In the interim you may encounter a mix of both an older C++ coding style, as well as the newer Google C++ Style.

Please refer to the _clang-format file in the root directory of the product for additional style information.


## Compressonator Core
Provides block level API access to updated performance and quality driven BCn codecs. The library is designed to be a small self-contained, cross-platform, and linkable library for user applications.

Example usage is shown as below to compress and decompress a single 4x4 image block using BC1 encoder

```c++

// To use Compressonator Core "C" interfaces, just include
// a single header file and CMP_Core lib into  your projects

#include "CMP_Core.h"

// Compress a sample image shape0 which is a 4x4 RGBA_8888 block.
// Users can use a pointer to any sized image buffers to reference
// a 4x4 block by supplying a stride offset for the next row.
// Optional BC1 settings is set to null in this example

unsigned char shape0_RGBA[64] = { filled with image source data as RGBA ...};

// cmpBuffer is a byte array of 8 byte to hold the compressed results.
unsigned char cmpBuffer[8]   = { 0 };

// Compress the source into cmpBuffer
CompressBlockBC1(shape0_RGBA, 16, cmpBuffer,null);

// Example to decompress comBuffer back to a RGBA_8888 4x4 image block
unsigned char imgBuffer[64] = { 0 };
DecompressBlockBC1(cmpBuffer,imgBuffer,null)

```

## Compressonator Framework

Includes Compressonator core with interfaces for multi-threading, mipmap generation, file access of images and HPC pipeline interfaces.

**Example Mip Level Processing using CPU**

```c++

// To use Compressonator Framework "C" interfaces, just include
// a single header file and CMP_Framework lib into  your projects

#include "compressonator.h"

 //--------------------------
 // Init frameworks
 // plugin and IO interfaces
 //--------------------------
 CMP_InitFramework();

//---------------
// Load the image
//---------------
CMP_MipSet MipSetIn;
memset(&MipSetIn, 0, sizeof(CMP_MipSet));
cmp_status = CMP_LoadTexture(pszSourceFile, &MipSetIn);
if (cmp_status != CMP_OK) {
    std::printf("Error %d: Loading source file!\n",cmp_status);
    return -1;
}

//----------------------------------------------------------------------
// generate mipmap level for the source image, if not already generated
//----------------------------------------------------------------------

if (MipSetIn.m_nMipLevels <= 1)
{
    CMP_INT requestLevel = 10; // Request 10 miplevels for the source image

    //------------------------------------------------------------------------
    // Checks what the minimum image size will be for the requested mip levels
    // if the request is too large, a adjusted minimum size will be returned
    //------------------------------------------------------------------------
    CMP_INT nMinSize = CMP_CalcMinMipSize(MipSetIn.m_nHeight, MipSetIn.m_nWidth, 10);

    //--------------------------------------------------------------
    // now that the minimum size is known, generate the miplevels
    // users can set any requested minumum size to use. The correct
    // miplevels will be set acordingly.
    //--------------------------------------------------------------
    CMP_GenerateMIPLevels(&MipSetIn, nMinSize);
}

//==========================
// Set Compression Options
//==========================
KernelOptions   kernel_options;
memset(&kernel_options, 0, sizeof(KernelOptions));

kernel_options.format   = destFormat;   // Set the format to process
kernel_options.fquality = fQuality;     // Set the quality of the result
kernel_options.threads  = 0;            // Auto setting

//=====================================================
// example of using BC1 encoder options 
// kernel_options.bc15 is valid for BC1 to BC5 formats
//=====================================================
if (destFormat == CMP_FORMAT_BC1)
{
    // Enable punch through alpha setting
    kernel_options.bc15.useAlphaThreshold = true;
    kernel_options.bc15.alphaThreshold    = 128;

    // Enable setting channel weights
    kernel_options.bc15.useChannelWeights = true;
    kernel_options.bc15.channelWeights[0] = 0.3086f;
    kernel_options.bc15.channelWeights[1] = 0.6094f;
    kernel_options.bc15.channelWeights[2] = 0.0820f;
}

//--------------------------------------------------------------
// Setup a results buffer for the processed file,
// the content will be set after the source texture is processed
// in the call to CMP_ProcessTexture()
//--------------------------------------------------------------
CMP_MipSet MipSetCmp;
memset(&MipSetCmp, 0, sizeof(CMP_MipSet));

//===============================================
// Compress the texture using Framework Lib
//===============================================
cmp_status = CMP_ProcessTexture(&MipSetIn, &MipSetCmp, kernel_options, CompressionCallback);
if (cmp_status != CMP_OK) {
  ...
}

//----------------------------------------------------------------
// Save the result into a DDS file
//----------------------------------------------------------------
cmp_status = CMP_SaveTexture(pszDestFile, &MipSetCmp);

CMP_FreeMipSet(&MipSetIn);
CMP_FreeMipSet(&MipSetCmp);

```

**Example GPU based processing using OpenCL**

```c++

// Note: Only MD x64 build is used for GPU processing
// SDK files required for application:
//     compressonator.h
//     CMP_Framework_xx.lib  For static libs xx is either MD or MDd, 
//                      When using DLL's make sure the  CMP_Framework_xx_DLL.dll is in exe path
//
// File(s) required to run with the built application
//
// Using OpenCL (OCL) 
//     CMP_GPU_OCL_MD_DLL.dll    or CMP_GPU_OCL_MDd_DLL.dll
//     Encode Kernel files in plugins/compute folder
//     BC1_Encode_Kernel.cpp
//     BC1_Encode_Kernel.h
//     BCn_Common_kernel.h
//     Common_Def.h
//
// Using DirectX (DXC) 
//     CMP_GPU_DXC_MD_DLL.dll    or CMP_GPU_DXC_MDd_DLL.dll
//     Encode Kernel files in plugins/compute folder
//     BC1_Encode_Kernel.hlsl
//     BCn_Common_kernel.h
//     Common_Def.h

#include "compressonator.h"

CMP_FORMAT      destFormat = CMP_FORMAT_BC1;

//---------------
// Load the image
//---------------
CMP_MipSet MipSetIn;
memset(&MipSetIn, 0, sizeof(CMP_MipSet));
if (CMP_LoadTexture(pszSourceFile, &MipSetIn) != CMP_OK) {
    std::printf("Error: Loading source file!\n");
    return -1;
  } 

 //-----------------------------------------------------
 // when using GPU: The texture must have width and height as a multiple of 4
 // Check texture for width and height
 //-----------------------------------------------------
 if ((MipSetIn.m_nWidth % 4) > 0 || (MipSetIn.m_nHeight % 4) > 0) {
    std::printf("Error: Texture width and height must be multiple of 4\n");
    return -1;
 }
    
//----------------------------------------------------------------------------------------------------------
// Set the target compression format and the host framework to use
// For this example OpenCL is been used
//-----------------------------------------------------------------------------------------------------------
KernelOptions   kernel_options;
memset(&kernel_options, 0, sizeof(KernelOptions));

kernel_options.encodeWith = CMP_GPU_OCL;         // Using OpenCL GPU Encoder, can replace with DXC for DirectX
kernel_options.format     = destFormat;          // Set the format to process
kernel_options.fquality   = fQuality;            // Set the quality of the result

//--------------------------------------------------------------
// Setup a results buffer for the processed file,
// the content will be set after the source texture is processed
// in the call to CMP_ProcessTexture()
//--------------------------------------------------------------
CMP_MipSet MipSetCmp;
memset(&MipSetCmp, 0, sizeof(CMP_MipSet));

//===============================================
// Compress the texture using Framework Lib
//===============================================
cmp_status = CMP_ProcessTexture(&MipSetIn, &MipSetCmp, kernel_options, CompressionCallback);
if (cmp_status != CMP_OK) {
  ...
}

//----------------------------------------------------------------
// Save the result into a DDS file
//----------------------------------------------------------------
cmp_status = CMP_SaveTexture(pszDestFile, &MipSetCmp);

CMP_FreeMipSet(&MipSetIn);
CMP_FreeMipSet(&MipSetCmp);

```

## Compressonator SDK

Compressonator SDK supported codecs includes BC1-BC7/DXTC, ETC1, ETC2, ASTC, ATC, ATI1N, ATI2N, all available in a single library.

With the new SDK installation, several example applications with source code are provided that demonstrate how easy it is to add texture compression to your own applications using either "High Level" or "Block Level" APIs.

A simple thread safe interface can compress, decompress and transcode any image as required

`CMP_ConvertTexture(CMP_Texture* pSourceTexture, CMP_Texture* pDestTexture,...);`

**For Example:**

```c++

// To use Compressonator's portable "C" interfaces, just include
// a single header file and Compresonator.lib into  your projects

#include "Compressonator.h"
...

//==========================
// Load Source Texture
//==========================
CMP_Texture srcTexture;
// note that LoadDDSFile function is a utils function to initialize the source CMP_Texture
// you can also initialize the source CMP_Texture the same way as initialize destination CMP_Texture
if (!LoadDDSFile(pszSourceFile, srcTexture))
{
  ...
}

//===================================
// Initialize Compressed Destination
//===================================
CMP_Texture destTexture;
destTexture.dwSize     = sizeof(destTexture);
destTexture.dwWidth    = srcTexture.dwWidth;
destTexture.dwHeight   = srcTexture.dwHeight;
destTexture.dwPitch    = 0;
destTexture.format     = CMP_FORMAT_BC6H;
destTexture.dwDataSize = CMP_CalculateBufferSize(&destTexture);
destTexture.pData      = (CMP_BYTE*)malloc(destTexture.dwDataSize);

//==========================
// Set Compression Options
//==========================
CMP_CompressOptions options = {0};
options.dwSize       = sizeof(options);
options.fquality     = 0.05f;
options.dwnumThreads = 8;

//==========================
// Compress Texture
//==========================
CMP_ERROR   cmp_status;
cmp_status = CMP_ConvertTexture(&srcTexture, &destTexture, &options, &CompressionCallback, NULL, NULL);
if (cmp_status != CMP_OK)
{
  ...
}

//==========================
// Save Compressed Testure
//==========================
SaveDDSFile(pszDestFile, destTexture))

free(srcTexture.pData);
free(destTexture.pData);

```


## Compressonator CLI
Command line application that can be batch processed and supports:

- Texture Compression, Decompression, Format Transcoding.
- 3D Model Optimization and Mesh Compression.
- Performance and Analysis Logs such as SSIM, MSE, PSNR.
- MIP Maps, Image Differences, etc. ...

```
C:\>CompressonatorCLI -fd BC7 .\images .results
```
```
C:\>CompressonatorCLI -log -fd BC7 .\images\ruby.png ruby_bc7.dds
```
```
CompressonatorCLI Performance Log v1.0

Source        : .\images\ruby.png, Height 416, Wideth 576, Size 0.936 MBytes
Destination   : ruby_bc7.dds
Using         : CPU
Quality       : 0.05
Processed to  : BC7        with  1 iteration(s) in 1.422 seconds
MSE           : 0.78
PSNR          : 49.2
SSIM          : 0.9978
Total time    : 1.432 seconds

--------------
```


## Compressonator GUI
Comprehensive graphical application that can be used to visualize Images and 3D Models, with support for:

- Texture Compression, Decompression, Format Transcoding.
- 3D Model Optimization and Mesh Compression.
- Multiple Image and 3D Model Views.
- MIP Maps, Differences, Analysis, etc. ...

![screenshot 1](https://github.com/GPUOpen-Tools/Compressonator/blob/master/docs/source/gui_tool/user_guide/media/image51.png)

**glTF 2.0 Model Render View**

![screenshot 2](https://github.com/GPUOpen-Tools/Compressonator/blob/master/docs/source/gui_tool/user_guide/media/image96.png)


## Contributors

Compressonator's GitHub repository (http://github.com/GPUOpen-Tools/Compressonator) is moderated by Advanced Micro Devices, Inc. as part of the GPUOpen initiative.

AMD encourages any and all contributors to submit changes, features, and bug fixes via Git pull requests to this repository.

Users are also encouraged to submit issues and feature requests via the repository's issue tracker.

 
