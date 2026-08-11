cmake_minimum_required(VERSION 3.10)

add_library(CMP_Core STATIC)

target_sources(CMP_Core
    PRIVATE
    shaders/bc1_encode_kernel.h
    shaders/bc1_common_kernel.h
    shaders/bc1_encode_kernel.cpp
    shaders/bc2_encode_kernel.h
    shaders/bc2_encode_kernel.cpp
    shaders/bc3_encode_kernel.h
    shaders/bc3_encode_kernel.cpp
    shaders/bc4_encode_kernel.h
    shaders/bc4_encode_kernel.cpp
    shaders/bc5_encode_kernel.h
    shaders/bc5_encode_kernel.cpp
    shaders/bc6_encode_kernel.h
    shaders/bc6_encode_kernel.cpp
    shaders/bc7_encode_kernel.h
    shaders/bc7_common_encoder.h
    shaders/bc7_encode_kernel.cpp
    shaders/bcn_common_kernel.h
    shaders/bcn_common_api.h
    shaders/common_def.h

    source/cmp_core.h
    source/cmp_core.cpp
    source/cmp_math_vec4.h
    source/cmp_math_func.h

    ../applications/_libs/cmp_math/cpu_extensions.cpp
    ../applications/_libs/cmp_math/cmp_math_common.cpp
)

if (OPTION_CMP_GTC)
    target_sources(
        CMP_Core
        PRIVATE
        shaders/gtc_encode_kernel.h
        shaders/gtc_encode_kernel.cpp
    )
endif()

if (OPTION_BUILD_BROTLIG)
    target_sources(
        CMP_Core
        PRIVATE
        shaders/brlg_encode_kernel.h
        shaders/brlg_encode_kernel.cpp
    )
endif()

target_include_directories(CMP_Core
    PUBLIC
    shaders
    source
    ../applications/_libs/cmp_math/
)

if (UNIX)
    target_compile_definitions(CMP_Core PRIVATE _LINUX ASPM_GPU)
endif()

set_target_properties(CMP_Core PROPERTIES FOLDER ${PROJECT_FOLDER_SDK_LIBS})

# Core SIMD options

