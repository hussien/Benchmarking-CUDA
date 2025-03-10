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

/* Computation of eigenvalues of symmetric, tridiagonal matrix using
 * bisection.
 */
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
#include "util.h"
#include "gerschgorin.h"

#include "bisect_small.cuh"
#include "bisect_large.cuh"

const char *sSDKsample = "CUDA eigenvalues";

////////////////////////////////////////////////////////////////////////////////
// declaration, forward
void runTest( int argc, char** argv);

////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int
main( int argc, char** argv)
{
	GpuProfiling::initProf();
	printf("[ %s ]\n", sSDKsample);

    runTest( argc, argv);
exit(0);
    cutilExit(argc, argv);
}

////////////////////////////////////////////////////////////////////////////////
//! Initialize the input data to the algorithm
//! @param input  handles to the input data
//! @param exec_path  path where executable is run (argv[0])
//! @param mat_size  size of the matrix
//! @param user_defined  1 if the matrix size has been requested by the user,
//!                      0 if the default size
////////////////////////////////////////////////////////////////////////////////
void
initInputData( InputData& input, char* exec_path,
               const unsigned int mat_size, const unsigned int user_defined)
{
    // allocate memory
    input.a = (float*) malloc( sizeof(float) * mat_size);
    input.b = (float*) malloc( sizeof(float) * mat_size);

    if( 1 == user_defined) {

        // initialize diagonal and superdiagonal entries with random values
        srand( 278217421);
        // srand( clock());
        for( unsigned int i = 0; i < mat_size; ++i) {
            input.a[i] = (float) (2.0 * (((double)rand()
                                / (double) RAND_MAX) - 0.5));
            input.b[i] = (float) (2.0 * (((double)rand()
                                / (double) RAND_MAX) - 0.5));
        }

        // the first element of s is used as padding on the device (thus the
        // whole vector is copied to the device but the kernels are launched
        // with (s+1) as start address
        input.b[0] = 0.0f;
    }
    else {

        // read default matrix
        unsigned int input_data_size = mat_size;
        char* diag_path = cutFindFilePath( "diagonal.dat", exec_path);
        cutilCondition( 0 != diag_path);
        cutilCheckError( cutReadFilef( diag_path, &(input.a), &input_data_size));

        char* sdiag_path = cutFindFilePath( "superdiagonal.dat", exec_path);
        cutilCondition( 0 != sdiag_path);
        cutilCheckError( cutReadFilef( sdiag_path, &(input.b), &input_data_size,
                                   1));

        cutFree( diag_path);
        cutFree( sdiag_path);
    }

    // allocate device memory for input
    cutilSafeCall( cudaMalloc( (void**) &(input.g_a)    , sizeof(float) * mat_size));
    cutilSafeCall( cudaMalloc( (void**) &(input.g_b_raw), sizeof(float) * mat_size));

    // copy data to device
    cutilSafeCall( cudaMemcpy( input.g_a    , input.a, sizeof(float) * mat_size, cudaMemcpyHostToDevice ));
    cutilSafeCall( cudaMemcpy( input.g_b_raw, input.b, sizeof(float) * mat_size, cudaMemcpyHostToDevice ));

    input.g_b = input.g_b_raw + 1;
}

////////////////////////////////////////////////////////////////////////////////
//! Clean up input data, in particular allocated memory
//! @param input  handles to the input data
////////////////////////////////////////////////////////////////////////////////
void
cleanupInputData( InputData& input) {

    freePtr( input.a);
    freePtr( input.b);

    cutilSafeCall( cudaFree( input.g_a));
    input.g_a = NULL;
    cutilSafeCall( cudaFree( input.g_b_raw));
    input.g_b_raw = NULL;
    input.g_b = NULL;
}

////////////////////////////////////////////////////////////////////////////////
//! Check if a specific matrix size has to be used
//! @param argc  number of command line arguments (from main(argc, argv)
//! @param argv  pointers to command line arguments (from main(argc, argv)
//! @param matrix_size  size of matrix, updated if specific size specified on
//!                     command line
////////////////////////////////////////////////////////////////////////////////
void
getMatrixSize( int argc, char** argv,
               unsigned int& mat_size, unsigned int& user_defined)
{
    int temp = -1;
    cutGetCmdLineArgumenti( argc, (const char**) argv, "matrix-size", &temp);
    if( temp > 0) {

        mat_size = (unsigned int) temp;
        // data type short is used in the kernel
        cutilCondition( mat_size < (1 << 16));

        user_defined = 1;
    }

    printf( "Matrix size: %i x %i\n", mat_size, mat_size);
}

