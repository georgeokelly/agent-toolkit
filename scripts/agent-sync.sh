#!/usr/bin/env bash
set -euo pipefail

# Terminal colors (disabled when stdout is not a TTY, e.g., piped output)
if [ -t 1 ]; then
    _R='\033[0;31m' _Y='\033[0;33m' _G='\033[0;32m' _N='\033[0m'
else
    _R='' _Y='' _G='' _N=''
fi
_err()  { printf '%b%s%b\n' "$_R" "$*" "$_N"; }
_warn() { printf '%b%s%b\n' "$_Y" "$*" "$_N"; }
_ok()   { printf '%b%s%b\n' "$_G" "$*" "$_N"; }

# agent-sync.sh — Sync rules from central repo to project directory
# Usage: agent-sync.sh [subcommand] [project-dir]
#
# Environment:
#   AGENT_RULES_HOME  — path to central rules repo (default: ~/.config/agent-rules)

show_help() {
    cat <<'EOF'
agent-sync — Sync rules from central repo to project directory

USAGE
    agent-sync [project-dir]              Full sync (default)
    agent-sync codex [project-dir]        Only generate AGENTS.md
    agent-sync claude [project-dir]       Only generate CLAUDE.md
    agent-sync skills [project-dir]       Only sync skills to .cursor/skills/
    agent-sync commands [project-dir]     Only sync commands to .cursor/commands/
    agent-sync agents [project-dir]       Only sync agents to .cursor/agents/
    agent-sync clean [project-dir]        Remove all generated files
    agent-sync -h | --help                Show this help message

ARGUMENTS
    project-dir    Target project directory (default: current directory)

ENVIRONMENT
    AGENT_RULES_HOME   Path to central rules repo (default: ~/.config/agent-rules)

SUBCOMMANDS
    (default)   Full sync: generates Cursor .mdc files, CLAUDE.md, AGENTS.md,
                deploys .cursor/worktrees.json (if template exists),
                applies project overlays, handles sub-repo overlays, and
                cleans up root-level remnants. Skips if already up to date.

    codex       Only generate .agent-rules/AGENTS.md for Codex.
                Always regenerates (skips staleness check).

    claude      Only generate .agent-rules/CLAUDE.md for Claude Code (legacy).
                Always regenerates (skips staleness check).

    cc          Only generate all CC native files (.claude/rules/, skills/, commands/).
                Always regenerates (skips staleness check).

    cc-rules    Only generate .claude/rules/*.md for Claude Code.

    cc-skills   Only sync skills to .claude/skills/.

    skills      Only sync skills from $AGENT_RULES_HOME/skills/ to
                .cursor/skills/ in the target project (root only).

    commands    Only sync commands from $AGENT_RULES_HOME/commands/ to
                .cursor/commands/ in the target project (root only).

    agents      Only sync agent configs from $AGENT_RULES_HOME/agents/ to
                .cursor/agents/ in the target project (root only).

    clean       Remove all generated files:
                .cursor/rules/*.mdc, .cursor/skills/, .cursor/commands/, .cursor/agents/,
                .claude/rules/, .claude/skills/, .claude/commands/,
                .cursor/worktrees.json (if agent-sync managed),
                .agent-rules/, .agent-sync-hash, .agent-sync-manifest,
                and sub-repo CLAUDE.md/AGENTS.md.

EXAMPLES
    agent-sync                  # Full sync to current directory
    agent-sync ~/my-project     # Full sync to a specific project
    agent-sync codex .          # Regenerate only AGENTS.md
    agent-sync claude .         # Regenerate only CLAUDE.md (legacy)
    agent-sync cc .             # Regenerate all CC native files
    agent-sync clean            # Remove all generated files
EOF
    exit 0
}

# --- Parse arguments: detect subcommand, then project-dir ---

SUBCOMMAND="sync"
case "${1:-}" in
    -h|--help) show_help ;;
    codex|claude|cc|cc-rules|cc-skills|skills|commands|agents|clean)
        SUBCOMMAND="$1"
        shift
        ;;
esac

RULES_HOME="${AGENT_RULES_HOME:-$HOME/.config/agent-rules}"

strip_html_comments() {
    perl -0777 -pe 's/<!--.*?-->\n?//gs' 2>/dev/null \
        || python3 -c "
import re, sys
text = sys.stdin.read()
print(re.sub(r'<!--.*?-->\n?', '', text, flags=re.DOTALL), end='')
" 2>/dev/null \
        || cat  # fallback: pass through unchanged
}

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

HASH_FILE="$PROJECT_DIR/.agent-sync-hash"
MANIFEST="$PROJECT_DIR/.agent-sync-manifest"

# CC (Claude Code) manifest paths for native .claude/ outputs
CC_RULES_MANIFEST="$PROJECT_DIR/.claude/rules/.agent-sync-rules-manifest"
CC_SKILLS_MANIFEST="$PROJECT_DIR/.claude/skills/.agent-sync-skills-manifest"
CC_COMMANDS_MANIFEST="$PROJECT_DIR/.claude/commands/.agent-sync-commands-manifest"

# --- Validation ---

validate_rules_repo() {
    echo "Checking rules repo at $RULES_HOME ..."
    if [ ! -d "$RULES_HOME" ]; then
        _err "ERROR: Rules repo not found at $RULES_HOME"
        _err "  Set AGENT_RULES_HOME or create the directory."
        exit 1
    fi
    if [ ! -d "$RULES_HOME/core" ] || [ ! -d "$RULES_HOME/packs" ]; then
        _err "ERROR: Rules repo missing core/ or packs/ directory."
        exit 1
    fi
    # Initialize submodules (extras/) so their content is available; non-blocking on failure
    git -C "$RULES_HOME" submodule update --init --recursive --quiet >/dev/null 2>&1 || {
        _warn "  WARNING: Submodule init failed — extras/ will be skipped."
        _warn "           Likely cause: SSH key not configured for the submodule remote."
        _warn "           Fix: add your SSH key to the remote host, or use HTTPS URL in .gitmodules."
        _warn "           Debug: git -C \"$RULES_HOME\" submodule update --init --recursive"
    }
}

# --- Pack resolution ---

ACTIVE_PACKS=""

resolve_packs() {
    local default_packs="cpp cuda python markdown shell git"
    ACTIVE_PACKS="$default_packs"
    if [ -f "$PROJECT_DIR/.agent-local.md" ]; then
        local overlay_packs
        # Strip inline HTML comments left by project-overlay skill (e.g. <!-- [推断] ... -->)
        overlay_packs="$(sed -n 's/^\*\*Packs\*\*:[[:space:]]*//p' "$PROJECT_DIR/.agent-local.md" | head -1 | sed 's/<!--.*-->//')"
        if [ -n "$overlay_packs" ]; then
            ACTIVE_PACKS="$(echo "$overlay_packs" | tr ',' ' ' | xargs)"
        fi
    fi
    echo "  Active packs: $ACTIVE_PACKS"
}

