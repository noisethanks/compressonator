//===============================================================================
// Copyright (c) 2014-2024  Advanced Micro Devices, Inc. All rights reserved.
//===============================================================================
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//  File Name:   Codec_BC7.cpp
//  Description: implementation of the CCodec_BC7 class
//
//////////////////////////////////////////////////////////////////////////////

#ifndef _CODEC_BC7_H_INCLUDED_
#define _CODEC_BC7_H_INCLUDED_

#include <atomic>
#include <thread>

#include "bc7_encode.h"
#include "bc7_decode.h"
#include "bc7_library.h"
#include "codec_common.h"
#include "codec_dxtc.h"
#include "compressonator.h"

#if defined(CMP_USE_BC7ENC_RDO_BATCH)
#include "bc7enc_rdo_adapter.h"
#endif

// #define USE_THREADED_CALLBACKS  // This is experimental code to improve compression performance!
#ifdef USE_THREADED_CALLBACKS
typedef struct
{
    float progress;
    bool  abort;
} CMP_PROGRESS_THREAD;
#endif

struct BC7EncodeThreadParam
{
    BC7BlockEncoder*  encoder;
    double            in[MAX_SUBSET_SIZE][MAX_DIMENSION_BIG];
    CMP_BYTE*         out;
    // Handoff flags between the producer and this worker. They must be
    // atomic, not volatile: volatile orders nothing between threads, so on a
    // weakly ordered CPU (arm64) the producer can observe run == false before
    // the worker's writes to *out are visible, then reuse the slot and
    // overwrite in/batch_in while the worker is still reading it. That races
    // per block and corrupts output — measured as 10 different results from
    // 10 identical runs on Apple Silicon. x86-64's store ordering hides the
    // bug, which is why it went unnoticed. Release on store, acquire on load,
    // pairs the slot handoff in both directions.
    std::atomic<bool> run;
    std::atomic<bool> exit;
#if defined(CMP_USE_BC7ENC_RDO_BATCH)
    // Batched-mode fields. When batch_count > 0, worker dispatches to
    // bc7e batch entry point using batch_in/batch_count/bctx and writes
    // batch_count*16 bytes at out. When batch_count == 0, worker takes
    // the per-block path (encoder->CompressBlock(in, out)) — preserving
    // per-block hook fallback if the batched producer ever hands a
    // per-block payload.
    double                    batch_in[CMP_BC7ENC_BATCH_N][16][4];
    unsigned int              batch_count;
    CMP_bc7enc_BatchContext*  bctx;
#endif
};

class CCodec_BC7 : public CCodec_DXTC
{
public:
    CCodec_BC7();
    ~CCodec_BC7();

    virtual bool SetParameter(const CMP_CHAR* pszParamName, CMP_CHAR* sValue);
    virtual bool SetParameter(const CMP_CHAR* /*pszParamName*/, CMP_DWORD /*dwValue*/);
    virtual bool SetParameter(const CMP_CHAR* /*pszParamName*/, CODECFLOAT /*fValue*/);

    // Required interfaces
    virtual CodecError Compress(CCodecBuffer&       bufferIn,
                                CCodecBuffer&       bufferOut,
                                Codec_Feedback_Proc pFeedbackProc = NULL,
                                CMP_DWORD_PTR       pUser1        = NULL,
                                CMP_DWORD_PTR       pUser2        = NULL);
    virtual CodecError Compress_Fast(CCodecBuffer&       bufferIn,
                                     CCodecBuffer&       bufferOut,
                                     Codec_Feedback_Proc pFeedbackProc = NULL,
                                     CMP_DWORD_PTR       pUser1        = NULL,
                                     CMP_DWORD_PTR       pUser2        = NULL);
    virtual CodecError Compress_SuperFast(CCodecBuffer&       bufferIn,
                                          CCodecBuffer&       bufferOut,
                                          Codec_Feedback_Proc pFeedbackProc = NULL,
                                          CMP_DWORD_PTR       pUser1        = NULL,
                                          CMP_DWORD_PTR       pUser2        = NULL);
    virtual CodecError Decompress(CCodecBuffer&       bufferIn,
                                  CCodecBuffer&       bufferOut,
                                  Codec_Feedback_Proc pFeedbackProc = NULL,
                                  CMP_DWORD_PTR       pUser1        = NULL,
                                  CMP_DWORD_PTR       pUser2        = NULL);

private:
    BC7EncodeThreadParam* m_EncodeParameterStorage;

    // BC7 User configurable variables
    CMP_DWORD m_ModeMask;
    double    m_Quality;
    double    m_Performance;
    CMP_BOOL  m_ColourRestrict;
    CMP_BOOL  m_AlphaRestrict;
    CMP_WORD  m_NumThreads;
    CMP_BOOL  m_ImageNeedsAlpha;

    // BC7 Internal status
    CMP_BOOL m_LibraryInitialized;
    CMP_BOOL m_Use_MultiThreading;
    CMP_INT  m_NumEncodingThreads;
    CMP_WORD m_LiveThreads;
    CMP_WORD m_LastThread;

    // BC7 Encoders and decoders: for encding use the interfaces below
    std::thread*     m_EncodingThreadHandle;
    BC7BlockEncoder* m_encoder[MAX_BC7_THREADS];
    BC7BlockDecoder* m_decoder;

#if defined(CMP_USE_BC7ENC_RDO_BATCH)
    // Per-worker bc7e batch contexts, built at InitializeBC7Library from
    // the (already-set) codec options. One per worker so workers run
    // batch flushes concurrently without shared state.
    CMP_bc7enc_BatchContext* m_bctx[MAX_BC7_THREADS];
#endif

    // Encoder interfaces
    CodecError InitializeBC7Library();
    CodecError EncodeBC7Block(double in[BC7_BLOCK_PIXELS][MAX_DIMENSION_BIG], CMP_BYTE* out);
#if defined(CMP_USE_BC7ENC_RDO_BATCH)
    // Reserves an idle worker slot, returns its index. Blocks until one
    // frees. Used by the batched producer to fill batch_in directly into
    // the worker's storage (no producer-side memcpy).
    int  AcquireIdleWorker();
    // Kicks the reserved worker with a batch of `count` blocks whose
    // pixel data is already in m_EncodeParameterStorage[slot].batch_in.
    void DispatchBatch(int slot, unsigned int count, CMP_BYTE* out);
#endif
    CodecError FinishBC7Encoding(void);

    static void Run();

#ifdef USE_THREADED_CALLBACKS
public:
    static CMP_PROGRESS_THREAD m_progress;
    static Codec_Feedback_Proc m_user_pFeedbackProc;
    static CMP_DWORD_PTR       m_pUser1;
    static CMP_DWORD_PTR       m_pUser2;
#endif
};

#endif  // !defined(_CODEC_DXT5_H_INCLUDED_)
