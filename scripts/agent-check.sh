#!/usr/bin/env bash
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
#   6. Core .mdc semantic validation (alwaysApply must be true)
#   7. Skills deployment validation (manifest + directory integrity)
#   8. Commands deployment validation (manifest + file integrity)
#   9. Worktrees.json deployment validation
#  10. .vscode/settings.json validity (if exists)

show_help() {
    cat <<'EOF'
agent-check — Validate generated rule files in a project directory

USAGE
    agent-check [options] [project-dir]

ARGUMENTS
    project-dir    Target project directory (default: current directory)

OPTIONS
    -h, --help     Show this help message and exit

ENVIRONMENT
    AGENT_RULES_HOME   Path to central rules repo (default: ~/.config/agent-rules)

CHECKS PERFORMED
    1. Codex AGENTS.md size (must be < 32KiB)
    2. Cursor .mdc frontmatter lint (must have closing ---)
    3. No .cursorrules + .mdc dual-write conflict
    4. Staleness detection (rules repo newer than generated files)
    5. Generated file existence (CLAUDE.md, AGENTS.md, .mdc files)
    6. Core .mdc alwaysApply validation (core rules must be always-on)
    7. Skills deployment validation (manifest + directory integrity)
    8. Commands deployment validation (manifest + file integrity)
    9. Worktrees.json deployment validation
   10. .vscode/settings.json validity

EXAMPLES
    agent-check                  # Check rules in current directory
    agent-check ~/my-project     # Check rules in a specific project

EXIT CODES
    0   All checks passed
    1   One or more checks failed
EOF
    exit 0
}

case "${1:-}" in
    -h|--help) show_help ;;
esac

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
# Codex size check is advisory — Codex is not the primary tool in this workflow
echo "[1/10] Codex AGENTS.md size limit (advisory)"

if [ -f "$PROJECT_DIR/.agent-rules/AGENTS.md" ]; then
    SIZE=$(wc -c < "$PROJECT_DIR/.agent-rules/AGENTS.md" | tr -d ' ')
    if [ "$SIZE" -gt 32768 ]; then
        warn ".agent-rules/AGENTS.md is $SIZE bytes (> 32KiB). Codex may silently truncate."
    else
        PERCENT=$((SIZE * 100 / 32768))
        pass ".agent-rules/AGENTS.md is $SIZE bytes (${PERCENT}% of 32KiB limit)"
    fi
else
    warn ".agent-rules/AGENTS.md not found (Codex not in use)"
fi

# --- 2. Cursor frontmatter lint ---

echo ""
echo "[2/10] Cursor .mdc frontmatter validation"

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
echo "[3/10] Cursor dual-write conflict check"

if [ -f "$PROJECT_DIR/.cursorrules" ] && [ -d "$PROJECT_DIR/.cursor/rules" ]; then
    warn ".cursorrules AND .cursor/rules/ both exist. .mdc files may silently override .cursorrules. Remove one."
else
    pass "No dual-write conflict detected"
fi

# --- 4. Staleness check ---

echo ""
echo "[4/10] Staleness detection"

if [ -f "$HASH_FILE" ]; then
    STORED_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo "none")"

    # Recompute the full composite hash using the same algorithm as agent-sync
    HASH_CMD="shasum"
    command -v shasum &>/dev/null || HASH_CMD="sha1sum"
    command -v "$HASH_CMD" &>/dev/null || HASH_CMD="md5sum"

    if [ -d "$RULES_HOME/.git" ]; then
        SUB_HASH="$(git -C "$RULES_HOME" submodule status 2>/dev/null | awk '{print $1}' | tr -d '+-U' | sort | tr -d '\n')"
        CURRENT_RULES_HASH="$(git -C "$RULES_HOME" rev-parse HEAD 2>/dev/null || echo "no-git"):${SUB_HASH:-no-submodules}"
    else
        CURRENT_RULES_HASH="$(find "$RULES_HOME" \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \) -type f -exec "$HASH_CMD" {} + 2>/dev/null | sort | "$HASH_CMD" | awk '{print $1}')"
    fi

    CURRENT_OVERLAY_HASH="$(find "$PROJECT_DIR" -maxdepth 3 -name '.agent-local.md' -not -path '*/.git/*' -not -path '*/node_modules/*' -type f -exec "$HASH_CMD" {} + 2>/dev/null | sort | "$HASH_CMD" | awk '{print $1}')"

    CURRENT_REVIEWER_CONF_HASH=""
    if [ -f "$PROJECT_DIR/.cursor/reviewer-models.conf" ]; then
        CURRENT_REVIEWER_CONF_HASH="$("$HASH_CMD" "$PROJECT_DIR/.cursor/reviewer-models.conf" 2>/dev/null | awk '{print $1}')"
    fi

    CURRENT_HASH="${CURRENT_RULES_HASH}:${CURRENT_OVERLAY_HASH}:${CURRENT_REVIEWER_CONF_HASH}"

    if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
        pass "Rules are up to date with last sync (rules repo + overlays + reviewer config)"
    else
        warn "Rules have been updated since last sync. Run agent-sync."
    fi