pack_is_active() {
    local pack_name="$1"
    local p
    for p in $ACTIVE_PACKS; do
        [ "$p" = "$pack_name" ] && return 0
    done
    return 1
}

# --- CC Mode resolution ---
# CC Mode controls Claude Code native output generation:
#   off    — no .claude/ outputs (Cursor + legacy CLAUDE.md only)
#   dual   — both .claude/ native + legacy CLAUDE.md (default)
#   native — .claude/ native only, skip legacy CLAUDE.md/AGENTS.md

CC_MODE="dual"

resolve_cc_mode() {
    if [ -f "$PROJECT_DIR/.agent-local.md" ]; then
        local mode
        mode="$(sed -n 's/^\*\*CC Mode\*\*:[[:space:]]*//p' "$PROJECT_DIR/.agent-local.md" | head -1 | sed 's/<!--.*-->//' | xargs)"
        case "$mode" in
            off|dual|native) CC_MODE="$mode" ;;
            "") CC_MODE="dual" ;;
            *) _warn "  WARNING: Unknown CC Mode '$mode'. Defaulting to 'dual'."; CC_MODE="dual" ;;
        esac
    fi
    echo "  CC Mode: $CC_MODE"
}

# --- Staleness check (full sync only) ---

CURRENT_HASH=""

check_staleness() {
    echo "Computing staleness hash ..."

    local hash_cmd="shasum"
    command -v shasum &>/dev/null || hash_cmd="sha1sum"
    command -v $hash_cmd &>/dev/null || hash_cmd="md5sum"

    local rules_hash=""
    if [ -d "$RULES_HOME/.git" ]; then
        local sub_hash
        # Include each submodule's pinned commit so extras/ updates trigger re-sync
        sub_hash="$(git -C "$RULES_HOME" submodule status 2>/dev/null | awk '{print $1}' | tr -d '+-U' | sort | tr -d '\n')"
        rules_hash="$(git -C "$RULES_HOME" rev-parse HEAD 2>/dev/null || echo "no-git"):${sub_hash:-no-submodules}"
    else
        rules_hash="$(find "$RULES_HOME" \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \) -type f -exec "$hash_cmd" {} + 2>/dev/null | sort | "$hash_cmd" | awk '{print $1}')"
    fi

    # -maxdepth 3: intentional trade-off — .agent-local.md deeper than 3 levels is unsupported
    # to avoid costly full-tree traversal in large repos (build dirs, .venv, etc.)
    local overlay_hash
    overlay_hash="$(find "$PROJECT_DIR" -maxdepth 3 -name '.agent-local.md' -not -path '*/.git/*' -not -path '*/node_modules/*' -type f -exec "$hash_cmd" {} + 2>/dev/null | sort | "$hash_cmd" | awk '{print $1}')"

    # Include reviewer-models.conf so editing it triggers re-sync
    local reviewer_conf_hash=""
    if [ -f "$PROJECT_DIR/.cursor/reviewer-models.conf" ]; then
        reviewer_conf_hash="$("$hash_cmd" "$PROJECT_DIR/.cursor/reviewer-models.conf" 2>/dev/null | awk '{print $1}')"
    fi
    CURRENT_HASH="${rules_hash}:${overlay_hash}:${reviewer_conf_hash}"

    local stored_hash=""
    if [ -f "$HASH_FILE" ]; then
        stored_hash="$(cat "$HASH_FILE")"
    fi

    local cursor_exists=false claude_exists=false agents_exists=false skills_ok=true commands_ok=true cursor_agents_ok=true
    [ -d "$PROJECT_DIR/.cursor/rules" ] && [ "$(ls -A "$PROJECT_DIR/.cursor/rules/" 2>/dev/null)" ] && cursor_exists=true
    [ -f "$PROJECT_DIR/.agent-rules/CLAUDE.md" ] && claude_exists=true
    [ -f "$PROJECT_DIR/.agent-rules/AGENTS.md" ] && agents_exists=true
    # If rules repo has skills (core or extras), ensure they are all deployed
    if [ -f "$SKILLS_MANIFEST" ]; then
        local expected_skill actual_skill
        # Check core skills
        for expected_skill in "$RULES_HOME/skills"/*/; do
            [ -d "$expected_skill" ] || continue
            grep -qx "$(basename "$expected_skill")" "$SKILLS_MANIFEST" 2>/dev/null || { skills_ok=false; break; }
        done
        # Check extras skills
        if $skills_ok && [ -d "$RULES_HOME/extras" ]; then
            local extras_dir
            for extras_dir in "$RULES_HOME/extras"/*/; do
                [ -d "$extras_dir/skills" ] || continue
                for expected_skill in "$extras_dir/skills"/*/; do
                    [ -d "$expected_skill" ] || continue
                    grep -qx "$(basename "$expected_skill")" "$SKILLS_MANIFEST" 2>/dev/null || { skills_ok=false; break 2; }
                done
            done
        fi
    else
        # No manifest at all — need sync if any skills exist
        if [ "$(ls -d "$RULES_HOME/skills/"*/ 2>/dev/null)" ]; then
            skills_ok=false
        elif [ -d "$RULES_HOME/extras" ]; then
            local extras_dir
            for extras_dir in "$RULES_HOME/extras"/*/; do
                [ "$(ls -d "${extras_dir}skills/"*/ 2>/dev/null)" ] && { skills_ok=false; break; }
            done
        fi
    fi
    # If rules repo has commands, ensure they are deployed
    if [ -d "$RULES_HOME/commands" ] && [ "$(ls "$RULES_HOME/commands/"*.md 2>/dev/null)" ]; then
        [ -f "$COMMANDS_MANIFEST" ] || commands_ok=false
    fi
    # If rules repo has agents, ensure they are deployed
    if [ -d "$RULES_HOME/agents" ] && [ "$(ls "$RULES_HOME/agents/"*.md 2>/dev/null)" ]; then
        [ -f "$CURSOR_AGENTS_MANIFEST" ] || cursor_agents_ok=false
    fi

    # CC native artifacts: require .claude/rules/ when CC Mode is not off
    local cc_rules_ok=true
    if [ "$CC_MODE" != "off" ]; then
        [ -d "$PROJECT_DIR/.claude/rules" ] && [ -n "$(ls "$PROJECT_DIR/.claude/rules/"*.md 2>/dev/null)" ] || cc_rules_ok=false
    fi

    if [ "$CURRENT_HASH" = "$stored_hash" ] && $cursor_exists && $claude_exists && $agents_exists && $skills_ok && $commands_ok && $cursor_agents_ok && $cc_rules_ok; then
        _ok "Rules up to date. No sync needed."
        exit 0
    fi
}

# --- Generation functions ---

