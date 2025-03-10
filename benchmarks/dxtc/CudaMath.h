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

// Math functions and operators to be used with vector types.

#ifndef CUDAMATH_H
#define CUDAMATH_H


// Use power method to find the first eigenvector.
// http://www.miislita.com/information-retrieval-tutorial/matrix-tutorial-3-eigenvalues-eigenvectors.html
inline __device__ __host__ float3 firstEigenVector( float matrix[6] )
{
    // 8 iterations seems to be more than enough.

    float3 v = make_float3(1.0f, 1.0f, 1.0f);
    for(int i = 0; i < 8; i++) {
        float x = v.x * matrix[0] + v.y * matrix[1] + v.z * matrix[2];
        float y = v.x * matrix[1] + v.y * matrix[3] + v.z * matrix[4];
        float z = v.x * matrix[2] + v.y * matrix[4] + v.z * matrix[5];
        float m = max(max(x, y), z);
        float iv = 1.0f / m;
        #if __DEVICE_EMULATION__
        if (m == 0.0f) iv = 0.0f;
        #endif
        v = make_float3(x*iv, y*iv, z*iv);
    }

    return v;
}

inline __device__ void colorSums(const float3 * colors, float3 * sums)
{
#if __DEVICE_EMULATION__
    float3 color_sum = make_float3(0.0f, 0.0f, 0.0f);
    for (int i = 0; i < 16; i++)
    {
        color_sum += colors[i];
    }

    for (int i = 0; i < 16; i++)
    {
        sums[i] = color_sum;
    }
#else

    const int idx = threadIdx.x;

    sums[idx] = colors[idx];
    sums[idx] += sums[idx^8];
    sums[idx] += sums[idx^4];
    sums[idx] += sums[idx^2];
    sums[idx] += sums[idx^1];

#endif
}


inline __device__ float3 bestFitLine(const float3 * colors, float3 color_sum)
{
    // Compute covariance matrix of the given colors.
#if __DEVICE_EMULATION__
    float covariance[6] = {0, 0, 0, 0, 0, 0};
    for (int i = 0; i < 16; i++)
    {
        float3 a = colors[i] - color_sum * (1.0f / 16.0f);
        covariance[0] += a.x * a.x;
        covariance[1] += a.x * a.y;
        covariance[2] += a.x * a.z;
        covariance[3] += a.y * a.y;
        covariance[4] += a.y * a.z;
        covariance[5] += a.z * a.z;
    }
#else

    const int idx = threadIdx.x;

    float3 diff = colors[idx] - color_sum * (1.0f / 16.0f);

    // @@ Eliminate two-way bank conflicts here.
    // @@ It seems that doing that and unrolling the reduction doesn't help...
    __shared__ float covariance[16*6];

    covariance[6 * idx + 0] = diff.x * diff.x;    // 0, 6, 12, 2, 8, 14, 4, 10, 0
    covariance[6 * idx + 1] = diff.x * diff.y;
    covariance[6 * idx + 2] = diff.x * diff.z;
    covariance[6 * idx + 3] = diff.y * diff.y;
    covariance[6 * idx + 4] = diff.y * diff.z;
    covariance[6 * idx + 5] = diff.z * diff.z;

    for(int d = 8; d > 0; d >>= 1)
    {
        if (idx < d)
        {
            covariance[6 * idx + 0] += covariance[6 * (idx+d) + 0];
            covariance[6 * idx + 1] += covariance[6 * (idx+d) + 1];
            covariance[6 * idx + 2] += covariance[6 * (idx+d) + 2];
            covariance[6 * idx + 3] += covariance[6 * (idx+d) + 3];
            covariance[6 * idx + 4] += covariance[6 * (idx+d) + 4];
            covariance[6 * idx + 5] += covariance[6 * (idx+d) + 5];
        }
    }

#endif

    // Compute first eigen vector.
    return firstEigenVector(covariance);
}


#endif // CUDAMATH_H
