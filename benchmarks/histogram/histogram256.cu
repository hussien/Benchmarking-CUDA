/*
 * Copyright 1993-2010 NVIDIA Corporation.  All rights reserved.
 *
 * NVIDIA Corporation and its licensors retain all intellectual property and
 * proprietary rights in and to this software and related documentation.
 * Any use, reproduction, disclosure, or distribution of this software
 * and related documentation without an express license agreement from
 * NVIDIA Corporation is strictly prohibited.
 *
 * Please refer to the applicable NVIDIA end user license agreement (EULA)
 * associated with this source code for terms and conditions that govern
 * your use of this NVIDIA software.
 *
 */
#include <prof.cu>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cutil_inline.h>
#include "histogram_common.h"

////////////////////////////////////////////////////////////////////////////////
// Shortcut shared memory atomic addition functions
////////////////////////////////////////////////////////////////////////////////
#define USE_SMEM_ATOMICS 0

#if(!USE_SMEM_ATOMICS)
    #define TAG_MASK ( (1U << (UINT_BITS - LOG2_WARP_SIZE)) - 1U )

    inline __device__ void addByte(volatile uint *s_WarpHist, uint data, uint threadTag){
        uint count;
        do{
            count = s_WarpHist[data] & TAG_MASK;
            count = threadTag | (count + 1);
            s_WarpHist[data] = count;
        }while(s_WarpHist[data] != count);
    }
#else
    #ifdef CUDA_NO_SM12_ATOMIC_INTRINSICS
        #error Compilation target does not support shared-memory atomics
    #endif

    #define TAG_MASK 0xFFFFFFFFU
    inline __device__ void addByte(uint *s_WarpHist, uint data, uint threadTag){
        atomicAdd(s_WarpHist + data, 1);
    }
#endif

inline __device__ void addWord(uint *s_WarpHist, uint data, uint tag){
    addByte(s_WarpHist, (data >>  0) & 0xFFU, tag);
    addByte(s_WarpHist, (data >>  8) & 0xFFU, tag);
    addByte(s_WarpHist, (data >> 16) & 0xFFU, tag);
    addByte(s_WarpHist, (data >> 24) & 0xFFU, tag);
}

__global__ void histogram256Kernel(uint *d_PartialHistograms, uint *d_Data, uint dataCount){
    //Per-warp subhistogram storage
    __shared__ uint s_Hist[HISTOGRAM256_THREADBLOCK_MEMORY];
    uint *s_WarpHist= s_Hist + (threadIdx.x >> LOG2_WARP_SIZE) * HISTOGRAM256_BIN_COUNT;

    //Clear shared memory storage for current threadblock before processing
    #pragma unroll
    for(uint i = 0; i < (HISTOGRAM256_THREADBLOCK_MEMORY / HISTOGRAM256_THREADBLOCK_SIZE); i++)
       s_Hist[threadIdx.x + i * HISTOGRAM256_THREADBLOCK_SIZE] = 0;

    //Cycle through the entire data set, update subhistograms for each warp
    #ifndef __DEVICE_EMULATION__
        const uint tag = threadIdx.x << (UINT_BITS - LOG2_WARP_SIZE);
    #else
        const uint tag = 0;
    #endif

    __syncthreads();
    for(uint pos = UMAD(blockIdx.x, blockDim.x, threadIdx.x); pos < dataCount; pos += UMUL(blockDim.x, gridDim.x)){
        uint data = d_Data[pos];
        addWord(s_WarpHist, data, tag);
    }

    //Merge per-warp histograms into per-block and write to global memory
    __syncthreads();
    for(uint bin = threadIdx.x; bin < HISTOGRAM256_BIN_COUNT; bin += HISTOGRAM256_THREADBLOCK_SIZE){
        uint sum = 0;

        for(uint i = 0; i < WARP_COUNT; i++)
            sum += s_Hist[bin + i * HISTOGRAM256_BIN_COUNT] & TAG_MASK;

        d_PartialHistograms[blockIdx.x * HISTOGRAM256_BIN_COUNT + bin] = sum;
    }
}

////////////////////////////////////////////////////////////////////////////////
// Merge histogram256() output
// Run one threadblock per bin; each threadblock adds up the same bin counter
// from every partial histogram. Reads are uncoalesced, but mergeHistogram256
// takes only a fraction of total processing time
////////////////////////////////////////////////////////////////////////////////
#define MERGE_THREADBLOCK_SIZE 256

__global__ void mergeHistogram256Kernel(
    uint *d_Histogram,
    uint *d_PartialHistograms,
    uint histogramCount
){
    uint sum = 0;
    for(uint i = threadIdx.x; i < histogramCount; i += MERGE_THREADBLOCK_SIZE)
        sum += d_PartialHistograms[blockIdx.x + i * HISTOGRAM256_BIN_COUNT];

    __shared__ uint data[MERGE_THREADBLOCK_SIZE];
    data[threadIdx.x] = sum;

    for(uint stride = MERGE_THREADBLOCK_SIZE / 2; stride > 0; stride >>= 1){
        __syncthreads();
        if(threadIdx.x < stride)
            data[threadIdx.x] += data[threadIdx.x + stride];
    }

    if(threadIdx.x == 0)
        d_Histogram[blockIdx.x] = data[0];
}

////////////////////////////////////////////////////////////////////////////////
// Host interface to GPU histogram
////////////////////////////////////////////////////////////////////////////////
//histogram256kernel() intermediate results buffer
static const uint PARTIAL_HISTOGRAM256_COUNT = 240;
static uint *d_PartialHistograms;

//Internal memory allocation
extern "C" void initHistogram256(void){
    cutilSafeCall( cudaMalloc((void **)&d_PartialHistograms, PARTIAL_HISTOGRAM256_COUNT * HISTOGRAM256_BIN_COUNT * sizeof(uint)) );
}

//Internal memory deallocation
extern "C" void closeHistogram256(void){
    cutilSafeCall( cudaFree(d_PartialHistograms) );
}

extern "C" void histogram256(
    uint *d_Histogram,
    void *d_Data,
    uint byteCount
){
    assert( byteCount % sizeof(uint) == 0 );
	GpuProfiling::prepareProfiling( PARTIAL_HISTOGRAM256_COUNT, HISTOGRAM256_THREADBLOCK_SIZE );
    histogram256Kernel<<<PARTIAL_HISTOGRAM256_COUNT, HISTOGRAM256_THREADBLOCK_SIZE>>>(
        d_PartialHistograms,
        (uint *)d_Data,
        byteCount / sizeof(uint)
    );
	GpuProfiling::addResults("histogram256Kernel");
    cutilCheckMsg("histogram256Kernel() execution failed\n");

	GpuProfiling::prepareProfiling( HISTOGRAM256_BIN_COUNT, MERGE_THREADBLOCK_SIZE );
    mergeHistogram256Kernel<<<HISTOGRAM256_BIN_COUNT, MERGE_THREADBLOCK_SIZE>>>(
        d_Histogram,
        d_PartialHistograms,
        PARTIAL_HISTOGRAM256_COUNT
    );
	GpuProfiling::addResults("mergeHistogram256Kernel");
    cutilCheckMsg("mergeHistogram256Kernel() execution failed\n");
}
