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
    Parallel reduction kernels
*/

#ifndef _REDUCE_KERNEL_H_
#define _REDUCE_KERNEL_H_
#include <prof.cu>
#include <stdio.h>
#include <typeinfo>
#include <string>

using std::string;
#ifdef __DEVICE_EMULATION__
#define EMUSYNC __syncthreads()
#else
#define EMUSYNC
#endif


string convertInt(int number)
{
	if (number == 0)
		return "0";
	string temp="";
	string returnvalue="";
	while (number>0)
	{
		temp+=number%10+48;
		number/=10;
	}
	for (int i=0;i<temp.length();i++)
		returnvalue+=temp[temp.length()-i-1];
	return returnvalue;
}
// Utility class used to avoid linker errors with extern
// unsized shared memory arrays with templated type
template<class T>
struct SharedMemory
{
    __device__ inline operator       T*()
    {
        extern __shared__ int __smem[];
        return (T*)__smem;
    }

    __device__ inline operator const T*() const
    {
        extern __shared__ int __smem[];
        return (T*)__smem;
    }
};

// specialize for double to avoid unaligned memory
// access compile errors
template<>
struct SharedMemory<double>
{
    __device__ inline operator       double*()
    {
        extern __shared__ double __smem_d[];
        return (double*)__smem_d;
    }

    __device__ inline operator const double*() const
    {
        extern __shared__ double __smem_d[];
        return (double*)__smem_d;
    }
};

/*
    Parallel sum reduction using shared memory
    - takes log(n) steps for n input elements
    - uses n threads
    - only works for power-of-2 arrays
*/

/* This reduction interleaves which threads are active by using the modulo
   operator.  This operator is very expensive on GPUs, and the interleaved
   inactivity means that no whole warps are active, which is also very
   inefficient */