generate_cursor() {
    mkdir -p "$PROJECT_DIR/.cursor/rules"
    local frontmatter_dir="$RULES_HOME/templates/cursor-frontmatter"

    local rule_file basename_no_ext lookup_name target
    for rule_file in "$RULES_HOME"/core/*.md "$RULES_HOME"/packs/*.md; do
        [ -f "$rule_file" ] || continue
        basename_no_ext="$(basename "$rule_file" .md)"
        # Strip numeric prefix for frontmatter lookup (00-communication → communication)
        lookup_name="$(echo "$basename_no_ext" | sed 's/^[0-9]*-//')"
        target="$PROJECT_DIR/.cursor/rules/${basename_no_ext}.mdc"

        echo "---" > "$target"
        if [ -f "$frontmatter_dir/${lookup_name}.yaml" ]; then
            cat "$frontmatter_dir/${lookup_name}.yaml" >> "$target"
        else
            echo "description: ${lookup_name} rules" >> "$target"
            echo "alwaysApply: false" >> "$target"
        fi
        echo "---" >> "$target"
        echo "" >> "$target"
        cat "$rule_file" >> "$target"
    done

    # Project overlay as a separate always-apply .mdc
    if [ -f "$PROJECT_DIR/.agent-local.md" ]; then
        target="$PROJECT_DIR/.cursor/rules/project-overlay.mdc"
        echo "---" > "$target"
        echo "description: Project-specific rules and constraints" >> "$target"
        echo "alwaysApply: true" >> "$target"
        echo "---" >> "$target"
        echo "" >> "$target"
        strip_html_comments < "$PROJECT_DIR/.agent-local.md" >> "$target"
    else
        rm -f "$PROJECT_DIR/.cursor/rules/project-overlay.mdc"
        _warn "  NOTE: No .agent-local.md found. Project overlay skipped."
        _warn "        Create one manually: cp \$AGENT_RULES_HOME/templates/overlay-template.md .agent-local.md"
        _warn "        Or ask your AI agent to run the \"project-overlay\" skill for guided setup."
    fi

    echo "  Cursor: $(ls "$PROJECT_DIR/.cursor/rules/"*.mdc 2>/dev/null | wc -l | tr -d ' ') .mdc files"
}

# Generate CC-native .claude/rules/*.md files.
# Rule categories:
#   A (always-on): core rules with alwaysApply — no frontmatter in CC (always loaded)
#   B (path-scoped): packs with globs — CC uses paths: YAML list from cc-frontmatter/
#   C (description-only): packs with only description — always-on in CC (no CC equivalent)
#   D (Cursor-only): review-criteria — skipped entirely
generate_cc_rules() {
    mkdir -p "$PROJECT_DIR/.claude/rules"

    local cc_fm_dir="$RULES_HOME/templates/cc-frontmatter"
    local manifest_new="${CC_RULES_MANIFEST}.new"
    : > "$manifest_new"

    local rule_file basename_no_ext lookup_name target count=0
    for rule_file in "$RULES_HOME"/core/*.md "$RULES_HOME"/packs/*.md; do
        [ -f "$rule_file" ] || continue
        basename_no_ext="$(basename "$rule_file" .md)"
        # D-class: skip review-criteria (Cursor-only reviewer workflow)
        [[ "$basename_no_ext" == *review-criteria* ]] && continue

        lookup_name="$(echo "$basename_no_ext" | sed 's/^[0-9]*-//')"
        target="$PROJECT_DIR/.claude/rules/${basename_no_ext}.md"

        # B-class rules have a cc-frontmatter file with paths:
        # A/C-class rules have no cc-frontmatter file → no frontmatter = always loaded
        if [ -f "$cc_fm_dir/${lookup_name}.yaml" ]; then
            echo "---" > "$target"
            cat "$cc_fm_dir/${lookup_name}.yaml" >> "$target"
            echo "---" >> "$target"
            echo "" >> "$target"
        else
            : > "$target"
        fi
        cat "$rule_file" >> "$target"

        echo "${basename_no_ext}.md" >> "$manifest_new"
        count=$((count + 1))
    done

    # Project overlay as an always-on CC rule (no paths frontmatter)
    if [ -f "$PROJECT_DIR/.agent-local.md" ]; then
        target="$PROJECT_DIR/.claude/rules/project-overlay.md"
        strip_html_comments < "$PROJECT_DIR/.agent-local.md" > "$target"
        echo "project-overlay.md" >> "$manifest_new"
        count=$((count + 1))
    fi

    # Remove CC rules that were previously synced but no longer exist
    if [ -f "$CC_RULES_MANIFEST" ]; then
        local old_rule
        while IFS= read -r old_rule; do
            [ -z "$old_rule" ] && continue
            if ! grep -qx "$old_rule" "$manifest_new" 2>/dev/null; then
                rm -f "$PROJECT_DIR/.claude/rules/$old_rule"
                echo "  Removed stale CC rule: $old_rule"
            fi
        done < "$CC_RULES_MANIFEST"
    fi

    mv "$manifest_new" "$CC_RULES_MANIFEST"
    echo "  CC Rules: $count .md files in .claude/rules/"
}

# Deploy skills from $RULES_HOME/skills/ to project root .cursor/skills/ (depth=0 only)
# Uses manifest for precise cleanup; convergent sync (rm + cp) to avoid stale files.
SKILLS_MANIFEST="$PROJECT_DIR/.cursor/skills/.agent-sync-skills-manifest"

generate_skills() {
    local skills_src="$RULES_HOME/skills"
    [ -d "$skills_src" ] || return 0

    local skill_dir skill_name target_dir
    local count=0
    local manifest_new="${SKILLS_MANIFEST}.new"
    mkdir -p "$PROJECT_DIR/.cursor/skills"
    : > "$manifest_new"

    for skill_dir in "$skills_src"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name="$(basename "$skill_dir")"
        target_dir="$PROJECT_DIR/.cursor/skills/$skill_name"
        # Convergent sync: clean target then copy fresh
        rm -rf "$target_dir"
        mkdir -p "$target_dir"
        if [ -n "$(ls -A "$skill_dir" 2>/dev/null)" ]; then
            cp -a "$skill_dir/." "$target_dir/"
        fi
        echo "$skill_name" >> "$manifest_new"
        count=$((count + 1))
    done

    # Deploy skills from extras/ — core takes priority; skip extras duplicates
    if [ -d "$RULES_HOME/extras" ]; then
        local extras_dir bundle_name
        for extras_dir in "$RULES_HOME/extras"/*/; do
            [ -d "$extras_dir/skills" ] || continue
            bundle_name="$(basename "$extras_dir")"
            for skill_dir in "$extras_dir/skills"/*/; do
                [ -d "$skill_dir" ] || continue
                skill_name="$(basename "$skill_dir")"
                # Core always wins — skip extras duplicate
                if [ -d "$skills_src/$skill_name" ]; then
                    _warn "  SKIP: extras/$bundle_name skill '$skill_name' — same name exists in core (core wins)"
                    _warn "        To use both, create a renamed symlink in the extras bundle."
                    continue
                fi
                target_dir="$PROJECT_DIR/.cursor/skills/$skill_name"
                rm -rf "$target_dir"
                mkdir -p "$target_dir"
                if [ -n "$(ls -A "$skill_dir" 2>/dev/null)" ]; then
                    cp -a "$skill_dir/." "$target_dir/"
                fi
                echo "$skill_name" >> "$manifest_new"
                count=$((count + 1))
            done
        done
    fi

    # Remove skills that were previously synced but no longer exist in any source (core or extras)
    if [ -f "$SKILLS_MANIFEST" ]; then
        local old_skill found extras_dir
        while IFS= read -r old_skill; do
            [ -z "$old_skill" ] && continue
            found=false
            [ -d "$skills_src/$old_skill" ] && found=true
            if ! $found && [ -d "$RULES_HOME/extras" ]; then
                for extras_dir in "$RULES_HOME/extras"/*/; do
                    [ -d "${extras_dir}skills/$old_skill" ] && found=true && break
                done
            fi
            if ! $found; then
                rm -rf "$PROJECT_DIR/.cursor/skills/$old_skill"
                echo "  Removed stale skill: $old_skill"
            fi
        done < "$SKILLS_MANIFEST"
    fi

    mv "$manifest_new" "$SKILLS_MANIFEST"
    echo "  Skills: $count skill(s) synced to .cursor/skills/"
}

