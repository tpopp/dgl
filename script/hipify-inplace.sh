#!/bin/bash

# Hipifies the DGL codebase. That is, translates CUDA terminology to HIP, using
# the HIPIFY tooling (https://rocm.docs.amd.com/projects/HIPIFY/) plus some
# custom regex replacements. This performs the hipification inplace, saving the
# original files with a .prehip extension and then modifying the existing files
# without renaming them. This means HIP files will have cuda file extensions
# (e.g. .cu), so some tooling will need to be modified to work with this (e.g.
# set language mode in CMake). The advantage is that file path references like
# include statements don't need to change.

set -euo pipefail

cd "${DGL_HOME}"

HIPIFY_LOG="/tmp/hipify-inplace.log"

function find_code() {
    find $@ -type f -name '*.cu' -o -name '*.CU'
    find $@ -type f -name '*.cpp' -o -name '*.cxx' -o -name '*.c' -o -name '*.cc'
    find $@ -type f -name '*.CPP' -o -name '*.CXX' -o -name '*.C' -o -name '*.CC'
    find $@ -type f -name '*.cuh' -o -name '*.CUH'
    find $@ -type f -name '*.h' -o -name '*.hpp' -o -name '*.inc' -o -name '*.inl' -o -name '*.hxx' -o -name '*.hdl'
    find $@ -type f -name '*.H' -o -name '*.HPP' -o -name '*.INC' -o -name '*.INL' -o -name '*.HXX' -o -name '*.HDL'
}

# There isn't any direct cuda code in the tests, but we still want to run our
# own sed replacements and want a prehip file for what they were before.
declare -a srcs=(
    $(find_code src include third_party/cccl third_party/cuco tests third_party/HugeCTR/gpu_cache)
)

declare -a log_files=()

log_file="$(mktemp --tmpdir hipify_tensoradapter.XXX.log)"
log_files+=("${log_file}")
( set -x ; script/hipify-tensoradapter.py &> "${log_file}" ) &

log_file="$(mktemp --tmpdir hipify_graphbolt.XXX.log)"
log_files+=("${log_file}")
( set -x ; script/hipify-graphbolt.py &> "${log_file}" ) &


for src in ${srcs[@]}; do
    log_file="$(mktemp --tmpdir hipify_${src//\//_}.XXX.log)"
    log_files+=("${log_file}")
    ( set -x ; hipify-perl -print-stats -inplace $src &> "${log_file}" ) &
done

sleep 1 # Hack to make it more likely the echo below prints after the last job command line from above.
echo "Waiting for hipify jobs to complete"
wait

cat "${log_files[@]}" > "${HIPIFY_LOG}" && rm "${log_files[@]}"
echo "Logs written to ${HIPIFY_LOG}"

declare -a all_srcs=(
    $(find_code src include  tests third_party/HugeCTR/gpu_cache tensoradapter graphbolt)
)
# Additional fixes for project-specific things and things hipify misses or gets
# wrong.
for src in ${all_srcs[@]}; do
    sed -i -e 's@#include <hipblas.h>@#include <hipblas/hipblas.h>@' \
        -e 's@#include <hipsparse.h>@#include <hipsparse/hipsparse.h>@' \
        -e 's@#include <cuda_fp8.h>@#include <hip/hip_fp8.h>@' \
        -e 's@#include <cuda_bf16.h>@#include <hip/hip_bf16.h>@' \
        -e 's@\bDGL_USE_CUDA\b@DGL_USE_ROCM@g' \
        -e 's@\bGRAPHBOLT_USE_CUDA\b@GRAPHBOLT_USE_ROCM@g' `# TODO(tpopp): changed` \
        -e 's@\bCUB_VERSION\b@HIPCUB_VERSION@g' \
        -e 's@\bCUDART_ZERO_BF16\b@HIPRT_ZERO_BF16@g' \
        -e 's@\bCUDART_INF_BF16\b@HIPRT_INF_BF16@g' \
        -e 's@\bthrust::cuda::par@thrust::hip::par@g' \
        -e 's@\b__nv_fp8_e4m3\b@__hip_fp8_e4m3@g' \
        -e 's@\b__nv_fp8_e5m2\b@__hip_fp8_e5m2@g' \
        -e 's@\bCUBLAS_GEMM_DEFAULT_TENSOR_OP\b@HIPBLAS_GEMM_DEFAULT@g' \
        -e 's@\bcurand4\b@hiprand4@g' \
        -e 's@\bhip_bfloat16\b@__hip_bfloat16@g' `# hipify uses the old one` \
        -e 's@\b__trap();@abort();@' \
        -e 's@_hip.h@.h@' $src # Not sure why hipify is changing the import name, though the file name is the original.

    # If no changes were made, delete the prehip file.
    if cmp -s "${src}" "${src}.prehip"; then
        echo "Deleting unchanged ${src}.prehip"
        rm "${src}.prehip"
    fi
done
