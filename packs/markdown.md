# Markdown Writing Guidelines

## References & Links

### External Sources (MUST)

Always include URL links when referencing external sources.

```markdown
# Good: Descriptive text with URL
See the [CUDA Best Practices Guide](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/)
for memory coalescing techniques.

# Bad: Missing URL
See the CUDA Best Practices Guide for memory coalescing techniques.

# Bad: Raw URL without context
https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/
```

### Link Text (SHOULD)

- Use descriptive link text that indicates the destination
- Avoid generic text like "click here" or "this link"

### Academic & Technical Citations (SHOULD)

```markdown
# Paper citation with link
This implementation is based on FlashAttention [Dao et al., 2022](https://arxiv.org/abs/2205.14135).

# Multiple references
For background on attention mechanisms, see:
- [Attention Is All You Need (Vaswani et al., 2017)](https://arxiv.org/abs/1706.03762)
- [FlashAttention-2 (Dao, 2023)](https://arxiv.org/abs/2307.08691)
```

## Admonitions

Use admonitions to highlight important information:

| Level   | Format                  | Use When                                            |
|---------|-------------------------|-----------------------------------------------------|
| NOTE    | `> **NOTE**: ...`       | Providing additional context or clarification        |
| TIP     | `> **TIP**: ...`        | Suggesting best practices or optimizations           |
| WARNING | `> **WARNING**: ...`    | Highlighting potential pitfalls or unexpected behavior|
| DANGER  | `> **DANGER**: ...`     | Indicating critical risks or irreversible operations |

Example:

```markdown
> **WARNING**: This operation modifies the tensor in-place. Clone the tensor first
> if you need to preserve the original data.
```