////////////////////////////////////////////////////////////////////////////////
//! Check if a specific precision of the eigenvalue has to be obtained
//! @param argc  number of command line arguments (from main(argc, argv)
//! @param argv  pointers to command line arguments (from main(argc, argv)
//! @param iters_timing  numbers of iterations for timing, updated if a
//!                      specific number is specified on the command line
////////////////////////////////////////////////////////////////////////////////
void
getPrecision( int argc, char** argv, float& precision) {

    float temp = -1.0f;
    cutGetCmdLineArgumentf( argc, (const char**) argv, "precision", &temp);
    if( temp > 0.0f) {
        precision = temp;
    }

    printf( "Precision: %f\n", precision);
}

////////////////////////////////////////////////////////////////////////////////
//! Check if a particular number of iterations for timings has to be used
//! @param argc  number of command line arguments (from main(argc, argv)
//! @param argv  pointers to command line arguments (from main(argc, argv)
//! @param  iters_timing  number of timing iterations, updated if user
//!                       specific value
////////////////////////////////////////////////////////////////////////////////
void
getItersTiming( int argc, char** argv, unsigned int& iters_timing) {

    int temp = -1;
    cutGetCmdLineArgumenti( argc, (const char**) argv, "iters-timing", &temp);
    if( temp > 0) {
        iters_timing = temp;
    }

    printf( "Iterations to be timed: %i\n", iters_timing);
}

////////////////////////////////////////////////////////////////////////////////
//! Check if a particular filename has to be used for the file where the result
//! is stored
//! @param argc  number of command line arguments (from main(argc, argv)
//! @param argv  pointers to command line arguments (from main(argc, argv)
//! @param  filename  filename of result file, updated if user specified
//!                   filename
////////////////////////////////////////////////////////////////////////////////
void
getResultFilename( int argc, char** argv, char*& filename) {

    char* temp = NULL;
    cutGetCmdLineArgumentstr( argc, (const char**) argv, "filename-result",
                              &temp);
    if( NULL != temp) {

        filename = (char*) malloc( sizeof(char) * strlen( temp));
        strcpy( filename, temp);

        cutFree( temp);
    }

    printf( "Result filename: '%s'\n", filename);
}

////////////////////////////////////////////////////////////////////////////////
//! Run a simple test for CUDA
////////////////////////////////////////////////////////////////////////////////
void
runTest( int argc, char** argv) {

    if( cutCheckCmdLineFlag(argc, (const char**)argv, "device") )
        cutilDeviceInit(argc, argv);
    else
        cudaSetDevice( cutGetMaxGflopsDeviceId() );

    unsigned int timer = 0;
    unsigned int timer_total = 0;
    cutilCheckError( cutCreateTimer( &timer));
    cutilCheckError( cutCreateTimer( &timer_total));

    // default
    unsigned int mat_size = 2048;
    // flag if the matrix size is due to explicit user request
    unsigned int user_defined = 0;
    // desired precision of eigenvalues
    float  precision = 0.00001f;
#ifdef __DEVICE_EMULATION__
    unsigned int iters_timing = 1;
#else
    unsigned int iters_timing = 100;
#endif
    char*  result_file = "eigenvalues.dat";

    // check if there is a command line request for the matrix size
    getMatrixSize( argc, argv, mat_size, user_defined);

    // check if user requested specific precision
    getPrecision( argc, argv, precision);

    // check if user requested specific number of iterations for timing
    getItersTiming( argc, argv, iters_timing);

    // file name for result file
    getResultFilename( argc, argv, result_file);

    // set up input
    InputData input;
    initInputData( input, argv[0], mat_size, user_defined);

    // compute Gerschgorin interval
    float lg = FLT_MAX;
    float ug = -FLT_MAX;
    computeGerschgorin( input.a, input.b+1, mat_size, lg, ug);
    printf( "Gerschgorin interval: %f / %f\n", lg, ug);

    // two kernels, for small matrices a lot of overhead can be avoided
    if( mat_size <= MAX_SMALL_MATRIX) {

        // initialize memory for result
        ResultDataSmall result;
        initResultSmallMatrix( result, mat_size);

        // run the kernel
        computeEigenvaluesSmallMatrix( input, result, mat_size, lg, ug,
                                       precision, iters_timing);

        // get the result from the device and do some sanity checks,
        // save the result
        processResultSmallMatrix( input, result, mat_size, result_file);

        // clean up
        cleanupResultSmallMatrix( result);
    }
    else {

        // initialize memory for result
        ResultDataLarge  result;
        initResultDataLargeMatrix( result, mat_size);

        // run the kernel
        computeEigenvaluesLargeMatrix( input, result, mat_size,
                                       precision, lg, ug,
                                       iters_timing );

        // get the result from the device and do some sanity checks
        // save the result if user specified matrix size
        processResultDataLargeMatrix( input, result, mat_size, result_file,
                                      user_defined, argv[0]);

        // cleanup
        cleanupResultDataLargeMatrix(result);
    }
	GpuProfiling::printResults();

    cleanupInputData( input);

    cudaThreadExit();
}