# Deploy commands from $RULES_HOME/commands/ to project root .cursor/commands/
# Commands are flat .md files (not directories like skills).
# Uses manifest for precise cleanup; convergent sync to avoid stale files.
COMMANDS_MANIFEST="$PROJECT_DIR/.cursor/commands/.agent-sync-commands-manifest"
CURSOR_AGENTS_MANIFEST="$PROJECT_DIR/.cursor/agents/.agent-sync-agents-manifest"

generate_commands() {
    local commands_src="$RULES_HOME/commands"
    [ -d "$commands_src" ] || return 0

    local cmd_file cmd_name
    local count=0
    local manifest_new="${COMMANDS_MANIFEST}.new"
    mkdir -p "$PROJECT_DIR/.cursor/commands"
    : > "$manifest_new"

    for cmd_file in "$commands_src"/*.md; do
        [ -f "$cmd_file" ] || continue
        cmd_name="$(basename "$cmd_file")"
        cp "$cmd_file" "$PROJECT_DIR/.cursor/commands/$cmd_name"
        echo "$cmd_name" >> "$manifest_new"
        count=$((count + 1))
    done

    # Deploy commands from extras/ — core takes priority; skip extras duplicates
    if [ -d "$RULES_HOME/extras" ]; then
        local extras_dir bundle_name
        for extras_dir in "$RULES_HOME/extras"/*/; do
            [ -d "$extras_dir/commands" ] || continue
            bundle_name="$(basename "$extras_dir")"
            for cmd_file in "$extras_dir/commands"/*.md; do
                [ -f "$cmd_file" ] || continue
                cmd_name="$(basename "$cmd_file")"
                # Core always wins — skip extras duplicate
                if [ -f "$commands_src/$cmd_name" ]; then
                    _warn "  SKIP: extras/$bundle_name command '$cmd_name' — same name exists in core (core wins)"
                    _warn "        To use both, create a renamed copy or symlink in the extras bundle."
                    continue
                fi
                cp "$cmd_file" "$PROJECT_DIR/.cursor/commands/$cmd_name"
                echo "$cmd_name" >> "$manifest_new"
                count=$((count + 1))
            done
        done
    fi

    # Remove commands that were previously synced but no longer exist in any source (core or extras)
    if [ -f "$COMMANDS_MANIFEST" ]; then
        local old_cmd found extras_dir
        while IFS= read -r old_cmd; do
            [ -z "$old_cmd" ] && continue
            found=false
            [ -f "$commands_src/$old_cmd" ] && found=true
            if ! $found && [ -d "$RULES_HOME/extras" ]; then
                for extras_dir in "$RULES_HOME/extras"/*/; do
                    [ -f "${extras_dir}commands/$old_cmd" ] && found=true && break
                done
            fi
            if ! $found; then
                rm -f "$PROJECT_DIR/.cursor/commands/$old_cmd"
                echo "  Removed stale command: $old_cmd"
            fi
        done < "$COMMANDS_MANIFEST"
    fi

    mv "$manifest_new" "$COMMANDS_MANIFEST"
    echo "  Commands: $count command(s) synced to .cursor/commands/"
}

