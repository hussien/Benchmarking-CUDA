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

/* Computation of eigenvalues of a small symmetric, tridiagonal matrix */
#include <prof.h>
// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <float.h>

// includes, project
#include "cutil_inline.h"
#include "config.h"
#include "structs.h"
#include "matlab.h"

// includes, kernels
#include "bisect_kernel_small.cu"

// includes, file
#include "bisect_small.cuh"

////////////////////////////////////////////////////////////////////////////////
//! Determine eigenvalues for matrices smaller than MAX_SMALL_MATRIX
//! @param TimingIterations  number of iterations for timing
//! @param  input  handles to input data of kernel
//! @param  result handles to result of kernel
//! @param  mat_size  matrix size
//! @param  lg  lower limit of Gerschgorin interval
//! @param  ug  upper limit of Gerschgorin interval
//! @param  precision  desired precision of eigenvalues
//! @param  iterations  number of iterations for timing
////////////////////////////////////////////////////////////////////////////////
void
computeEigenvaluesSmallMatrix( const InputData& input, ResultDataSmall& result,
                               const unsigned int mat_size,
                               const float lg, const float ug,
                               const float precision,
                               const unsigned int iterations )
{
  unsigned int timer = 0;
  cutilCheckError( cutCreateTimer( &timer));

  cutilCheckError( cutStartTimer( timer));
  for( unsigned int i = 0; i < iterations; ++i) {

    dim3  blocks( 1, 1, 1);
    dim3  threads( MAX_THREADS_BLOCK_SMALL_MATRIX, 1, 1);

	GpuProfiling::prepareProfiling(  blocks, threads  );
    bisectKernel<<< blocks, threads >>>( input.g_a, input.g_b, mat_size,
                                         result.g_left, result.g_right,
                                         result.g_left_count,
                                         result.g_right_count,
                                         lg, ug, 0, mat_size,
                                         precision
                                       );
	GpuProfiling::addResults("bisectKernel");
  }
  cutilSafeCall( cudaThreadSynchronize());
  cutilCheckError( cutStopTimer( timer));
  cutilCheckMsg( "Kernel launch failed");
  printf( "Average time: %f ms (%i iterations)\n",
          cutGetTimerValue( timer) / (float) iterations, iterations );

  cutilCheckError( cutDeleteTimer( timer));
}

////////////////////////////////////////////////////////////////////////////////
//! Initialize variables and memory for the result for small matrices
//! @param result  handles to the necessary memory
//! @param  mat_size  matrix_size
////////////////////////////////////////////////////////////////////////////////
void
initResultSmallMatrix( ResultDataSmall& result, const unsigned int mat_size) {

  result.mat_size_f = sizeof(float) * mat_size;
  result.mat_size_ui = sizeof(unsigned int) * mat_size;

  result.eigenvalues = (float*) malloc( result.mat_size_f);

  // helper variables
  result.zero_f = (float*) malloc( result.mat_size_f);
  result.zero_ui = (unsigned int*) malloc( result.mat_size_ui);
  for( unsigned int i = 0; i < mat_size; ++i) {

    result.zero_f[i] = 0.0f;
    result.zero_ui[i] = 0;

    result.eigenvalues[i] = 0.0f;
  }

  cutilSafeCall( cudaMalloc( (void**) &result.g_left, result.mat_size_f));
  cutilSafeCall( cudaMalloc( (void**) &result.g_right, result.mat_size_f));

  cutilSafeCall( cudaMalloc( (void**) &result.g_left_count,
                            result.mat_size_ui));
  cutilSafeCall( cudaMalloc( (void**) &result.g_right_count,
                            result.mat_size_ui));

  // initialize result memory
  cutilSafeCall( cudaMemcpy( result.g_left, result.zero_f, result.mat_size_f,
                            cudaMemcpyHostToDevice));
  cutilSafeCall( cudaMemcpy( result.g_right, result.zero_f, result.mat_size_f,
                            cudaMemcpyHostToDevice));
  cutilSafeCall( cudaMemcpy( result.g_right_count, result.zero_ui,
                            result.mat_size_ui,
                            cudaMemcpyHostToDevice));
  cutilSafeCall( cudaMemcpy( result.g_left_count, result.zero_ui,
                            result.mat_size_ui,
                            cudaMemcpyHostToDevice));
}

////////////////////////////////////////////////////////////////////////////////
//! Cleanup memory and variables for result for small matrices
//! @param  result  handle to variables
////////////////////////////////////////////////////////////////////////////////
void
cleanupResultSmallMatrix( ResultDataSmall& result) {

  freePtr( result.eigenvalues);
  freePtr( result.zero_f);
  freePtr( result.zero_ui);

  cutilSafeCall( cudaFree( result.g_left));
  cutilSafeCall( cudaFree( result.g_right));
  cutilSafeCall( cudaFree( result.g_left_count));
  cutilSafeCall( cudaFree( result.g_right_count));
}

////////////////////////////////////////////////////////////////////////////////
//! Process the result obtained on the device, that is transfer to host and
//! perform basic sanity checking
//! @param  input  handles to input data
//! @param  result  handles to result data
//! @param  mat_size   matrix size
//! @param  filename  output filename
////////////////////////////////////////////////////////////////////////////////
void
processResultSmallMatrix( const InputData& input, const ResultDataSmall& result,
                          const unsigned int mat_size,
                          const char* filename ) {

  const unsigned int mat_size_f = sizeof(float) * mat_size;
  const unsigned int mat_size_ui = sizeof(unsigned int) * mat_size;

  // copy data back to host
  float* left = (float*) malloc( mat_size_f);
  unsigned int* left_count = (unsigned int*) malloc( mat_size_ui);

  cutilSafeCall( cudaMemcpy( left, result.g_left, mat_size_f,
                            cudaMemcpyDeviceToHost));
  cutilSafeCall( cudaMemcpy( left_count, result.g_left_count, mat_size_ui,
                            cudaMemcpyDeviceToHost));

  float* eigenvalues = (float*) malloc( mat_size_f);

  for( unsigned int i = 0; i < mat_size; ++i) {
      eigenvalues[left_count[i]] = left[i];
  }

  // save result in matlab format
  writeTridiagSymMatlab( filename, input.a, input.b+1, eigenvalues, mat_size);
//  GpuProfiling::printResults();


  freePtr( left);
  freePtr( left_count);
  freePtr( eigenvalues);
}
