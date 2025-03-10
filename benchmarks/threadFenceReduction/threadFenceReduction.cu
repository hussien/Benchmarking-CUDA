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

/*
    Parallel reduction

    This sample shows how to perform a reduction operation on an array of values
    to produce a single value in a single kernel (as opposed to two or more
    kernel calls as shown in the "reduction" SDK sample).  Single-pass
    reduction requires global atomic instructions (Compute Capability 1.1 or
    later) and the __threadfence() intrinsic (CUDA 2.2 or later).

    Reductions are a very common computation in parallel algorithms.  Any time
    an array of values needs to be reduced to a single value using a binary
    associative operator, a reduction can be used.  Example applications include
    statistics computations such as mean and standard deviation, and image
    processing applications such as finding the total luminance of an
    image.

    This code performs sum reductions, but any associative operator such as
    min() or max() could also be used.

    It assumes the input size is a power of 2.

    COMMAND LINE ARGUMENTS

    "--shmoo":         Test performance for 1 to 32M elements with each of the 7 different kernels
    "--n=<N>":         Specify the number of elements to reduce (default 1048576)
    "--threads=<N>":   Specify the number of threads per block (default 128)
    "--maxblocks=<N>": Specify the maximum number of thread blocks to launch (kernel 6 only, default 64)
    "--cpufinal":      Read back the per-block results and do final sum of block sums on CPU (default false)
    "--cputhresh=<N>": The threshold of number of blocks sums below which to perform a CPU final reduction (default 1)
    "--multipass":     Use a multipass reduction instead of a single-pass reduction

*/
#include <prof.cu>
// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

// includes, project
#include <cutil_inline.h>

#define VERSION_MAJOR (CUDART_VERSION/1000)
#define VERSION_MINOR (CUDART_VERSION%100)/10

const char *sSDKsample = "threadFenceReduction";

#pragma comment(user, "CUDA NVCC Version " VERSION_MAJOR "." VERSION_MINOR)

#if CUDART_VERSION >= 2020
    #include "threadFenceReduction_kernel.cu"
#else
    #pragma comment(user, "CUDA 2.2 is required to build for threadFenceReduction")
#endif

////////////////////////////////////////////////////////////////////////////////
// declaration, forward
void runTest( int argc, char** argv);

extern "C"
{
    void reduce(int size, int threads, int blocks, float *d_idata, float *d_odata);
    void reduceSinglePass(int size, int threads, int blocks, float *d_idata, float *d_odata);
}

#if CUDART_VERSION < 2020
    void reduce(int size, int threads, int blocks, float *d_idata, float *d_odata)
    {
        printf("reduce(), compiler not supported, aborting tests\n");
    }

    void reduceSinglePass(int size, int threads, int blocks, float *d_idata, float *d_odata)
    {
        printf("reduceSinglePass(), compiler not supported, aborting tests\n");
    }
#endif

#ifdef WIN32
#define strcasecmp strcmpi
#endif




////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int
main( int argc, char** argv)
{
	GpuProfiling::initProf();
    cudaDeviceProp deviceProp;
    deviceProp.major = 0;
    deviceProp.minor = 0;
    int minimumComputeVersion = 11;
    int dev;

    printf("[ %s ]\n", sSDKsample);

    if( cutCheckCmdLineFlag(argc, (const char**)argv, "device") )
    {
        cutilDeviceInit(argc, argv);
        cutilSafeCallNoSync(cudaGetDevice(&dev));
    }
    else
    {
        cutilSafeCallNoSync(cudaChooseDevice(&dev, &deviceProp));

    }

    cutilSafeCallNoSync(cudaGetDeviceProperties(&deviceProp, dev));

    if((deviceProp.major * 10 + deviceProp.minor) >= minimumComputeVersion)
    {
        printf("Using Device %d: %s\n\n", dev, deviceProp.name);
        cutilSafeCallNoSync(cudaSetDevice(dev));
    }
    else
    {
        printf("The selected device does not support compute capability %d.%d, aborting\n\n",
            minimumComputeVersion / 10, minimumComputeVersion % 10);
        printf("PASSED\n");
        cudaThreadExit();
exit(0);
        cutilExit(argc, argv);
    }


#if CUDART_VERSION >= 2020
    runTest( argc, argv);
#else
    print_NVCC_min_spec(sSDKsample, "2.2", "Version 185");
    printf("  FAILED\n");
#endif

    cudaThreadExit();
exit(0);
    cutilExit(argc, argv);
}

