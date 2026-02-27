# C++ Guidelines

**Standard**: Strict C++17. C++20 features are NOT permitted unless explicitly whitelisted in the project overlay.
**Naming convention base**: [Google C++ Style Guide](https://google.github.io/styleguide/cppguide.html). The rules below are key project-specific overrides and clarifications.
**Formatter**: clang-format (Google style, modified)
**Linter**: clang-tidy

---

## Naming Conventions (MUST)

```cpp
// Classes/Structs: PascalCase
class TensorProcessor { ... };

// Public methods: PascalCase
void ProcessBatch(const Tensor& input);

// Private members: snake_case with trailing underscore
int internal_state_;

// Functions: PascalCase
void InitializeDevice();

// Variables: snake_case
int num_threads = 4;

// Namespaces: snake_case
namespace cuda_utils { }
```

### Constants: `constexpr` vs `const` (MUST distinguish)

```cpp
// constexpr: value known at compile time → use kCamelCase
constexpr int kMaxBatchSize = 1024;
constexpr int kTileSize = 32;

// const: value determined at runtime → use UPPER_SNAKE_CASE or kCamelCase
const double PI = 3.14159265359;
```

Rule: if it CAN be `constexpr`, it **MUST** be `constexpr`.

## Header Files (MUST)

- **MUST** use `#pragma once` (not include guards)
- **MUST** use forward declarations to minimize includes
- **SHOULD** follow include order: project headers → third-party → standard library

## Ownership & Memory (MUST)

- **MUST** use `std::unique_ptr` / `std::shared_ptr` for ownership — no raw owning pointers
- **MUST** use RAII for all resource management (GPU memory, file handles, locks)
- **MUST** delete copy constructor/assignment for non-copyable resources; explicitly default move operations
- **MUST NOT** mix `malloc/free` with `new/delete`

```cpp
// RAII pattern (summarized — see docs/examples/ for full implementations)
class CudaMemory {
public:
    explicit CudaMemory(size_t size);  // cudaMalloc in ctor
    ~CudaMemory();                      // cudaFree in dtor
    CudaMemory(const CudaMemory&) = delete;
    CudaMemory& operator=(const CudaMemory&) = delete;
    CudaMemory(CudaMemory&&) noexcept;
    void* Get() const;
private:
    void* ptr_ = nullptr;
    size_t size_;
};
```

## Exception & Error Boundary Strategy (MUST)

- **MUST** use exceptions for error propagation within C++ code
- **MUST** mark functions `noexcept` when they genuinely cannot throw (destructors, move operations, simple getters)
- **MUST NOT** let C++ exceptions propagate across CUDA kernel boundaries
- **SHOULD** catch exceptions at the pybind11 boundary — pybind11 automatically translates `std::runtime_error` → Python `RuntimeError`
- **SHOULD** prefer specific exception types (`std::invalid_argument`, `std::runtime_error`) over generic `std::exception`

## Modern C++17 Features (SHOULD use)

- `std::optional` for nullable return values (instead of pointer + nullptr)
- `std::string_view` for non-owning string references
- Structured bindings: `auto [key, value] = map_entry;`
- `if constexpr` for compile-time branching in templates
- `std::variant` when a value can be one of several types

## Testing (MUST for new features)

- Framework: Google Test
- **MUST** use `TEST_F` with fixtures for shared setup
- **MUST** test both valid inputs and expected error conditions (`EXPECT_THROW`)

```cpp
TEST_F(ComputeEngineTest, ProcessEmptyInputThrows) {
    std::vector<float> input;
    EXPECT_THROW(engine_->Process(input), std::invalid_argument);
}
```

**MUST NOT:**

- Use raw pointers for ownership
- Forget to initialize variables
- Assume `const` and `constexpr` are interchangeable
- Leave CUDA API calls unchecked