# Deploy skills to .claude/skills/ (CC native, mirrors generate_skills for Cursor).
generate_cc_skills() {
    local skills_src="$RULES_HOME/skills"
    [ -d "$skills_src" ] || return 0

    local skill_dir skill_name target_dir
    local count=0
    local manifest_new="${CC_SKILLS_MANIFEST}.new"
    mkdir -p "$PROJECT_DIR/.claude/skills"
    : > "$manifest_new"

    for skill_dir in "$skills_src"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name="$(basename "$skill_dir")"
        target_dir="$PROJECT_DIR/.claude/skills/$skill_name"
        rm -rf "$target_dir"
        mkdir -p "$target_dir"
        if [ -n "$(ls -A "$skill_dir" 2>/dev/null)" ]; then
            cp -a "$skill_dir/." "$target_dir/"
        fi
        echo "$skill_name" >> "$manifest_new"
        count=$((count + 1))
    done

    # Deploy skills from extras/ — core takes priority
    if [ -d "$RULES_HOME/extras" ]; then
        local extras_dir bundle_name
        for extras_dir in "$RULES_HOME/extras"/*/; do
            [ -d "$extras_dir/skills" ] || continue
            bundle_name="$(basename "$extras_dir")"
            for skill_dir in "$extras_dir/skills"/*/; do
                [ -d "$skill_dir" ] || continue
                skill_name="$(basename "$skill_dir")"
                if [ -d "$skills_src/$skill_name" ]; then
                    continue
                fi
                target_dir="$PROJECT_DIR/.claude/skills/$skill_name"
                rm -rf "$target_dir"
                mkdir -p "$target_dir"
                if [ -n "$(ls -A "$skill_dir" 2>/dev/null)" ]; then
                    cp -a "$skill_dir/." "$target_dir/"
                fi
                echo "$skill_name" >> "$manifest_new"
                count=$((count + 1))
            done
        done
    fi

    # Remove skills previously synced but no longer in any source
    if [ -f "$CC_SKILLS_MANIFEST" ]; then
        local old_skill found extras_dir
        while IFS= read -r old_skill; do
            [ -z "$old_skill" ] && continue
            found=false
            [ -d "$skills_src/$old_skill" ] && found=true
            if ! $found && [ -d "$RULES_HOME/extras" ]; then
                for extras_dir in "$RULES_HOME/extras"/*/; do
                    [ -d "${extras_dir}skills/$old_skill" ] && found=true && break
                done
            fi
            if ! $found; then
                rm -rf "$PROJECT_DIR/.claude/skills/$old_skill"
                echo "  Removed stale CC skill: $old_skill"
            fi
        done < "$CC_SKILLS_MANIFEST"
    fi

    mv "$manifest_new" "$CC_SKILLS_MANIFEST"
    echo "  CC Skills: $count skill(s) synced to .claude/skills/"
}

# Deploy commands to .claude/commands/ (CC legacy compatibility surface).
generate_cc_commands() {
    local commands_src="$RULES_HOME/commands"
    [ -d "$commands_src" ] || return 0

    local cmd_file cmd_name
    local count=0
    local manifest_new="${CC_COMMANDS_MANIFEST}.new"
    mkdir -p "$PROJECT_DIR/.claude/commands"
    : > "$manifest_new"

    for cmd_file in "$commands_src"/*.md; do
        [ -f "$cmd_file" ] || continue
        cmd_name="$(basename "$cmd_file")"
        cp "$cmd_file" "$PROJECT_DIR/.claude/commands/$cmd_name"
        echo "$cmd_name" >> "$manifest_new"
        count=$((count + 1))
    done

    # Deploy commands from extras/ — core takes priority
    if [ -d "$RULES_HOME/extras" ]; then
        local extras_dir bundle_name
        for extras_dir in "$RULES_HOME/extras"/*/; do
            [ -d "$extras_dir/commands" ] || continue
            bundle_name="$(basename "$extras_dir")"
            for cmd_file in "$extras_dir/commands"/*.md; do
                [ -f "$cmd_file" ] || continue
                cmd_name="$(basename "$cmd_file")"
                if [ -f "$commands_src/$cmd_name" ]; then
                    continue
                fi
                cp "$cmd_file" "$PROJECT_DIR/.claude/commands/$cmd_name"
                echo "$cmd_name" >> "$manifest_new"
                count=$((count + 1))
            done
        done
    fi

    # Remove commands previously synced but no longer in any source
    if [ -f "$CC_COMMANDS_MANIFEST" ]; then
        local old_cmd found extras_dir
        while IFS= read -r old_cmd; do
            [ -z "$old_cmd" ] && continue
            found=false
            [ -f "$commands_src/$old_cmd" ] && found=true
            if ! $found && [ -d "$RULES_HOME/extras" ]; then
                for extras_dir in "$RULES_HOME/extras"/*/; do
                    [ -f "${extras_dir}commands/$old_cmd" ] && found=true && break
                done
            fi
            if ! $found; then
                rm -f "$PROJECT_DIR/.claude/commands/$old_cmd"
                echo "  Removed stale CC command: $old_cmd"
            fi
        done < "$CC_COMMANDS_MANIFEST"
    fi

    mv "$manifest_new" "$CC_COMMANDS_MANIFEST"
    echo "  CC Commands: $count command(s) → .claude/commands/ (CC legacy — consider migrating to skills)"
}

# Deploy agent configs from $RULES_HOME/agents/ to project root .cursor/agents/
# Agent configs are .md files with YAML frontmatter (name, model, readonly, etc.).
# Uses manifest for precise cleanup; convergent sync to avoid stale files.

generate_cursor_agents() {
    local agents_src="$RULES_HOME/agents"
    [ -d "$agents_src" ] || return 0

    local agent_file agent_name
    local count=0
    local manifest_new="${CURSOR_AGENTS_MANIFEST}.new"
    mkdir -p "$PROJECT_DIR/.cursor/agents"
    : > "$manifest_new"

    for agent_file in "$agents_src"/*.md; do
        [ -f "$agent_file" ] || continue
        agent_name="$(basename "$agent_file")"
        cp "$agent_file" "$PROJECT_DIR/.cursor/agents/$agent_name"
        echo "$agent_name" >> "$manifest_new"
        count=$((count + 1))
    done

    # Deploy agents from extras/ — core takes priority; skip extras duplicates
    if [ -d "$RULES_HOME/extras" ]; then
        local extras_dir bundle_name
        for extras_dir in "$RULES_HOME/extras"/*/; do
            [ -d "$extras_dir/agents" ] || continue
            bundle_name="$(basename "$extras_dir")"
            for agent_file in "$extras_dir/agents"/*.md; do
                [ -f "$agent_file" ] || continue
                agent_name="$(basename "$agent_file")"
                if [ -f "$agents_src/$agent_name" ]; then
                    _warn "  SKIP: extras/$bundle_name agent '$agent_name' — same name exists in core (core wins)"
                    _warn "        To use both, create a renamed copy or symlink in the extras bundle."
                    continue
                fi
                cp "$agent_file" "$PROJECT_DIR/.cursor/agents/$agent_name"
                echo "$agent_name" >> "$manifest_new"
                count=$((count + 1))
            done
        done
    fi

    # Remove agents that were previously synced but no longer exist in any source
    if [ -f "$CURSOR_AGENTS_MANIFEST" ]; then
        local old_agent found extras_dir
        while IFS= read -r old_agent; do
            [ -z "$old_agent" ] && continue
            found=false
            [ -f "$agents_src/$old_agent" ] && found=true
            if ! $found && [ -d "$RULES_HOME/extras" ]; then
                for extras_dir in "$RULES_HOME/extras"/*/; do
                    [ -f "${extras_dir}agents/$old_agent" ] && found=true && break
                done
            fi
            if ! $found; then
                rm -f "$PROJECT_DIR/.cursor/agents/$old_agent"
                echo "  Removed stale agent: $old_agent"
            fi
        done < "$CURSOR_AGENTS_MANIFEST"
    fi

    mv "$manifest_new" "$CURSOR_AGENTS_MANIFEST"
    echo "  Agents: $count agent(s) synced to .cursor/agents/"
}

# Deploy .cursor/reviewer-models.conf from template (skip if user has a custom version).
# Uses a sidecar stamp file to track ownership — conf has comments but no ownership marker.
REVIEWER_CONF_TEMPLATE="$RULES_HOME/templates/reviewer-models.conf"
REVIEWER_CONF_TARGET="$PROJECT_DIR/.cursor/reviewer-models.conf"
REVIEWER_CONF_STAMP="$PROJECT_DIR/.cursor/.reviewer-models-agent-sync"

deploy_reviewer_models_conf() {
    [ -f "$REVIEWER_CONF_TEMPLATE" ] || return 0
    mkdir -p "$PROJECT_DIR/.cursor"

    if [ -f "$REVIEWER_CONF_TARGET" ] && [ ! -f "$REVIEWER_CONF_STAMP" ]; then
        _warn "  SKIP: .cursor/reviewer-models.conf exists and is not managed by agent-sync."
        _warn "        To let agent-sync manage it, delete it and re-run."
        return 0
    fi

    [ -f "$REVIEWER_CONF_TARGET" ] && [ ! -w "$REVIEWER_CONF_TARGET" ] && rm -f "$REVIEWER_CONF_TARGET"
    cp "$REVIEWER_CONF_TEMPLATE" "$REVIEWER_CONF_TARGET"
    touch "$REVIEWER_CONF_STAMP"
    echo "  Reviewer models: .cursor/reviewer-models.conf deployed"
}

