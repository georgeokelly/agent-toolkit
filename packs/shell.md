# Shell Scripting Guidelines

**Target**: Bash 5.x+ (note Bash-only features where applicable)
**Linter**: [ShellCheck](https://www.shellcheck.net/) (MUST pass with zero warnings)
**Formatter**: shfmt (indent: 4 spaces, `-bn -ci -sr`)

---

## Script Header (MUST)

Every script file MUST begin with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `set -e`: exit on error
- `set -u`: treat unset variables as errors
- `set -o pipefail`: propagate pipe failures

## Naming Conventions (MUST)

```bash
# Variables: snake_case
local input_file="data.csv"

# Constants / Environment exports: UPPER_SNAKE_CASE
readonly MAX_RETRIES=3
export PROJECT_ROOT="/opt/app"

# Functions: snake_case
process_batch() { ... }

# MUST NOT: camelCase, PascalCase, or Hungarian notation
```

## Quoting & Variable Expansion (MUST)

```bash
# MUST: double-quote all variable expansions
echo "Processing ${input_file}"
cp "$src" "$dst"

# MUST: quote array expansions to preserve elements
for item in "${files[@]}"; do
    process "$item"
done

# SHOULD: use single quotes for static strings (no expansion)
grep -r 'TODO' src/

# MUST NOT: unquoted variables (word splitting + glob expansion risk)
# rm $file         ← WRONG: splits on spaces, expands globs
# rm "$file"       ← CORRECT
```

## Error Handling (MUST)

```bash
# MUST: use trap for cleanup
cleanup() {
    rm -f "$tmp_file"
}
trap cleanup EXIT

# MUST: check cd success
cd "$target_dir" || { echo "Failed to cd to $target_dir" >&2; exit 1; }

# SHOULD: check command return values explicitly when set -e is insufficient
if ! output=$(some_command 2>&1); then
    echo "Error: ${output}" >&2
    exit 1
fi
```

## Dangerous Command Protection (MUST)

```bash
# MUST: protect rm -rf with variable validation
[[ -n "${dir}" && "${dir}" != "/" ]] || { echo "Refusing to rm empty/root path" >&2; exit 1; }
rm -rf "${dir:?'dir must be set'}"

# MUST NOT: use eval unless absolutely necessary (and document why)
# MUST NOT: use unquoted glob patterns in rm/mv/cp
```

## Functions (SHOULD)

```bash
process_file() {
    local input_path="$1"
    local output_path="${2:-/dev/stdout}"

    # Validate arguments
    [[ -f "$input_path" ]] || { echo "Not a file: $input_path" >&2; return 1; }

    # Use local for all function-scoped variables
    local line_count
    line_count=$(wc -l < "$input_path")

    echo "Processed ${line_count} lines" >&2
}
```

- **MUST** declare function-scoped variables with `local`
- **SHOULD** validate arguments at function entry
- **SHOULD** send diagnostic/log output to stderr (`>&2`)

## Common Patterns (SHOULD)

### Temporary Files

```bash
tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT
```

### Argument Parsing

```bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) verbose=1; shift ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Option $1 requires a value" >&2; exit 1; }
            output="$2"
            shift 2
            ;;
        --)           shift; break ;;
        -*)           echo "Unknown option: $1" >&2; exit 1 ;;
        *)            args+=("$1"); shift ;;
    esac
done
```

## Portability (SHOULD)

- **SHOULD** prefer POSIX builtins over external commands where practical (`[[ ]]` is Bash-only; `[ ]` is POSIX)
- **SHOULD** mark Bash-only features with comments when portability matters
- **SHOULD** use `command -v` instead of `which` to check command availability
- **SHOULD** use `printf` over `echo` for portable output (especially with `-e`, `-n` flags)

## Testing (SHOULD for non-trivial scripts)

- Framework: [bats-core](https://github.com/bats-core/bats-core)
- **SHOULD** extract logic into functions and test functions individually
- **SHOULD** use `setup` / `teardown` for temporary files and directories

```bash
@test "process_file handles missing file" {
    run process_file "/nonexistent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not a file"* ]]
}
```

## Common Pitfalls (MUST NOT)

- **MUST NOT** parse `ls` output — use globs or `find` with `-print0` + `xargs -0`
- **MUST NOT** use `cat file | cmd` when `cmd < file` suffices (useless use of cat)
- **MUST NOT** assume `local` declaration and assignment succeed together — split when capturing subshell exit codes: `local val; val=$(cmd)`
- **SHOULD NOT** use `$RANDOM` for security-sensitive purposes — use `/dev/urandom`