# These three libraries are x86 intrinsic code compiled at three instruction
# set levels, and -march=nehalem / haswell / skylake-avx512 are x86 flags.
# Skip them on any other target: core_simd.h gates the declarations and
# bc1_cmp.h gates the dispatch, so the scalar kernels stand alone there.
# On Apple platforms CMAKE_OSX_ARCHITECTURES names the slice being built
# while CMAKE_SYSTEM_PROCESSOR still reports the host, so it has to win —
# an arm64 host cross-building the x86_64 slice needs these libraries.
set(CMP_TARGET_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
if (CMAKE_OSX_ARCHITECTURES)
    set(CMP_TARGET_ARCH "${CMAKE_OSX_ARCHITECTURES}")
endif()

if (CMP_TARGET_ARCH MATCHES "^(x86_64|amd64|AMD64|x86|i[3-6]86)$")
    set(CMP_TARGET_X86 ON)
else()
    set(CMP_TARGET_X86 OFF)
    message(STATUS "CMP_Core: target arch '${CMP_TARGET_ARCH}' is not x86 — building scalar BC1 kernels only")
endif()

if (CMP_TARGET_X86)
    # SSE
    add_library(CMP_Core_SSE STATIC)
    target_sources(CMP_Core_SSE PRIVATE source/core_simd_sse.cpp)
    target_include_directories(CMP_Core_SSE PRIVATE source shaders)

    if (UNIX)
        target_compile_options(CMP_Core_SSE PRIVATE -march=nehalem)
    endif()

    set_target_properties(CMP_Core_SSE PROPERTIES FOLDER ${PROJECT_FOLDER_SDK_LIBS})

    # AVX
    add_library(CMP_Core_AVX STATIC)
    target_sources(CMP_Core_AVX PRIVATE source/core_simd_avx.cpp)
    target_include_directories(CMP_Core_AVX PRIVATE source shaders)

    if (WIN32)
        target_compile_options(CMP_Core_AVX PRIVATE /arch:AVX2)
    else()
        target_compile_options(CMP_Core_AVX PRIVATE -march=haswell)
    endif()

    set_target_properties(CMP_Core_AVX PROPERTIES FOLDER ${PROJECT_FOLDER_SDK_LIBS})

    # AVX-512
    add_library(CMP_Core_AVX512 STATIC)
    target_sources(CMP_Core_AVX512 PRIVATE source/core_simd_avx512.cpp)
    target_include_directories(CMP_Core_AVX512 PRIVATE source shaders)

    if (WIN32)
        target_compile_options(CMP_Core_AVX512 PRIVATE /arch:AVX512)
    else()
        target_compile_options(CMP_Core_AVX512 PRIVATE -march=skylake-avx512)
    endif()

    set_target_properties(CMP_Core_AVX512 PROPERTIES FOLDER ${PROJECT_FOLDER_SDK_LIBS})

    # Link SIMD libraries to CMP_Core
    target_link_libraries(CMP_Core PRIVATE CMP_Core_SSE CMP_Core_AVX CMP_Core_AVX512)
endif()

# ------------------------------------------------------------------------
# Optional: route the CPU BC7 encoder through richgel999/bc7enc_rdo's
# bc7e.ispc SIMD encoder. Additive — stock BC7BlockEncoder stays in place
# and is selected when this option is OFF.
# ------------------------------------------------------------------------
option(OPTION_CMP_USE_BC7ENC_RDO "Route CPU BC7 encode through bc7enc_rdo (bc7e.ispc)" OFF)

if (OPTION_CMP_USE_BC7ENC_RDO)
    set(BC7ENC_RDO_DIR "${CMAKE_SOURCE_DIR}/../bc7enc_rdo" CACHE PATH
        "Path to richgel999/bc7enc_rdo checkout")
    set(BC7ENC_RDO_ISPC "${CMAKE_SOURCE_DIR}/../tools/ispc/linux/bin/ispc" CACHE FILEPATH
        "Path to the ispc compiler binary")

    # ISPC code-generation target selection. The defaults reproduce the
    # verified Linux/Windows x86-64 build exactly. macOS needs them
    # configurable for two reasons: an arm64 host defaults ispc to aarch64
    # (so an x86-64 slice must ask for --arch=x86-64), and an arm64 slice
    # needs the NEON target instead of the four SSE/AVX ones.
    set(BC7ENC_RDO_ISPC_ARCH "" CACHE STRING
        "ispc --arch value; empty uses the ispc host default")
    set(BC7ENC_RDO_ISPC_TARGETS "sse2,sse4,avx,avx2" CACHE STRING
        "ispc --target list (comma-separated)")

    if (NOT EXISTS "${BC7ENC_RDO_DIR}/bc7e.ispc")
        message(FATAL_ERROR "OPTION_CMP_USE_BC7ENC_RDO=ON but ${BC7ENC_RDO_DIR}/bc7e.ispc not found. Set BC7ENC_RDO_DIR to the bc7enc_rdo checkout.")
    endif()
    if (NOT EXISTS "${BC7ENC_RDO_ISPC}")
        message(FATAL_ERROR "OPTION_CMP_USE_BC7ENC_RDO=ON but ispc binary not found at ${BC7ENC_RDO_ISPC}. Set BC7ENC_RDO_ISPC.")
    endif()

    set(BC7E_OBJ_DIR "${CMAKE_CURRENT_BINARY_DIR}/bc7e_ispc")
    file(MAKE_DIRECTORY "${BC7E_OBJ_DIR}")

    # ispc emits one object per target plus a dispatch object, but only when
    # more than one target is requested. A single-target build (e.g. NEON)
    # emits bc7e.o alone, so listing per-target objects there would declare
    # outputs the compiler never writes.
    string(REPLACE "," ";" BC7E_TARGET_LIST "${BC7ENC_RDO_ISPC_TARGETS}")
    set(BC7E_OBJS "${BC7E_OBJ_DIR}/bc7e.o")
    list(LENGTH BC7E_TARGET_LIST BC7E_TARGET_COUNT)
    if (BC7E_TARGET_COUNT GREATER 1)
        foreach(BC7E_TARGET IN LISTS BC7E_TARGET_LIST)
            string(REPLACE "-" "_" BC7E_TARGET_SUFFIX "${BC7E_TARGET}")
            list(APPEND BC7E_OBJS "${BC7E_OBJ_DIR}/bc7e_${BC7E_TARGET_SUFFIX}.o")
        endforeach()
    endif()
    set(BC7E_HEADER "${BC7E_OBJ_DIR}/bc7e_ispc.h")

    set(BC7E_ISPC_ARCH_ARG "")
    if (BC7ENC_RDO_ISPC_ARCH)
        set(BC7E_ISPC_ARCH_ARG "--arch=${BC7ENC_RDO_ISPC_ARCH}")
    endif()

    add_custom_command(
        OUTPUT ${BC7E_OBJS} ${BC7E_HEADER}
        COMMAND ${BC7ENC_RDO_ISPC} --pic -g -O2
                "${BC7ENC_RDO_DIR}/bc7e.ispc"
                -o "${BC7E_OBJ_DIR}/bc7e.o"
                -h "${BC7E_HEADER}"
                ${BC7E_ISPC_ARCH_ARG}
                --target=${BC7ENC_RDO_ISPC_TARGETS}
                --opt=fast-math --opt=disable-assertions
        DEPENDS "${BC7ENC_RDO_DIR}/bc7e.ispc"
        COMMENT "Generating bc7e.ispc objects for CMP_Core (${BC7ENC_RDO_ISPC_TARGETS})"
        VERBATIM
    )

    add_custom_target(cmp_core_bc7e_ispc DEPENDS ${BC7E_OBJS} ${BC7E_HEADER})
    add_dependencies(CMP_Core cmp_core_bc7e_ispc)

    target_sources(CMP_Core PRIVATE
        source/bc7enc_rdo_adapter.h
        source/bc7enc_rdo_adapter.cpp
        ${BC7E_OBJS}
    )
    set_source_files_properties(${BC7E_OBJS} PROPERTIES
        EXTERNAL_OBJECT TRUE
        GENERATED TRUE
    )
    target_include_directories(CMP_Core PRIVATE "${BC7E_OBJ_DIR}")
    target_compile_definitions(CMP_Core PUBLIC CMP_USE_BC7ENC_RDO=1)

    # Optional producer-side batching (Phase 3 part 5). Groups blocks into
    # BATCH_N=64 chunks before calling into bc7e_compress_blocks, amortizing
    # per-call setup and packing SIMD lanes. Requires OPTION_CMP_USE_BC7ENC_RDO
    # to be on. Kept as a separate toggle so the per-block bc7e path remains
    # reachable for correctness A/B verification.
    option(OPTION_CMP_USE_BC7ENC_RDO_BATCH "Producer-side block batching for bc7e (requires OPTION_CMP_USE_BC7ENC_RDO)" OFF)
    if (OPTION_CMP_USE_BC7ENC_RDO_BATCH)
        target_compile_definitions(CMP_Core PUBLIC CMP_USE_BC7ENC_RDO_BATCH=1)
    endif()
endif()