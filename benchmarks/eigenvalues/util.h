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

/* Utility functions */

#ifndef _UTIL_H_
#define _UTIL_H_

////////////////////////////////////////////////////////////////////////////////
//! Safely free() for pointer
////////////////////////////////////////////////////////////////////////////////
template<class T>
inline void
freePtr( T* &ptr) {

  if( NULL != ptr) {
    free( ptr);
    ptr = NULL;
  }
}

////////////////////////////////////////////////////////////////////////////////
//! Minimum
////////////////////////////////////////////////////////////////////////////////
template<class T>
#ifdef __CUDACC__
__host__  __device__
#endif
T
min( const T& lhs, const T& rhs) {

  return (lhs < rhs) ? lhs : rhs;
}

////////////////////////////////////////////////////////////////////////////////
//! Maximum
////////////////////////////////////////////////////////////////////////////////
template<class T>
#ifdef __CUDACC__
__host__  __device__
#endif
T
max( const T& lhs, const T& rhs) {

  return (lhs < rhs) ? rhs : lhs;
}

////////////////////////////////////////////////////////////////////////////////
//! Sign of number (integer data type)
////////////////////////////////////////////////////////////////////////////////
template<class T>
#ifdef __CUDACC__
__host__  __device__
#endif
T
sign_i( const T& val) {
  return (val < 0) ? -1 : 1;
}

////////////////////////////////////////////////////////////////////////////////
//! Sign of number (float)
////////////////////////////////////////////////////////////////////////////////
#ifdef __CUDACC__
__host__  __device__
#endif
inline float
sign_f( const float& val) {
  return (val < 0.0f) ? -1.0f : 1.0f;
}

////////////////////////////////////////////////////////////////////////////////
//! Sign of number (double)
////////////////////////////////////////////////////////////////////////////////
#ifdef __CUDACC__
__host__  __device__
#endif
inline double
sign_d( const double& val) {
  return (val < 0.0) ? -1.0 : 1.0;
}

////////////////////////////////////////////////////////////////////////////////
//! Swap \a lhs and \a rhs
////////////////////////////////////////////////////////////////////////////////
template<class T>
#ifdef __CUDACC__
__host__  __device__
#endif
void
swap( T& lhs, T& rhs) {

  T temp = rhs;
  rhs = lhs;
  lhs = temp;
}

///////////////////////////////////////////////////////////////////////////////
//! Get the number of blocks that are required to process \a num_threads with
//! \a num_threads_blocks threads per block
///////////////////////////////////////////////////////////////////////////////
extern "C"
inline
unsigned int
getNumBlocksLinear( const unsigned int num_threads,
                    const unsigned int num_threads_block )
{
  const unsigned int block_rem =
    ((num_threads % num_threads_block) != 0) ? 1 : 0;
  return (num_threads / num_threads_block) + block_rem;
}

#endif // #ifndef _UTIL_H_