# Generate model-specific reviewer sub-agent variants.
# Delegates to generate-reviewers.sh which reads .cursor/reviewer-models.conf.
REVIEWER_VARIANTS_MANIFEST="$PROJECT_DIR/.cursor/agents/.generated-reviewers-manifest"

generate_reviewer_variants() {
    local gen_script="$RULES_HOME/scripts/generate-reviewers.sh"
    if [ ! -x "$gen_script" ]; then
        return 0
    fi

    local conf_file="$PROJECT_DIR/.cursor/reviewer-models.conf"
    if [ ! -f "$conf_file" ] && [ ! -f "$REVIEWER_VARIANTS_MANIFEST" ]; then
        return 0
    fi

    AGENT_RULES_HOME="$RULES_HOME" "$gen_script" "$PROJECT_DIR"
}

# Deploy .cursor/worktrees.json from template (skip if user has a custom version).
# Uses a sidecar stamp file to track ownership — JSON has no comment syntax.
WORKTREES_TEMPLATE="$RULES_HOME/templates/worktrees.json"
WORKTREES_TARGET="$PROJECT_DIR/.cursor/worktrees.json"
WORKTREES_STAMP="$PROJECT_DIR/.cursor/.worktrees-agent-sync"

generate_worktrees() {
    [ -f "$WORKTREES_TEMPLATE" ] || return 0
    mkdir -p "$PROJECT_DIR/.cursor"

    if [ -f "$WORKTREES_TARGET" ] && [ ! -f "$WORKTREES_STAMP" ]; then
        _warn "  SKIP: .cursor/worktrees.json exists and is not managed by agent-sync."
        _warn "        To let agent-sync manage it, delete it and re-run."
        return 0
    fi

    [ -f "$WORKTREES_TARGET" ] && [ ! -w "$WORKTREES_TARGET" ] && rm -f "$WORKTREES_TARGET"
    cp "$WORKTREES_TEMPLATE" "$WORKTREES_TARGET"
    touch "$WORKTREES_STAMP"
    echo "  Worktrees: .cursor/worktrees.json deployed"
}

generate_claude() {
    mkdir -p "$PROJECT_DIR/.agent-rules"
    local claude_file="$PROJECT_DIR/.agent-rules/CLAUDE.md"
    echo "<!-- Auto-generated by agent-sync. Do not edit manually. -->" > "$claude_file"
    echo "" >> "$claude_file"

    local rule_file pack_name basename_no_ext
    for rule_file in "$RULES_HOME"/core/*.md; do
        [ -f "$rule_file" ] || continue
        # Skip review-criteria — it contains reviewer-only constraints (readonly mode)
        # that should not leak into normal Claude/Codex sessions.
        # Cursor scopes it via globs in review-criteria.yaml; Claude/Codex have no equivalent.
        basename_no_ext="$(basename "$rule_file" .md)"
        [[ "$basename_no_ext" == *review-criteria* ]] && continue
        cat "$rule_file" >> "$claude_file"
        echo "" >> "$claude_file"
        echo "---" >> "$claude_file"
        echo "" >> "$claude_file"
    done

    for rule_file in "$RULES_HOME"/packs/*.md; do
        [ -f "$rule_file" ] || continue
        pack_name="$(basename "$rule_file" .md)"
        pack_is_active "$pack_name" || continue
        cat "$rule_file" >> "$claude_file"
        echo "" >> "$claude_file"
        echo "---" >> "$claude_file"
        echo "" >> "$claude_file"
    done

    if [ -f "$PROJECT_DIR/.agent-local.md" ]; then
        strip_html_comments < "$PROJECT_DIR/.agent-local.md" >> "$claude_file"
        echo "" >> "$claude_file"
    fi

    echo "  Claude Code: CLAUDE.md ($(wc -c < "$claude_file" | tr -d ' ') bytes)"
}

generate_codex() {
    mkdir -p "$PROJECT_DIR/.agent-rules"

    # AGENTS.md is derived from CLAUDE.md; always regenerate to avoid stale content
    generate_claude

    cp "$PROJECT_DIR/.agent-rules/CLAUDE.md" "$PROJECT_DIR/.agent-rules/AGENTS.md"
    # Portable in-place edit: write to temp file then replace (avoids GNU vs BSD sed -i divergence)
    local tmp_agents
    tmp_agents="$(mktemp)"
    sed '1s/.*<!-- Auto-generated.*/<!-- Auto-generated by agent-sync for Codex. Do not edit manually. -->/' \
        "$PROJECT_DIR/.agent-rules/AGENTS.md" > "$tmp_agents" 2>/dev/null \
        && mv "$tmp_agents" "$PROJECT_DIR/.agent-rules/AGENTS.md" \
        || rm -f "$tmp_agents"

    local agents_size
    agents_size=$(wc -c < "$PROJECT_DIR/.agent-rules/AGENTS.md" | tr -d ' ')
    echo "  Codex: AGENTS.md ($agents_size bytes)"
    if [ "$agents_size" -gt 32768 ]; then
        _warn "  WARNING: AGENTS.md exceeds 32KiB ($agents_size bytes). Codex may silently truncate!"
    fi
}

cleanup_remnants() {
    rm -f "$PROJECT_DIR/CLAUDE.md" "$PROJECT_DIR/AGENTS.md"
}

