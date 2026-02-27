# PyBind11 Bindings

## Module Structure (MUST)

```cpp
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>
#include <pybind11/numpy.h>
#include "package_name/core.h"

namespace py = pybind11;

PYBIND11_MODULE(_core, m) {
    m.doc() = "Core C++/CUDA implementations for package_name";

    py::class_<package_name::ComputeEngine>(m, "ComputeEngine")
        .def(py::init<int>(),
             py::arg("device_id") = 0,
             "Initialize compute engine on specified CUDA device")
        .def("process", &package_name::ComputeEngine::Process,
             py::arg("input"),
             "Process input data on GPU")
        .def_readwrite("batch_size",
             &package_name::ComputeEngine::batch_size);

    m.attr("__version__") = "0.1.0";
}
```

## Binding Rules

- **MUST** include `pybind11/stl.h` for automatic STL container conversion
- **MUST** include `pybind11/numpy.h` when accepting/returning numpy arrays
- **MUST** use `py::arg("name")` for all function parameters — unnamed args are confusing from Python
- **MUST** provide docstrings for all bound functions and classes
- **SHOULD** validate array dimensions and dtypes at the binding layer before calling C++
- **SHOULD** use `py::array_t<T>` with `.request()` for zero-copy numpy access

## Exception Handling at the Boundary

- C++ `std::runtime_error` → automatically becomes Python `RuntimeError`
- C++ `std::invalid_argument` → automatically becomes Python `ValueError`
- **MUST NOT** let CUDA errors propagate uncaught — wrap in `std::runtime_error` first
- **SHOULD** provide meaningful error messages that include tensor shapes and expected formats

## Python Overhead Target

- **SHOULD** keep Python-side overhead < 10µs per call for the binding layer itself