else
    warn "No sync hash found. Has agent-sync been run?"
fi

# --- 5. File existence ---

echo ""
echo "[5/10] Generated file existence"

# CLAUDE.md is required; AGENTS.md is advisory (Codex is not the primary tool)
if [ -f "$PROJECT_DIR/.agent-rules/CLAUDE.md" ]; then
    pass ".agent-rules/CLAUDE.md exists"
else
    fail ".agent-rules/CLAUDE.md not found"
fi
if [ -f "$PROJECT_DIR/.agent-rules/AGENTS.md" ]; then
    pass ".agent-rules/AGENTS.md exists"
else
    warn ".agent-rules/AGENTS.md not found (Codex not in use)"
fi

# Warn if root-level remnants exist (Cursor would auto-inject these)
for f in CLAUDE.md AGENTS.md; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        warn "Root-level $f exists — Cursor will auto-inject it, duplicating .mdc rules. Run agent-sync to clean up."
    fi
done

if [ -d "$PROJECT_DIR/.cursor/rules" ] && [ "$(ls "$PROJECT_DIR/.cursor/rules/"*.mdc 2>/dev/null | wc -l)" -gt 0 ]; then
    pass ".cursor/rules/ contains .mdc files"
else
    fail ".cursor/rules/ is empty or missing"
fi

# --- 6. Core .mdc semantic validation ---

echo ""
echo "[6/10] Core .mdc alwaysApply validation"

CORE_PATTERNS=("00-communication" "10-workflow" "20-quality-gates")
if [ -d "$PROJECT_DIR/.cursor/rules" ]; then
    CORE_OK=true
    for pattern in "${CORE_PATTERNS[@]}"; do
        mdc="$PROJECT_DIR/.cursor/rules/${pattern}.mdc"
        if [ -f "$mdc" ]; then
            if grep -q 'alwaysApply: true' "$mdc"; then
                pass "${pattern}.mdc has alwaysApply: true"
            else
                fail "${pattern}.mdc is missing alwaysApply: true (core rules must always load)"
                CORE_OK=false
            fi
        else
            warn "${pattern}.mdc not found in .cursor/rules/"
        fi
    done
fi

# --- 7. Skills deployment validation ---

echo ""
echo "[7/10] Skills deployment validation"

SKILLS_MANIFEST="$PROJECT_DIR/.cursor/skills/.agent-sync-skills-manifest"
SKILLS_SRC="$RULES_HOME/skills"
HAS_SOURCE_SKILLS=false
if [ -d "$SKILLS_SRC" ] && [ "$(ls -d "$SKILLS_SRC"/*/ 2>/dev/null)" ]; then
    HAS_SOURCE_SKILLS=true
fi

if $HAS_SOURCE_SKILLS; then
    if [ -f "$SKILLS_MANIFEST" ]; then
        SKILLS_OK=true
        SKILLS_CHECKED=0
        while IFS= read -r skill_name; do
            [ -z "$skill_name" ] && continue
            SKILLS_CHECKED=$((SKILLS_CHECKED + 1))
            skill_dir="$PROJECT_DIR/.cursor/skills/$skill_name"
            if [ -d "$skill_dir" ] && [ "$(ls -A "$skill_dir" 2>/dev/null)" ]; then
                pass "Skill '$skill_name' deployed and non-empty"
            else
                fail "Skill '$skill_name' listed in manifest but missing or empty"
                SKILLS_OK=false
            fi
        done < "$SKILLS_MANIFEST"
        if [ "$SKILLS_CHECKED" -eq 0 ]; then
            fail "Skills manifest exists but is empty. Run agent-sync to regenerate."
        elif $SKILLS_OK; then
            pass "All $SKILLS_CHECKED manifest skills are deployed"
        fi
    else
        fail "Rules repo has skills but .agent-sync-skills-manifest not found. Run agent-sync."
    fi
else
    pass "No skills in rules repo (nothing to validate)"
fi

