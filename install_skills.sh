#!/usr/bin/env bash
set -euo pipefail

## install_skills.sh — Deploy agent-toolkit skills to global discovery paths.
##
## USAGE
##   bash install_skills.sh [--targets LIST] [--prefix PREFIX|none]
##
## Default target set:
##   cursor,claude,codex,agents,opencode
##
## Idempotent: it overwrites agent-toolkit managed skill directories, prunes
## manifest-tracked stale skills, and leaves unrelated user-authored skill
## directories alone.

# --- Defaults --------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_HOME="${AGENT_TOOLKIT_HOME:-$SCRIPT_DIR}"
PROJECT_DIR="${HOME}"

TARGETS="cursor,claude,codex,agents,opencode"
SKILL_PREFIX="${SKILL_PREFIX:-gla-}"

# --- Output helpers --------------------------------------------------------

_info() { printf '[INFO] %s\n' "$*" >&2; }
_warn() { printf '[WARN] %s\n' "$*" >&2; }
_err()  { printf '[ERROR] %s\n' "$*" >&2; }
_ok()   { printf '[ OK ] %s\n' "$*" >&2; }

show_help() {
    cat <<'EOF'
install_skills.sh — Deploy agent-toolkit skills globally

USAGE
    bash install_skills.sh [options]

OPTIONS
    --targets LIST     Comma-separated targets to deploy.
                       Values: all,cursor,claude,codex,agents,opencode
                       Default: cursor,claude,codex,agents,opencode
    --prefix PREFIX    Prefix applied to deployed directory names and
                       SKILL.md frontmatter name values.
                       Default: gla-
                       Use none/off/- to deploy bare names.
    -h, --help         Show this help.

DEFAULT GLOBAL PATHS
    cursor    ~/.cursor/skills-cursor when that directory exists,
              otherwise ~/.cursor/skills
    claude    ~/.claude/skills
    codex     ${CODEX_HOME:-~/.codex}/skills
    agents    ~/.agents/skills
    opencode  ${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/opencode}/skills

PATH OVERRIDES
    AGENT_TOOLKIT_HOME   Source repo path. Defaults to this script's directory.
    CURSOR_SKILLS_DIR    Override Cursor target.
    CLAUDE_SKILLS_DIR    Override Claude target.
    CODEX_SKILLS_DIR     Override Codex target.
    AGENTS_SKILLS_DIR    Override agents-compatible target.
    OPENCODE_SKILLS_DIR  Override OpenCode target.

EXAMPLES
    # Deploy all agent-toolkit skills globally with default gla- prefix.
    bash install_skills.sh

    # Deploy only Codex global skills.
    bash install_skills.sh --targets codex

    # Deploy bare skill names without the default namespace prefix.
    bash install_skills.sh --prefix none
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --targets)
                [[ $# -ge 2 ]] || { _err "--targets requires a value"; exit 2; }
                TARGETS="$2"
                shift 2
                ;;
            --prefix)
                [[ $# -ge 2 ]] || { _err "--prefix requires a value"; exit 2; }
                SKILL_PREFIX="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                _err "Unknown option: $1"
                echo >&2
                show_help >&2
                exit 2
                ;;
        esac
    done
}

normalize_prefix() {
    case "$SKILL_PREFIX" in
        none|off|-) SKILL_PREFIX="" ;;
        ""|*-) ;;
        *) SKILL_PREFIX="${SKILL_PREFIX}-" ;;
    esac
    export SKILL_PREFIX
}

validate_targets() {
    local raw token has_all=false
    local -a target_items
    raw="$(printf '%s' "$TARGETS" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [[ -z "$raw" ]]; then
        _err "--targets cannot be empty"
        exit 2
    fi

    IFS=',' read -r -a target_items <<< "$raw"
    for token in "${target_items[@]}"; do
        case "$token" in
            all) has_all=true ;;
            cursor|claude|codex|agents|opencode) ;;
            *)
                _err "Unknown target: $token"
                _err "Valid targets: all,cursor,claude,codex,agents,opencode"
                exit 2
                ;;
        esac
    done

    if $has_all; then
        TARGETS="all"
    else
        TARGETS="$raw"
    fi
}