////////////////////////////////////////////////////////////////////////////////
//! Compute sum reduction on CPU
//! We use Kahan summation for an accurate sum of large arrays.
//! http://en.wikipedia.org/wiki/Kahan_summation_algorithm
//!
//! @param data       pointer to input data
//! @param size       number of input data elements
////////////////////////////////////////////////////////////////////////////////
template<class T>
T reduceCPU(T *data, int size)
{
    T sum = data[0];
    T c = (T)0.0;
    for (int i = 1; i < size; i++)
    {
        T y = data[i] - c;
        T t = sum + y;
        c = (t - sum) - y;
        sum = t;
    }
    return sum;
}

unsigned int nextPow2( unsigned int x ) {
    --x;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return ++x;
}


////////////////////////////////////////////////////////////////////////////////
// Compute the number of threads and blocks to use for the reduction
// We set threads / block to the minimum of maxThreads and n/2.
////////////////////////////////////////////////////////////////////////////////
void getNumBlocksAndThreads(int n, int maxBlocks, int maxThreads, int &blocks, int &threads)
{
    if (n == 1)
    {
        threads = 1;
        blocks = 1;
    }
    else
    {
        threads = (n < maxThreads*2) ? nextPow2(n / 2) : maxThreads;
        blocks = max(1, n / (threads * 2));
    }

    blocks = min(maxBlocks, blocks);
}

////////////////////////////////////////////////////////////////////////////////
// This function performs a reduction of the input data multiple times and
// measures the average reduction time.
////////////////////////////////////////////////////////////////////////////////
float benchmarkReduce(int  n,
                      int  numThreads,
                      int  numBlocks,
                      int  maxThreads,
                      int  maxBlocks,
                      int  testIterations,
                      bool multiPass,
                      bool cpuFinalReduction,
                      int  cpuFinalThreshold,
                      unsigned int timer,
                      float* h_odata,
                      float* d_idata,
                      float* d_odata)
{
    float gpu_result = 0;
    bool needReadBack = true;

    for (int i = 0; i < testIterations; ++i)
    {
        gpu_result = 0;
        unsigned int retCnt = 0;
        cudaMemcpyToSymbol("retirementCount", &retCnt, sizeof(unsigned int), 0, cudaMemcpyHostToDevice);
        cutilCheckMsg("MemcpyToSymbol failed");

        cudaThreadSynchronize();
        cutilCheckError( cutStartTimer( timer));

        if (multiPass)
        {
            // execute the kernel
            reduce(n, numThreads, numBlocks, d_idata, d_odata);

            // check if kernel execution generated an error
            cutilCheckMsg("Kernel execution failed");

            if (cpuFinalReduction)
            {
                // sum partial sums from each block on CPU
                // copy result from device to host
                cutilSafeCallNoSync( cudaMemcpy( h_odata, d_odata, numBlocks*sizeof(float), cudaMemcpyDeviceToHost) );

                for(int i=0; i<numBlocks; i++)
                {
                    gpu_result += h_odata[i];
                }

                needReadBack = false;
            }
            else
            {
                // sum partial block sums on GPU
                int s=numBlocks;
                while(s > cpuFinalThreshold)
                {
                    int threads = 0, blocks = 0;
                    getNumBlocksAndThreads(s, maxBlocks, maxThreads, blocks, threads);

                    reduce(s, threads, blocks, d_odata, d_odata);

                    s = s / (threads*2);
                }

                if (s > 1)
                {
                    // copy result from device to host
                    cutilSafeCallNoSync( cudaMemcpy( h_odata, d_odata, s * sizeof(float), cudaMemcpyDeviceToHost) );

                    for(int i=0; i < s; i++)
                    {
                        gpu_result += h_odata[i];
                    }

                    needReadBack = false;
                }
            }
        }
        else
        {
            cutilCheckMsg("Kernel execution failed");

            // execute the kernel
            reduceSinglePass(n, numThreads, numBlocks, d_idata, d_odata);

            // check if kernel execution generated an error
            cutilCheckMsg("Kernel execution failed");
        }

        cudaThreadSynchronize();
        cutilCheckError( cutStopTimer(timer) );
    }

    if (needReadBack)
    {
        // copy final sum from device to host
        cutilSafeCallNoSync( cudaMemcpy( &gpu_result, d_odata, sizeof(float), cudaMemcpyDeviceToHost) );
    }

    return gpu_result;
}