# --- 8. Commands deployment validation ---

echo ""
echo "[8/10] Commands deployment validation"

COMMANDS_MANIFEST="$PROJECT_DIR/.cursor/commands/.agent-sync-commands-manifest"
COMMANDS_SRC="$RULES_HOME/commands"
HAS_SOURCE_COMMANDS=false
if [ -d "$COMMANDS_SRC" ] && [ "$(ls "$COMMANDS_SRC"/*.md 2>/dev/null)" ]; then
    HAS_SOURCE_COMMANDS=true
fi

if $HAS_SOURCE_COMMANDS; then
    if [ -f "$COMMANDS_MANIFEST" ]; then
        COMMANDS_OK=true
        COMMANDS_CHECKED=0
        while IFS= read -r cmd_name; do
            [ -z "$cmd_name" ] && continue
            COMMANDS_CHECKED=$((COMMANDS_CHECKED + 1))
            cmd_file="$PROJECT_DIR/.cursor/commands/$cmd_name"
            if [ -f "$cmd_file" ]; then
                pass "Command '$cmd_name' deployed"
            else
                fail "Command '$cmd_name' listed in manifest but missing"
                COMMANDS_OK=false
            fi
        done < "$COMMANDS_MANIFEST"
        if [ "$COMMANDS_CHECKED" -eq 0 ]; then
            fail "Commands manifest exists but is empty. Run agent-sync to regenerate."
        elif $COMMANDS_OK; then
            pass "All $COMMANDS_CHECKED manifest commands are deployed"
        fi
    else
        fail "Rules repo has commands but .agent-sync-commands-manifest not found. Run agent-sync."
    fi
else
    pass "No commands in rules repo (nothing to validate)"
fi

# --- 9. Worktrees.json deployment validation ---

echo ""
echo "[9/10] Worktrees.json deployment validation"

WORKTREES_TEMPLATE="$RULES_HOME/templates/worktrees.json"
WORKTREES_TARGET="$PROJECT_DIR/.cursor/worktrees.json"
WORKTREES_STAMP="$PROJECT_DIR/.cursor/.worktrees-agent-sync"

if [ -f "$WORKTREES_TEMPLATE" ]; then
    if [ -f "$WORKTREES_TARGET" ]; then
        # Validate JSON syntax
        if command -v python3 &>/dev/null; then
            if python3 -c "import json; json.load(open('$WORKTREES_TARGET'))" 2>/dev/null; then
                pass ".cursor/worktrees.json is valid JSON"
            else
                fail ".cursor/worktrees.json is NOT valid JSON"
            fi
        else
            warn "Cannot validate .cursor/worktrees.json syntax (python3 not available)"
        fi

        # If agent-sync managed, verify content matches template
        if [ -f "$WORKTREES_STAMP" ]; then
            if diff -q "$WORKTREES_TEMPLATE" "$WORKTREES_TARGET" >/dev/null 2>&1; then
                pass ".cursor/worktrees.json matches template (agent-sync managed)"
            else
                warn ".cursor/worktrees.json differs from template. Run agent-sync to update."
            fi
        else
            pass ".cursor/worktrees.json exists (user-managed)"
        fi
    else
        warn ".cursor/worktrees.json not found. Run agent-sync to deploy worktree setup."
    fi
else
    pass "No worktrees.json template in rules repo (nothing to validate)"
fi

# --- 10. .vscode/settings.json validity ---

echo ""
echo "[10/10] .vscode/settings.json validation"

VSCODE_SETTINGS="$PROJECT_DIR/.vscode/settings.json"
if [ -f "$VSCODE_SETTINGS" ]; then
    if command -v python3 &>/dev/null; then
        if python3 -c "import json; json.load(open('$VSCODE_SETTINGS'))" 2>/dev/null; then
            pass "$VSCODE_SETTINGS is valid JSON"
        else
            fail "$VSCODE_SETTINGS is NOT valid JSON — VS Code/Cursor may fail to load settings"
        fi
    elif command -v node &>/dev/null; then
        if node -e "JSON.parse(require('fs').readFileSync('$VSCODE_SETTINGS','utf8'))" 2>/dev/null; then
            pass "$VSCODE_SETTINGS is valid JSON (validated via node)"
        else
            fail "$VSCODE_SETTINGS is NOT valid JSON — VS Code/Cursor may fail to load settings"
        fi
    else
        warn "Cannot validate $VSCODE_SETTINGS (neither python3 nor node available)"
    fi
else
    pass ".vscode/settings.json not present (no validation needed)"
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