validate_rules_repo() {
    _info "Checking agent-toolkit repo at $RULES_HOME ..."
    if [[ ! -d "$RULES_HOME" ]]; then
        _err "Source repo not found: $RULES_HOME"
        exit 1
    fi
    if [[ ! -d "$RULES_HOME/skills" ]]; then
        _err "Source repo missing skills/ directory: $RULES_HOME"
        exit 1
    fi
    if [[ ! -f "$RULES_HOME/scripts/lib/common.sh" ]]; then
        _err "Source repo missing scripts/lib/common.sh: $RULES_HOME"
        exit 1
    fi

    # Extras are optional, but initializing submodules makes "all skills"
    # include bundled extension skills on a fresh clone when credentials allow.
    if [[ -d "$RULES_HOME/.git" && -f "$RULES_HOME/.gitmodules" ]]; then
        git -C "$RULES_HOME" submodule update --init --recursive --quiet >/dev/null 2>&1 || {
            _warn "Submodule init failed; extras/ skills may be skipped."
            _warn "Debug: git -C \"$RULES_HOME\" submodule update --init --recursive"
        }
    fi
}

cursor_target() {
    if [[ -n "${CURSOR_SKILLS_DIR:-}" ]]; then
        printf '%s\n' "$CURSOR_SKILLS_DIR"
    elif [[ -d "$HOME/.cursor/skills-cursor" ]]; then
        printf '%s\n' "$HOME/.cursor/skills-cursor"
    else
        printf '%s\n' "$HOME/.cursor/skills"
    fi
}

claude_target() {
    printf '%s\n' "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
}

codex_target() {
    if [[ -n "${CODEX_SKILLS_DIR:-}" ]]; then
        printf '%s\n' "$CODEX_SKILLS_DIR"
    else
        printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/skills"
    fi
}

agents_target() {
    printf '%s\n' "${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
}

opencode_target() {
    if [[ -n "${OPENCODE_SKILLS_DIR:-}" ]]; then
        printf '%s\n' "$OPENCODE_SKILLS_DIR"
    else
        printf '%s\n' "${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/skills"
    fi
}

target_enabled() {
    local needle="$1" targets_padded
    [[ "$TARGETS" == "all" ]] && return 0
    targets_padded=",$TARGETS,"
    [[ "$targets_padded" == *",$needle,"* ]]
}

deploy_target() {
    local name="$1" target_dir="$2" manifest_file
    manifest_file="$target_dir/.agent-toolkit-global-skills-manifest"

    _info "Deploying $name skills -> $target_dir"
    deploy_artifacts "$RULES_HOME/skills" "$target_dir" "$manifest_file" "$name Skills"
}

deploy_selected_targets() {
    local count=0

    if target_enabled cursor; then
        deploy_target "Cursor" "$(cursor_target)"
        count=$((count + 1))
    fi
    if target_enabled claude; then
        deploy_target "Claude" "$(claude_target)"
        count=$((count + 1))
    fi
    if target_enabled codex; then
        deploy_target "Codex" "$(codex_target)"
        count=$((count + 1))
    fi
    if target_enabled agents; then
        deploy_target "Agents" "$(agents_target)"
        count=$((count + 1))
    fi
    if target_enabled opencode; then
        deploy_target "OpenCode" "$(opencode_target)"
        count=$((count + 1))
    fi

    if [[ "$count" -eq 0 ]]; then
        _err "No valid targets selected: $TARGETS"
        _err "Valid targets: all,cursor,claude,codex,agents,opencode"
        exit 2
    fi
}

main() {
    parse_args "$@"
    validate_targets
    normalize_prefix
    validate_rules_repo

    # Source after validation so the error for a broken checkout is local to
    # this script. deploy_artifacts handles copy, prefixing, extras, and stale
    # cleanup using the same code path as project-level agent-sync.
    # shellcheck source=scripts/lib/common.sh
    source "$RULES_HOME/scripts/lib/common.sh"

    if [[ -n "$SKILL_PREFIX" ]]; then
        _info "Skill Prefix: '$SKILL_PREFIX'"
    else
        _info "Skill Prefix: <none>"
    fi

    deploy_selected_targets
    _ok "Global skill deployment complete."
}

main "$@"