////////////////////////////////////////////////////////////////////////////////
// This function calls benchmarkReduce multiple times for a range of array sizes
// and prints a report in CSV (comma-separated value) format that can be used for
// generating a "shmoo" plot showing the performance for each kernel variation
// over a wide range of input sizes.
////////////////////////////////////////////////////////////////////////////////
void shmoo(int minN, int maxN, int maxThreads, int maxBlocks)
{
    // create random input data on CPU
    unsigned int bytes = maxN * sizeof(float);

    float *h_idata = (float*) malloc(bytes);

    for(int i = 0; i < maxN; i++) {
        // Keep the numbers small so we don't get truncation error in the sum
        h_idata[i] = (rand() & 0xFF) / (float)RAND_MAX;
    }

    int maxNumBlocks = min(65535, maxN / maxThreads);

    // allocate mem for the result on host side
    float* h_odata = (float*) malloc(maxNumBlocks*sizeof(float));

    // allocate device memory and data
    float* d_idata = NULL;
    float* d_odata = NULL;

    cutilSafeCallNoSync( cudaMalloc((void**) &d_idata, bytes) );
    cutilSafeCallNoSync( cudaMalloc((void**) &d_odata, maxNumBlocks*sizeof(float)) );

    // copy data directly to device memory
    cutilSafeCallNoSync( cudaMemcpy(d_idata, h_idata, bytes, cudaMemcpyHostToDevice) );
    cutilSafeCallNoSync( cudaMemcpy(d_odata, h_idata, maxNumBlocks*sizeof(float), cudaMemcpyHostToDevice) );


#ifndef __DEVICE_EMULATION__
    // warm-up
    reduce(maxN, maxThreads, maxNumBlocks, d_idata, d_odata);
    int testIterations = 100;
#else
    int testIterations = 1;
#endif

    unsigned int timer = 0;
    cutilCheckError( cutCreateTimer( &timer));

    // print headers
    printf("N, %d blocks one pass, %d blocks multipass\n", maxBlocks, maxBlocks);
    for (int i = minN; i <= maxN; i *= 2)
    {
        printf("%d, ", i);
        for (int multiPass = 0; multiPass <= 1; multiPass++)
        {
            cutResetTimer(timer);
            int numBlocks = 0;
            int numThreads = 0;
            getNumBlocksAndThreads(i, maxBlocks, maxThreads, numBlocks, numThreads);


            benchmarkReduce(i, numThreads, numBlocks, maxThreads, maxBlocks,
                            testIterations, multiPass==1, false, 1, timer, h_odata, d_idata, d_odata);

            float reduceTime = cutGetAverageTimerValue(timer);
            printf("%f%s", reduceTime, multiPass==0 ? ", " : "\n");
        }
    }
    printf("\n");

    // cleanup
    cutilCheckError(cutDeleteTimer(timer));
    free(h_idata);
    free(h_odata);

    cutilSafeCallNoSync(cudaFree(d_idata));
    cutilSafeCallNoSync(cudaFree(d_odata));
}

