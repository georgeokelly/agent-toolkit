#!/bin/bash
set -euo pipefail

# agent-check.sh — Validate generated rule files in a project directory
# Usage: agent-check.sh [project-dir]
#
# Checks:
#   1. Codex AGENTS.md size (must be < 32KiB)
#   2. Cursor .mdc frontmatter lint (must have closing ---)
#   3. No .cursorrules + .mdc dual-write conflict
#   4. Staleness (rules repo newer than generated files)
#   5. File existence (all expected files present)

RULES_HOME="${AGENT_RULES_HOME:-$HOME/.config/agent-rules}"
PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

HASH_FILE="$PROJECT_DIR/.agent-sync-hash"
PASS=0
FAIL=0
WARN=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  WARN: $1"; WARN=$((WARN + 1)); }

echo "Checking rules in $PROJECT_DIR"
echo "================================"

# --- 1. Codex AGENTS.md size ---

echo ""
echo "[1/5] Codex AGENTS.md size limit"

if [ -f "$PROJECT_DIR/AGENTS.md" ]; then
    SIZE=$(wc -c < "$PROJECT_DIR/AGENTS.md" | tr -d ' ')
    if [ "$SIZE" -gt 32768 ]; then
        fail "AGENTS.md is $SIZE bytes (> 32KiB). Codex will silently truncate!"
    else
        PERCENT=$((SIZE * 100 / 32768))
        pass "AGENTS.md is $SIZE bytes (${PERCENT}% of 32KiB limit)"
    fi
else
    fail "AGENTS.md not found"
fi

# --- 2. Cursor frontmatter lint ---

echo ""
echo "[2/5] Cursor .mdc frontmatter validation"

if [ -d "$PROJECT_DIR/.cursor/rules" ]; then
    MDC_COUNT=0
    MDC_FAIL=0
    for mdc in "$PROJECT_DIR/.cursor/rules/"*.mdc; do
        [ -f "$mdc" ] || continue
        MDC_COUNT=$((MDC_COUNT + 1))

        # Check: file must start with ---
        FIRST_LINE=$(head -1 "$mdc")
        if [ "$FIRST_LINE" != "---" ]; then
            fail "$(basename "$mdc"): missing opening ---"
            MDC_FAIL=$((MDC_FAIL + 1))
            continue
        fi

        # Check: must have a closing --- (second occurrence)
        CLOSING=$(awk 'NR>1 && /^---$/{print NR; exit}' "$mdc")
        if [ -z "$CLOSING" ]; then
            fail "$(basename "$mdc"): missing closing --- in frontmatter"
            MDC_FAIL=$((MDC_FAIL + 1))
        fi
    done

    if [ "$MDC_COUNT" -eq 0 ]; then
        fail "No .mdc files found in .cursor/rules/"
    elif [ "$MDC_FAIL" -eq 0 ]; then
        pass "All $MDC_COUNT .mdc files have valid frontmatter"
    fi
else
    fail ".cursor/rules/ directory not found"
fi

# --- 3. No dual-write conflict ---

echo ""
echo "[3/5] Cursor dual-write conflict check"

if [ -f "$PROJECT_DIR/.cursorrules" ] && [ -d "$PROJECT_DIR/.cursor/rules" ]; then
    warn ".cursorrules AND .cursor/rules/ both exist. .mdc files may silently override .cursorrules. Remove one."
else
    pass "No dual-write conflict detected"
fi

# --- 4. Staleness check ---

echo ""
echo "[4/5] Staleness detection"

if [ -d "$RULES_HOME/.git" ] && [ -f "$HASH_FILE" ]; then
    CURRENT_HASH="$(git -C "$RULES_HOME" rev-parse HEAD 2>/dev/null || echo "unknown")"
    STORED_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo "none")"

    if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
        pass "Generated files are up to date with rules repo"
    else
        warn "Rules repo has been updated since last sync. Run agent-sync."
    fi
elif [ ! -f "$HASH_FILE" ]; then
    warn "No sync hash found. Has agent-sync been run?"
else
    warn "Rules repo is not a git repository — cannot check staleness"
fi

# --- 5. File existence ---

echo ""
echo "[5/5] Generated file existence"

EXPECTED_FILES=("CLAUDE.md" "AGENTS.md")
for f in "${EXPECTED_FILES[@]}"; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        pass "$f exists"
    else
        fail "$f not found"
    fi
done

if [ -d "$PROJECT_DIR/.cursor/rules" ] && [ "$(ls "$PROJECT_DIR/.cursor/rules/"*.mdc 2>/dev/null | wc -l)" -gt 0 ]; then
    pass ".cursor/rules/ contains .mdc files"
else
    fail ".cursor/rules/ is empty or missing"
fi

# --- Summary ---

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"

if [ "$FAIL" -gt 0 ]; then
    echo "STATUS: FAILED — fix the issues above before using AI agents."
    exit 1
else
    echo "STATUS: OK"
    exit 0
fi
