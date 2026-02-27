# CUDA Guidelines

**File extensions**: `.cu` for implementation, `.cuh` for headers
**Target architectures**: sm_80, sm_86, sm_89, sm_90, sm_100, sm_120 (Ampere / Ada / Hopper / Blackwell)

> The CMake `CMAKE_CUDA_ARCHITECTURES` variable in the project overlay MUST match this list exactly.

---

## Kernel Requirements (MUST)

Every CUDA kernel **MUST** satisfy ALL of the following:

1. **Error checking**: Use `CUDA_CHECK()` macro for every CUDA API call
2. **Bounds checking**: Validate thread indices before memory access
3. **Stream parameter**: Accept `cudaStream_t stream` parameter (default `0`)
4. **fp16 support**: Support `__half` type where applicable (via template or overload)
5. **Namespace**: Place in `package_name::kernels` namespace
6. **Documentation**: `@brief`, `@param`, `@throws` for host wrapper functions

## Error Checking Macro (MUST use)

```cuda
#define CUDA_CHECK(call)                                              \
    do {                                                              \
        cudaError_t err = call;                                       \
        if (err != cudaSuccess) {                                     \
            throw std::runtime_error(                                 \
                std::string(__FILE__) + ":" + std::to_string(__LINE__) + \
                " CUDA error: " + cudaGetErrorString(err)             \
            );                                                        \
        }                                                             \
    } while (0)
```

## Kernel Patterns (SHOULD follow)

- **SHOULD** use shared memory tiling with default `TILE_SIZE = 32`
- **SHOULD** use `__restrict__` on all pointer parameters
- **SHOULD** use `#pragma unroll` for known-bound inner loops
- **SHOULD** use warp-level primitives (`__shfl_down_sync`) for reductions within warps

For full reference implementations (MatMul, Reduction, etc.), see `docs/examples/`.

## Host Wrapper Pattern (MUST)

Every kernel **MUST** have a host wrapper function that:

1. Computes grid/block dimensions
2. Launches the kernel
3. Checks for launch errors via `cudaGetLastError()`

```cuda
template<typename T>
void MatMul(const T* d_A, const T* d_B, T* d_C,
            int M, int K, int N, cudaStream_t stream = 0) {
    constexpr int TILE_SIZE = 32;
    dim3 block(TILE_SIZE, TILE_SIZE);
    dim3 grid((N + TILE_SIZE - 1) / TILE_SIZE,
              (M + TILE_SIZE - 1) / TILE_SIZE);

    MatMulKernel<T, TILE_SIZE><<<grid, block, 0, stream>>>(
        d_A, d_B, d_C, M, K, N);

    CUDA_CHECK(cudaGetLastError());
}
```

## Stream & Event Management (SHOULD)

- **SHOULD** use non-default streams for concurrent kernel execution
- **SHOULD** use `cudaEvent_t` for inter-stream synchronization
- **MUST NOT** call `cudaDeviceSynchronize()` in production code — use stream-level sync

## Tensor Core Usage (SHOULD for Ampere+)

- **SHOULD** use `wmma` API or `mma.sync` PTX for matrix operations on supported architectures
- **SHOULD** ensure data alignment to 16-byte boundaries for Tensor Core operations
- **MAY** provide fallback path for architectures without Tensor Core support

## Occupancy & Performance (SHOULD)

- **SHOULD** use `cudaOccupancyMaxPotentialBlockSize` to determine optimal block size
- Target: kernel occupancy > 50%
- Target: memory bandwidth utilization > 70% of theoretical peak
- Target: FLOPs utilization > 60% for compute-bound kernels

## Common Pitfalls (MUST NOT)

- **MUST NOT** forget `__syncthreads()` when using shared memory
- **MUST NOT** assume kernel launch succeeded without checking errors
- **MUST NOT** access out-of-bounds memory — always guard with thread index checks
- **SHOULD** coalesce memory accesses (contiguous threads access contiguous memory)
- **SHOULD** minimize divergent branches within warps
- **SHOULD** use `__ldg()` or `const __restrict__` for read-only data
