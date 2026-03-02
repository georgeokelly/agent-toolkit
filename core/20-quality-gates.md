# Quality Gates

All code changes **MUST** satisfy these gates before submission.

## Code Review Checklist

- [ ] **Type safety**: Python has type hints; C++ has no `void*` without justification
- [ ] **Memory safety**: No leaks; use RAII in C++; check all CUDA errors
- [ ] **Performance**: Profiled critical paths; no obvious bottlenecks introduced
- [ ] **Testing**: Existing tests pass; new features have corresponding tests
- [ ] **Documentation**: Public APIs documented; complex logic has explanatory comments
- [ ] **Style**: Passes all configured linters (see language-specific packs)
- [ ] **Edge cases**: Handles empty inputs, large inputs, error conditions
- [ ] **Thread safety**: CUDA streams used correctly; no race conditions

## Documentation Standards

Every public function **MUST** have:

1. Brief description
2. Parameter descriptions
3. Return value description
4. Exceptions / errors that can be raised
5. Example usage (SHOULD, for complex functions)

Code comments:

- **MUST NOT** state the obvious (`int count = 0; // Initialize counter`)
- **SHOULD** explain *why*, not *what* (`// Start from 0 to match 0-indexed CUDA thread IDs`)
- **SHOULD** explain complex logic or non-obvious trade-offs
- **MUST** add or update comments when fixing bugs, optimizing, or changing non-trivial logic — explain the reasoning, not the diff (e.g., `// Use xargs to normalize whitespace; tr alone leaves leading spaces`)
- **SHOULD** add step-level comments for procedural/sequential code — each major phase gets a one-line summary of *what* and *why*, forming a readable outline of the procedure

## Quick Reference Commands

```bash
# Python
black python/src/ python/tests/
ruff check --fix python/
mypy python/src/

# C++
find cpp/ -name "*.cpp" -o -name "*.h" | xargs clang-format -i
clang-tidy cpp/src/*.cpp

# Build (cross-platform)
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --build build --target test

# Python tests
pytest python/tests/ -v

# Full install
pip install -e . -v
```