sync_sub_repos() {
    local manifest_new="$MANIFEST.new"
    : > "$manifest_new"

    # -maxdepth 3: matches check_staleness depth — overlays deeper than 3 levels are unsupported
    local sub_overlay sub_dir sub_rel sub_claude mdc_name mdc_target
    find "$PROJECT_DIR" -mindepth 2 -maxdepth 3 -name '.agent-local.md' -not -path '*/.git/*' -not -path '*/node_modules/*' | while read -r sub_overlay; do
        sub_dir="$(dirname "$sub_overlay")"
        sub_rel="${sub_dir#"$PROJECT_DIR"/}"

        sub_claude="$sub_dir/CLAUDE.md"
        echo "<!-- Auto-generated by agent-sync (sub-repo overlay only). Do not edit manually. -->" > "$sub_claude"
        echo "" >> "$sub_claude"
        strip_html_comments < "$sub_overlay" >> "$sub_claude"

        cp "$sub_claude" "$sub_dir/AGENTS.md"

        # Generate a globs-scoped .mdc so Cursor loads this overlay only when editing files
        # under the sub-repo directory — avoids paying token cost for unrelated contexts.
        mdc_name="$(echo "$sub_rel" | tr '/' '-')-overlay.mdc"
        mdc_target="$PROJECT_DIR/.cursor/rules/$mdc_name"
        {
            echo "---"
            echo "description: ${sub_rel} project overlay"
            echo "globs: ${sub_rel}/**"
            echo "alwaysApply: false"
            echo "---"
            echo ""
            strip_html_comments < "$sub_overlay"
        } > "$mdc_target"

        # CC native: generate a paths-scoped rule at project root .claude/rules/
        if [ "$CC_MODE" != "off" ]; then
            local cc_overlay_name="$(echo "$sub_rel" | tr '/' '-')-overlay.md"
            local cc_overlay_target="$PROJECT_DIR/.claude/rules/$cc_overlay_name"
            {
                echo "---"
                echo "paths:"
                echo "  - \"${sub_rel}/**\""
                echo "---"
                echo ""
                strip_html_comments < "$sub_overlay"
            } > "$cc_overlay_target"
        fi

        echo "$sub_rel" >> "$manifest_new"
        echo "  Sub-repo $sub_rel: CLAUDE.md + AGENTS.md + ${mdc_name} (overlay only, $(wc -c < "$sub_claude" | tr -d ' ') bytes)"
    done

    # Clean up ghost rule files from deleted sub-repo overlays
    if [ -f "$MANIFEST" ]; then
        local old_rel ghost_mdc ghost_cc
        while IFS= read -r old_rel; do
            if [ ! -f "$PROJECT_DIR/$old_rel/.agent-local.md" ]; then
                rm -f "$PROJECT_DIR/$old_rel/CLAUDE.md" "$PROJECT_DIR/$old_rel/AGENTS.md"
                ghost_mdc="$(echo "$old_rel" | tr '/' '-')-overlay.mdc"
                rm -f "$PROJECT_DIR/.cursor/rules/$ghost_mdc"
                ghost_cc="$(echo "$old_rel" | tr '/' '-')-overlay.md"
                rm -f "$PROJECT_DIR/.claude/rules/$ghost_cc"
                echo "  Cleaned ghost rules: $old_rel/ (overlay removed)"
            fi
        done < "$MANIFEST"
    fi
    mv "$manifest_new" "$MANIFEST"
}

store_hash() {
    echo "$CURRENT_HASH" > "$HASH_FILE"
}

# --- Clean subcommand ---

do_clean() {
    echo "Cleaning generated files in $PROJECT_DIR ..."

    if [ -d "$PROJECT_DIR/.cursor/rules" ]; then
        rm -f "$PROJECT_DIR/.cursor/rules/"*.mdc
        rmdir "$PROJECT_DIR/.cursor/rules" 2>/dev/null || true
        echo "  Removed .cursor/rules/*.mdc"
    fi

    # Clean only agent-sync managed skills (manifest-based)
    if [ -f "$SKILLS_MANIFEST" ]; then
        local old_skill
        while IFS= read -r old_skill; do
            [ -z "$old_skill" ] && continue
            rm -rf "$PROJECT_DIR/.cursor/skills/$old_skill"
        done < "$SKILLS_MANIFEST"
        rm -f "$SKILLS_MANIFEST"
        rmdir "$PROJECT_DIR/.cursor/skills" 2>/dev/null || true
        echo "  Removed agent-sync managed skills"
    elif [ -d "$PROJECT_DIR/.cursor/skills" ]; then
        _warn "  WARNING: .cursor/skills/ exists but no manifest found."
        _warn "           Cannot determine which skills were managed by agent-sync."
        _warn "           Run 'agent-sync .' to regenerate manifest, then 'agent-sync clean' to retry."
    fi

    # Clean only agent-sync managed commands (manifest-based)
    if [ -f "$COMMANDS_MANIFEST" ]; then
        local old_cmd
        while IFS= read -r old_cmd; do
            [ -z "$old_cmd" ] && continue
            rm -f "$PROJECT_DIR/.cursor/commands/$old_cmd"
        done < "$COMMANDS_MANIFEST"
        rm -f "$COMMANDS_MANIFEST"
        rmdir "$PROJECT_DIR/.cursor/commands" 2>/dev/null || true
        echo "  Removed agent-sync managed commands"
    elif [ -d "$PROJECT_DIR/.cursor/commands" ]; then
        _warn "  WARNING: .cursor/commands/ exists but no manifest found."
        _warn "           Cannot determine which commands were managed by agent-sync."
        _warn "           Run 'agent-sync .' to regenerate manifest, then 'agent-sync clean' to retry."
    fi

    # Clean generated reviewer variants (from generate-reviewers.sh)
    if [ -f "$REVIEWER_VARIANTS_MANIFEST" ]; then
        local rv_entry rv_file
        while IFS= read -r rv_entry; do
            [ -z "$rv_entry" ] && continue
            rv_file="$(echo "$rv_entry" | cut -d'|' -f1)"
            rm -f "$PROJECT_DIR/.cursor/agents/$rv_file"
        done < "$REVIEWER_VARIANTS_MANIFEST"
        rm -f "$REVIEWER_VARIANTS_MANIFEST"
        echo "  Removed generated reviewer variants"
    fi

    # Clean only agent-sync managed agents (manifest-based)
    if [ -f "$CURSOR_AGENTS_MANIFEST" ]; then
        local old_agent
        while IFS= read -r old_agent; do
            [ -z "$old_agent" ] && continue
            rm -f "$PROJECT_DIR/.cursor/agents/$old_agent"
        done < "$CURSOR_AGENTS_MANIFEST"
        rm -f "$CURSOR_AGENTS_MANIFEST"
        rmdir "$PROJECT_DIR/.cursor/agents" 2>/dev/null || true
        echo "  Removed agent-sync managed agents"
    elif [ -d "$PROJECT_DIR/.cursor/agents" ]; then
        _warn "  WARNING: .cursor/agents/ exists but no manifest found."
        _warn "           Cannot determine which agents were managed by agent-sync."
        _warn "           Run 'agent-sync .' to regenerate manifest, then 'agent-sync clean' to retry."
    fi

    # Clean reviewer-models.conf only if agent-sync owns it
    if [ -f "$REVIEWER_CONF_STAMP" ]; then
        rm -f "$REVIEWER_CONF_TARGET"
        rm -f "$REVIEWER_CONF_STAMP"
        echo "  Removed .cursor/reviewer-models.conf (agent-sync managed)"
    elif [ -f "$REVIEWER_CONF_TARGET" ]; then
        _warn "  SKIP: .cursor/reviewer-models.conf is not managed by agent-sync — left intact."
    fi

    # Clean worktrees.json only if agent-sync owns it (stamp file exists)
    if [ -f "$PROJECT_DIR/.cursor/.worktrees-agent-sync" ]; then
        rm -f "$PROJECT_DIR/.cursor/worktrees.json"
        rm -f "$PROJECT_DIR/.cursor/.worktrees-agent-sync"
        echo "  Removed .cursor/worktrees.json (agent-sync managed)"
    elif [ -f "$PROJECT_DIR/.cursor/worktrees.json" ]; then
        _warn "  SKIP: .cursor/worktrees.json is not managed by agent-sync — left intact."
    fi

    rmdir "$PROJECT_DIR/.cursor" 2>/dev/null || true

    # Clean CC native files (.claude/)
    if [ -f "$CC_RULES_MANIFEST" ]; then
        local old_rule
        while IFS= read -r old_rule; do
            [ -z "$old_rule" ] && continue
            rm -f "$PROJECT_DIR/.claude/rules/$old_rule"
        done < "$CC_RULES_MANIFEST"
        rm -f "$CC_RULES_MANIFEST"
        rmdir "$PROJECT_DIR/.claude/rules" 2>/dev/null || true
        echo "  Removed agent-sync managed CC rules"
    elif [ -d "$PROJECT_DIR/.claude/rules" ]; then
        _warn "  WARNING: .claude/rules/ exists but no manifest found."
    fi

    if [ -f "$CC_SKILLS_MANIFEST" ]; then
        local old_skill
        while IFS= read -r old_skill; do
            [ -z "$old_skill" ] && continue
            rm -rf "$PROJECT_DIR/.claude/skills/$old_skill"
        done < "$CC_SKILLS_MANIFEST"
        rm -f "$CC_SKILLS_MANIFEST"
        rmdir "$PROJECT_DIR/.claude/skills" 2>/dev/null || true
        echo "  Removed agent-sync managed CC skills"
    elif [ -d "$PROJECT_DIR/.claude/skills" ]; then
        _warn "  WARNING: .claude/skills/ exists but no manifest found."
    fi

    if [ -f "$CC_COMMANDS_MANIFEST" ]; then
        local old_cmd
        while IFS= read -r old_cmd; do
            [ -z "$old_cmd" ] && continue
            rm -f "$PROJECT_DIR/.claude/commands/$old_cmd"
        done < "$CC_COMMANDS_MANIFEST"
        rm -f "$CC_COMMANDS_MANIFEST"
        rmdir "$PROJECT_DIR/.claude/commands" 2>/dev/null || true
        echo "  Removed agent-sync managed CC commands"
    elif [ -d "$PROJECT_DIR/.claude/commands" ]; then
        _warn "  WARNING: .claude/commands/ exists but no manifest found."
    fi

    rmdir "$PROJECT_DIR/.claude" 2>/dev/null || true

    if [ -d "$PROJECT_DIR/.agent-rules" ]; then
        rm -rf "$PROJECT_DIR/.agent-rules"
        echo "  Removed .agent-rules/"
    fi

    rm -f "$HASH_FILE"
    echo "  Removed .agent-sync-hash"

    # Clean sub-repo generated files using manifest
    if [ -f "$MANIFEST" ]; then
        local old_rel
        while IFS= read -r old_rel; do
            rm -f "$PROJECT_DIR/$old_rel/CLAUDE.md" "$PROJECT_DIR/$old_rel/AGENTS.md"
            echo "  Removed sub-repo rules: $old_rel/"
        done < "$MANIFEST"
    fi
    rm -f "$MANIFEST"
    echo "  Removed .agent-sync-manifest"

    # Fallback: scan for auto-generated files missed by manifest (e.g., manifest was deleted)
    local stale_file
    find "$PROJECT_DIR" -mindepth 2 -maxdepth 4 \( -name 'CLAUDE.md' -o -name 'AGENTS.md' \) -not -path '*/.git/*' -not -path '*/.agent-rules/*' -not -path '*/node_modules/*' -type f | while read -r stale_file; do
        if head -1 "$stale_file" 2>/dev/null | grep -q '<!-- Auto-generated by agent-sync'; then
            rm -f "$stale_file"
            echo "  Removed orphan: ${stale_file#"$PROJECT_DIR"/}"
        fi
    done

    # Root-level remnants (only files agent-sync historically created; never touch user-owned .cursorignore)
    rm -f "$PROJECT_DIR/CLAUDE.md" "$PROJECT_DIR/AGENTS.md"

    _ok "Clean complete."
}