////////////////////////////////////////////////////////////////////////////////
// The main function which runs the reduction test.
////////////////////////////////////////////////////////////////////////////////
void
runTest( int argc, char** argv)
{
    int size = 1<<20;    // number of elements to reduce
    int maxThreads = 128;  // number of threads per block
    int maxBlocks = 64;
    bool cpuFinalReduction = false;
    int cpuFinalThreshold = 1;
    bool multipass = false;

    cutGetCmdLineArgumenti( argc, (const char**) argv, "n", &size);
    cutGetCmdLineArgumenti( argc, (const char**) argv, "threads", &maxThreads);
    cutGetCmdLineArgumenti( argc, (const char**) argv, "maxblocks", &maxBlocks);

    printf("%d elements\n", size);
    printf("%d threads (max)\n", maxThreads);

    cpuFinalReduction = (cutCheckCmdLineFlag( argc, (const char**) argv, "cpufinal") == CUTTrue);
    multipass = (cutCheckCmdLineFlag( argc, (const char**) argv, "multipass") == CUTTrue);

    cutGetCmdLineArgumenti( argc, (const char**) argv, "cputhresh", &cpuFinalThreshold);

    bool runShmoo = (cutCheckCmdLineFlag(argc, (const char**) argv, "shmoo") == CUTTrue);

    if (runShmoo)
    {
        shmoo(1, 33554432, maxThreads, maxBlocks);
    }
    else
    {

        // create random input data on CPU
        unsigned int bytes = size * sizeof(float);

        float *h_idata = (float *) malloc(bytes);

        for(int i=0; i<size; i++)
        {
            // Keep the numbers small so we don't get truncation error in the sum
            h_idata[i] = (rand() & 0xFF) / (float)RAND_MAX;
        }

        int numBlocks = 0;
        int numThreads = 0;
        getNumBlocksAndThreads(size, maxBlocks, maxThreads, numBlocks, numThreads);
        if (numBlocks == 1) cpuFinalThreshold = 1;

        // allocate mem for the result on host side
        float* h_odata = (float*) malloc(numBlocks*sizeof(float));

        printf("%d blocks\n", numBlocks);

        // allocate device memory and data
        float* d_idata = NULL;
        float* d_odata = NULL;

        cutilSafeCallNoSync( cudaMalloc((void**) &d_idata, bytes) );
        cutilSafeCallNoSync( cudaMalloc((void**) &d_odata, numBlocks*sizeof(float)) );

        // copy data directly to device memory
        cutilSafeCallNoSync( cudaMemcpy(d_idata, h_idata, bytes, cudaMemcpyHostToDevice) );
        cutilSafeCallNoSync( cudaMemcpy(d_odata, h_idata, numBlocks*sizeof(float), cudaMemcpyHostToDevice) );

    #ifndef __DEVICE_EMULATION__
        // warm-up
        reduce(size, numThreads, numBlocks, d_idata, d_odata);
        int testIterations = 100;
    #else
        int testIterations = 1;
    #endif

        unsigned int timer = 0;
        cutilCheckError( cutCreateTimer( &timer));

        float gpu_result = 0;

        gpu_result = benchmarkReduce(size, numThreads, numBlocks, maxThreads, maxBlocks,
                                     testIterations, multipass, cpuFinalReduction,
                                     cpuFinalThreshold, timer, h_odata, d_idata, d_odata);

        float reduceTime = cutGetAverageTimerValue(timer);
        printf("Average time: %f ms\n", reduceTime);
        printf("Bandwidth:    %f GB/s\n\n", (size * sizeof(int)) / (reduceTime * 1.0e6));

        // compute reference solution
        float cpu_result = reduceCPU<float>(h_idata, size);

        printf("GPU result = %0.12f\n", gpu_result);
        printf("CPU result = %0.12f\n", cpu_result);

        double threshold = 1e-8 * size;
        double diff = abs((double)gpu_result - (double)cpu_result);
        printf("%s\n", (diff < threshold) ? "PASSED" : "FAILED");
		GpuProfiling::printResults();

        // cleanup
        cutilCheckError( cutDeleteTimer(timer) );
        free(h_idata);
        free(h_odata);

        cutilSafeCallNoSync(cudaFree(d_idata));
        cutilSafeCallNoSync(cudaFree(d_odata));
    }
}
