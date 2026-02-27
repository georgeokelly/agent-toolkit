# Project Overlay Template

> Copy this file to your project root as `.agent-local.md` and fill in each section.
> This file SHOULD be committed to the project's git repository.
>
> For private preferences that should NOT be committed (e.g., personal API keys,
> local paths), Claude Code users can use `CLAUDE.local.md` which is auto-gitignored.

## Project Overview

<!-- One-sentence project description + boundary statement -->
**Project**: [Project name] — [one-line description]
**Boundary**: [e.g., "Performance and memory efficiency take priority over code elegance"]

**Tech Stack**: [e.g., Python 3.10+, C++17, CUDA 12.x, PyTorch/JAX]
**Build System**: [e.g., CMake 3.24+, setuptools]
**Target Platform**: [e.g., Linux (primary), Windows (secondary)]

## Project Structure

<!-- MUST fill in. This is the single most important section for AI agent effectiveness. -->

```
project-root/
├── python/
│   ├── src/package_name/       # Python source
│   │   ├── __init__.py
│   │   ├── core.py             # Main Python API
│   │   └── utils.py            # Utilities
│   └── tests/                  # Python tests (mirrors src/ structure)
│       └── test_core.py
├── cpp/
│   ├── src/                    # C++ implementation
│   │   ├── core.cpp
│   │   └── bindings.cpp        # PyBind11 bindings
│   ├── include/package_name/   # C++ public headers
│   │   └── core.h
│   └── tests/                  # Google Test
│       └── test_core.cpp
├── cuda/
│   ├── kernels/                # CUDA .cu files
│   │   ├── matmul.cu
│   │   └── reduce.cu
│   └── include/                # CUDA .cuh headers
│       └── cuda_utils.cuh
├── benchmarks/                 # Performance benchmarks
├── docs/
│   └── examples/               # Full reference implementations
├── CMakeLists.txt
└── pyproject.toml
```

### Source ↔ Test Mapping

<!-- Describe how test files correspond to source files -->
- `python/src/package_name/core.py` → `python/tests/test_core.py`
- `cpp/src/core.cpp` → `cpp/tests/test_core.cpp`

## Build & Test Commands

```bash
# Full build
pip install -e . -v

# C++ only
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j

# Run all tests
pytest python/tests/ -v
cmake --build build --target test
```

## Core Architectural Invariants

<!-- Things that MUST NOT be violated. Examples: -->
- [e.g., All GPU memory allocation goes through CudaMemory RAII wrapper]
- [e.g., Exceptions must not cross CUDA kernel boundaries]
- [e.g., All public Python APIs must have type annotations]

## Performance Targets

- Kernel occupancy: > 50%
- Memory bandwidth utilization: > 70% of theoretical peak
- FLOPs utilization: > 60% for compute-bound kernels
- Python binding overhead: < 10µs per call

## Boundaries (DO NOT touch)

<!-- Files, modules, or APIs that must not be modified without explicit approval -->
- [e.g., `cpp/include/package_name/core.h` — public API, backward compatibility required]

## Project-Specific Patterns

<!-- Macros, patterns, or conventions unique to this project -->

### CUDA Architecture List

The following MUST match `CMAKE_CUDA_ARCHITECTURES` in CMakeLists.txt:

```cmake
set(CMAKE_CUDA_ARCHITECTURES 80 86 89 90 100 120)
```

### Key Macros

- `CUDA_CHECK(call)` — defined in `cuda/include/cuda_utils.cuh`, MUST be used for all CUDA API calls