# --- Main dispatch ---

case "$SUBCOMMAND" in
    clean)
        do_clean
        ;;
    codex)
        validate_rules_repo
        resolve_packs
        echo "Generating AGENTS.md for Codex in $PROJECT_DIR ..."
        generate_codex
        _ok "Done."
        ;;
    claude)
        validate_rules_repo
        resolve_packs
        echo "Generating CLAUDE.md for Claude Code in $PROJECT_DIR ..."
        generate_claude
        _ok "Done."
        ;;
    skills)
        validate_rules_repo
        echo "Syncing skills to $PROJECT_DIR/.cursor/skills/ ..."
        generate_skills
        _ok "Done."
        ;;
    commands)
        validate_rules_repo
        echo "Syncing commands to $PROJECT_DIR/.cursor/commands/ ..."
        generate_commands
        _ok "Done."
        ;;
    agents)
        validate_rules_repo
        echo "Syncing agents to $PROJECT_DIR/.cursor/agents/ ..."
        generate_cursor_agents
        _ok "Done."
        ;;
    cc)
        validate_rules_repo
        resolve_packs
        resolve_cc_mode
        echo "Generating all CC native files in $PROJECT_DIR/.claude/ ..."
        generate_cc_rules
        generate_cc_skills
        generate_cc_commands
        _ok "Done."
        ;;
    cc-rules)
        validate_rules_repo
        resolve_packs
        resolve_cc_mode
        echo "Generating CC rules in $PROJECT_DIR/.claude/rules/ ..."
        generate_cc_rules
        _ok "Done."
        ;;
    cc-skills)
        validate_rules_repo
        echo "Syncing skills to $PROJECT_DIR/.claude/skills/ ..."
        generate_cc_skills
        _ok "Done."
        ;;
    sync)
        validate_rules_repo
        resolve_cc_mode
        check_staleness
        echo "Syncing rules from $RULES_HOME → $PROJECT_DIR"
        resolve_packs
        generate_cursor
        generate_skills
        generate_commands
        generate_cursor_agents
        deploy_reviewer_models_conf
        generate_reviewer_variants
        generate_worktrees
        # CC native outputs (controlled by CC Mode)
        if [ "$CC_MODE" != "off" ]; then
            generate_cc_rules
            generate_cc_skills
            generate_cc_commands
        fi
        # Legacy CLAUDE.md / AGENTS.md (skipped in native-only mode)
        if [ "$CC_MODE" != "native" ]; then
            # generate_codex internally calls generate_claude first
            generate_codex
        else
            echo "  CC Mode: native — skipping legacy CLAUDE.md / AGENTS.md generation"
        fi
        cleanup_remnants
        sync_sub_repos
        store_hash
        _ok "Sync complete."
        ;;
esac
