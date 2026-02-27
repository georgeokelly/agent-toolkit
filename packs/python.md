# Python Guidelines

**Target version**: Python 3.10+
**Formatter**: Black (line length: 100)
**Linter**: Ruff (replaces flake8, isort, pylint)
**Type Checker**: mypy (strict mode)
**Dependency management**: pyproject.toml (SHOULD use); pin dependencies in lock file

---

## Naming Conventions (MUST)

```python
# Variables and functions: snake_case
batch_size = 32
def compute_loss(predictions, targets): ...

# Classes: PascalCase
class DataLoader: ...

# Constants: UPPER_SNAKE_CASE
MAX_ITERATIONS = 1000
DEFAULT_LR = 1e-3

# Private members: leading underscore
def _internal_helper(): ...
```

## Type Annotations (MUST)

Use Python 3.10+ native syntax. Do NOT import from `typing` for built-in generics.

```python
# MUST: 3.10+ native syntax
def process_batch(
    data: torch.Tensor,
    labels: torch.Tensor | None = None,
    batch_size: int = 32,
) -> tuple[torch.Tensor, dict[str, float]]:
    ...

# MUST NOT: legacy typing imports for built-in generics
# from typing import Optional, Union, List, Tuple  # ← WRONG for 3.10+
```

## Import Order (MUST)

```python
# 1. Standard library
import os
import sys
from pathlib import Path

# 2. Third-party
import numpy as np
import torch
import torch.nn as nn

# 3. Local (absolute)
from package_name.core import Model
from package_name.utils import timer

# 4. Local (relative, only within submodules)
from .helpers import preprocess
```

## Error Handling (MUST)

```python
# Always catch specific exceptions
try:
    result = risky_operation()
except SpecificException as e:
    logger.error(f"Operation failed: {e}")
    raise

# Prefer context managers for resource management
with acquire_resource() as resource:
    process(resource)
```

**MUST NOT:**

- Use mutable default arguments: `def foo(x=[])` — use `None` sentinel instead
- Catch bare `except:` — always specify exception types
- Mix tabs and spaces

**SHOULD:**

- Use f-strings for formatting: `f"Value: {x:.2f}"`
- Use `with` statements for all resource management
- Use `pathlib.Path` over `os.path`

## Docstrings (MUST for public APIs)

Use **Google Style**:

```python
def train_model(
    model: nn.Module,
    dataloader: torch.utils.data.DataLoader,
    epochs: int = 10,
) -> dict[str, list[float]]:
    """Train a PyTorch model.

    Args:
        model: The neural network to train.
        dataloader: Training data iterator.
        epochs: Number of training epochs.

    Returns:
        Dictionary with 'loss' and 'accuracy' lists per epoch.

    Raises:
        ValueError: If dataloader is empty.
    """
```

## Testing (MUST for new features)

- Framework: pytest
- **MUST** use `@pytest.fixture` for shared setup
- **SHOULD** use `@pytest.mark.parametrize` for multiple input variations
- **MUST** use `np.testing.assert_allclose` (not `==`) for floating-point comparisons
- Test files: `python/tests/test_<module>.py` mirroring source structure

```python
class TestComputeEngine:
    @pytest.fixture
    def engine(self):
        return ComputeEngine(device_id=0)

    @pytest.mark.parametrize("batch_size", [1, 16, 128])
    def test_process_various_sizes(self, engine, batch_size):
        data = np.random.randn(batch_size, 256).astype(np.float32)
        result = engine.process(data)
        assert result.shape[0] == batch_size
```