template <class T>
__global__ void
reduce0(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // load shared mem
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*blockDim.x + threadIdx.x;

    sdata[tid] = (i < n) ? g_idata[i] : 0;

    __syncthreads();

    // do reduction in shared mem
    for(unsigned int s=1; s < blockDim.x; s *= 2) {
        // modulo arithmetic is slow!
        if ((tid % (2*s)) == 0) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

/* This version uses contiguous threads, but its interleaved
   addressing results in many shared memory bank conflicts.
*/
template <class T>
__global__ void
reduce1(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // load shared mem
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*blockDim.x + threadIdx.x;

    sdata[tid] = (i < n) ? g_idata[i] : 0;

    __syncthreads();

    // do reduction in shared mem
    for(unsigned int s=1; s < blockDim.x; s *= 2)
    {
        int index = 2 * s * tid;

        if (index < blockDim.x)
        {
            sdata[index] += sdata[index + s];
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

/*
    This version uses sequential addressing -- no divergence or bank conflicts.
*/
template <class T>
__global__ void
reduce2(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // load shared mem
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*blockDim.x + threadIdx.x;

    sdata[tid] = (i < n) ? g_idata[i] : 0;

    __syncthreads();

    // do reduction in shared mem
    for(unsigned int s=blockDim.x/2; s>0; s>>=1)
    {
        if (tid < s)
        {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

/*
    This version uses n/2 threads --
    it performs the first level of reduction when reading from global memory.
*/
template <class T>
__global__ void
reduce3(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // perform first level of reduction,
    // reading from global memory, writing to shared memory
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*(blockDim.x*2) + threadIdx.x;

    T mySum = (i < n) ? g_idata[i] : 0;
    if (i + blockDim.x < n)
        mySum += g_idata[i+blockDim.x];

    sdata[tid] = mySum;
    __syncthreads();

    // do reduction in shared mem
    for(unsigned int s=blockDim.x/2; s>0; s>>=1)
    {
        if (tid < s)
        {
            sdata[tid] = mySum = mySum + sdata[tid + s];
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

/*
    This version unrolls the last warp to avoid synchronization where it
    isn't needed.

    Note, this kernel needs a minimum of 64*sizeof(T) bytes of shared memory.
    In other words if blockSize <= 32, allocate 64*sizeof(T) bytes.
    If blockSize > 32, allocate blockSize*sizeof(T) bytes.
*/
template <class T, unsigned int blockSize>
__global__ void
reduce4(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // perform first level of reduction,
    // reading from global memory, writing to shared memory
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*(blockDim.x*2) + threadIdx.x;

    T mySum = (i < n) ? g_idata[i] : 0;
    if (i + blockSize < n)
        mySum += g_idata[i+blockSize];

    sdata[tid] = mySum;
    __syncthreads();

    // do reduction in shared mem
    for(unsigned int s=blockDim.x/2; s>32; s>>=1)
    {
        if (tid < s)
        {
            sdata[tid] = mySum = mySum + sdata[tid + s];
        }
        __syncthreads();
    }

#ifndef __DEVICE_EMULATION__
    if (tid < 32)
#endif
    {
        // now that we are using warp-synchronous programming (below)
        // we need to declare our shared memory volatile so that the compiler
        // doesn't reorder stores to it and induce incorrect behavior.
        T *smem = sdata;
        if (blockSize >=  64) { smem[tid] = mySum = mySum + smem[tid + 32]; EMUSYNC; }
        if (blockSize >=  32) { smem[tid] = mySum = mySum + smem[tid + 16]; EMUSYNC; }
        if (blockSize >=  16) { smem[tid] = mySum = mySum + smem[tid +  8]; EMUSYNC; }
        if (blockSize >=   8) { smem[tid] = mySum = mySum + smem[tid +  4]; EMUSYNC; }
        if (blockSize >=   4) { smem[tid] = mySum = mySum + smem[tid +  2]; EMUSYNC; }
        if (blockSize >=   2) { smem[tid] = mySum = mySum + smem[tid +  1]; EMUSYNC; }
    }

    // write result for this block to global mem
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

/*
    This version is completely unrolled.  It uses a template parameter to achieve
    optimal code for any (power of 2) number of threads.  This requires a switch
    statement in the host code to handle all the different thread block sizes at
    compile time.

    Note, this kernel needs a minimum of 64*sizeof(T) bytes of shared memory.
    In other words if blockSize <= 32, allocate 64*sizeof(T) bytes.
    If blockSize > 32, allocate blockSize*sizeof(T) bytes.
*/
template <class T, unsigned int blockSize>
__global__ void
reduce5(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // perform first level of reduction,
    // reading from global memory, writing to shared memory
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*(blockSize*2) + threadIdx.x;

    T mySum = (i < n) ? g_idata[i] : 0;
    if (i + blockSize < n)
        mySum += g_idata[i+blockSize];

    sdata[tid] = mySum;
    __syncthreads();

    // do reduction in shared mem
    if (blockSize >= 512) { if (tid < 256) { sdata[tid] = mySum = mySum + sdata[tid + 256]; } __syncthreads(); }
    if (blockSize >= 256) { if (tid < 128) { sdata[tid] = mySum = mySum + sdata[tid + 128]; } __syncthreads(); }
    if (blockSize >= 128) { if (tid <  64) { sdata[tid] = mySum = mySum + sdata[tid +  64]; } __syncthreads(); }

#ifndef __DEVICE_EMULATION__
    if (tid < 32)
#endif
    {
        // now that we are using warp-synchronous programming (below)
        // we need to declare our shared memory volatile so that the compiler
        // doesn't reorder stores to it and induce incorrect behavior.
        volatile T* smem = sdata;
        if (blockSize >=  64) { smem[tid] = mySum = mySum + smem[tid + 32]; EMUSYNC; }
        if (blockSize >=  32) { smem[tid] = mySum = mySum + smem[tid + 16]; EMUSYNC; }
        if (blockSize >=  16) { smem[tid] = mySum = mySum + smem[tid +  8]; EMUSYNC; }
        if (blockSize >=   8) { smem[tid] = mySum = mySum + smem[tid +  4]; EMUSYNC; }
        if (blockSize >=   4) { smem[tid] = mySum = mySum + smem[tid +  2]; EMUSYNC; }
        if (blockSize >=   2) { smem[tid] = mySum = mySum + smem[tid +  1]; EMUSYNC; }
    }

    // write result for this block to global mem
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

/*
    This version adds multiple elements per thread sequentially.  This reduces the overall
    cost of the algorithm while keeping the work complexity O(n) and the step complexity O(log n).
    (Brent's Theorem optimization)

    Note, this kernel needs a minimum of 64*sizeof(T) bytes of shared memory.
    In other words if blockSize <= 32, allocate 64*sizeof(T) bytes.
    If blockSize > 32, allocate blockSize*sizeof(T) bytes.
*/
template <class T, unsigned int blockSize, bool nIsPow2>
__global__ void
reduce6(T *g_idata, T *g_odata, unsigned int n)
{
    T *sdata = SharedMemory<T>();

    // perform first level of reduction,
    // reading from global memory, writing to shared memory
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x*blockSize*2 + threadIdx.x;
    unsigned int gridSize = blockSize*2*gridDim.x;

    T mySum = 0;

    // we reduce multiple elements per thread.  The number is determined by the
    // number of active thread blocks (via gridDim).  More blocks will result
    // in a larger gridSize and therefore fewer elements per thread
    while (i < n)
    {
        mySum += g_idata[i];
        // ensure we don't read out of bounds -- this is optimized away for powerOf2 sized arrays
        if (nIsPow2 || i + blockSize < n)
            mySum += g_idata[i+blockSize];
        i += gridSize;
    }

    // each thread puts its local sum into shared memory
    sdata[tid] = mySum;
    __syncthreads();


    // do reduction in shared mem
    if (blockSize >= 512) { if (tid < 256) { sdata[tid] = mySum = mySum + sdata[tid + 256]; } __syncthreads(); }
    if (blockSize >= 256) { if (tid < 128) { sdata[tid] = mySum = mySum + sdata[tid + 128]; } __syncthreads(); }
    if (blockSize >= 128) { if (tid <  64) { sdata[tid] = mySum = mySum + sdata[tid +  64]; } __syncthreads(); }

#ifndef __DEVICE_EMULATION__
    if (tid < 32)
#endif
    {
        // now that we are using warp-synchronous programming (below)
        // we need to declare our shared memory volatile so that the compiler
        // doesn't reorder stores to it and induce incorrect behavior.
        volatile T* smem = sdata;
        if (blockSize >=  64) { smem[tid] = mySum = mySum + smem[tid + 32]; EMUSYNC; }
        if (blockSize >=  32) { smem[tid] = mySum = mySum + smem[tid + 16]; EMUSYNC; }
        if (blockSize >=  16) { smem[tid] = mySum = mySum + smem[tid +  8]; EMUSYNC; }
        if (blockSize >=   8) { smem[tid] = mySum = mySum + smem[tid +  4]; EMUSYNC; }
        if (blockSize >=   4) { smem[tid] = mySum = mySum + smem[tid +  2]; EMUSYNC; }
        if (blockSize >=   2) { smem[tid] = mySum = mySum + smem[tid +  1]; EMUSYNC; }
    }

    // write result for this block to global mem
    if (tid == 0)
        g_odata[blockIdx.x] = sdata[0];
}


extern "C"
bool isPow2(unsigned int x);


////////////////////////////////////////////////////////////////////////////////
// Wrapper function for kernel launch
////////////////////////////////////////////////////////////////////////////////
template <class T>
void
reduce(int size, int threads, int blocks,
       int whichKernel, T *d_idata, T *d_odata)
{
	string kernelName = "reduce" + convertInt(whichKernel) + '<';
	if(typeid(T) == typeid(int)){
		kernelName += "int";
	} else if (typeid(T) == typeid(float)){
		kernelName += "float";
	} else {
		 kernelName += "double";
	}

	if(whichKernel > 3){
		kernelName += "," + convertInt(threads) + "u";
		if (whichKernel == 6){
			kernelName += (isPow2(size))?",true":",false";
		}
	}
	kernelName += ">";

    dim3 dimBlock(threads, 1, 1);
    dim3 dimGrid(blocks, 1, 1);

    // when there is only one warp per block, we need to allocate two warps
    // worth of shared memory so that we don't index shared memory out of bounds
    int smemSize = (threads <= 32) ? 2 * threads * sizeof(T) : threads * sizeof(T);

    // choose which of the optimized versions of reduction to launch
    switch (whichKernel)
    {
    case 0:
	GpuProfiling::prepareProfiling( blocks, threads  );
        reduce0<T><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size);
	GpuProfiling::addResults( kernelName.c_str() );

        break;
    case 1:
	GpuProfiling::prepareProfiling( blocks, threads  );
        reduce1<T><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size);
	GpuProfiling::addResults( kernelName.c_str() );
        break;
    case 2:
	GpuProfiling::prepareProfiling( blocks, threads  );
        reduce2<T><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size);
	GpuProfiling::addResults( kernelName.c_str() );
        break;
    case 3:
	GpuProfiling::prepareProfiling( blocks, threads  );
        reduce3<T><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size);
	GpuProfiling::addResults( kernelName.c_str() );
        break;
    case 4:
        switch (threads)
        {
        case 512:
	GpuProfiling::prepareProfiling( blocks, threads  );
            reduce4<T, 512><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 256:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T, 256><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 128:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T, 128><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 64:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,  64><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 32:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,  32><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 16:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,  16><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  8:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,   8><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  4:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,   4><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  2:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,   2><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  1:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce4<T,   1><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        }
        break;
    case 5:
        switch (threads)
        {
        case 512:
	GpuProfiling::prepareProfiling( blocks, threads  );
            reduce5<T, 512><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 256:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T, 256><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 128:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T, 128><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 64:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,  64><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 32:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,  32><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case 16:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,  16><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  8:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,   8><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  4:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,   4><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  2:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,   2><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        case  1:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                   reduce5<T,   1><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;        }
        break;
    case 6:
    default:
        if (isPow2(size))
        {
            switch (threads)
            {
            case 512:
	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T, 512, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 256:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T, 256, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 128:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T, 128, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 64:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,  64, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 32:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,  32, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 16:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,  16, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  8:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   8, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  4:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   4, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  2:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   2, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  1:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   1, true><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            }
        }
        else
        {
            switch (threads)
            {
            case 512:
	GpuProfiling::prepareProfiling( blocks, threads  );
                reduce6<T, 512, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 256:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T, 256, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 128:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T, 128, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 64:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,  64, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 32:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,  32, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case 16:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,  16, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  8:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   8, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  4:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   4, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  2:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   2, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            case  1:
       	GpuProfiling::prepareProfiling( blocks, threads  );
                       reduce6<T,   1, false><<< dimGrid, dimBlock, smemSize >>>(d_idata, d_odata, size); 
	GpuProfiling::addResults( kernelName.c_str() );
break;            }
        }
        break;
    }
}

// Instantiate the reduction function for 3 types
template void
reduce<int>(int size, int threads, int blocks,
            int whichKernel, int *d_idata, int *d_odata);

template void
reduce<float>(int size, int threads, int blocks,
              int whichKernel, float *d_idata, float *d_odata);

template void
reduce<double>(int size, int threads, int blocks,
               int whichKernel, double *d_idata, double *d_odata);

#endif // #ifndef _REDUCE_KERNEL_H_
