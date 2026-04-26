#!/usr/bin/env bash
set -euo pipefail

## install.sh — Bootstrap agent-toolkit on a fresh machine.
##
## [USAGE]
##   bash install.sh [--repo-url URL] [--dest PATH] [--no-alias] [--rc-file FILE]
##
## Mirrors the manual sequence documented in README §3 "First-Time Setup":
##   1. git clone (with submodules) → ~/.config/agent-toolkit
##   2. chmod -R a-w on core/ packs/ templates/ — same set async-agent-toolkit locks
##   3. Append three aliases to the detected shell rc, idempotently
##
## Idempotent: re-running on an already-installed host re-applies locks,
## refreshes alias entries, and is safe to invoke as part of provisioning.
## The clone step is skipped when the destination is already a git repo —
## use scripts/async-agent-toolkit.sh to update an existing install.

# --- Defaults ---

readonly DEFAULT_REPO_URL="https://github.com/georgeokelly/agent-toolkit.git"
readonly DEFAULT_DEST="${HOME}/.config/agent-toolkit"
# LOCK_TARGETS must stay in lock-step with async-agent-toolkit.sh:8 — both
# scripts agree on the same write-protected source-of-truth subtrees.
readonly LOCK_TARGETS=("core" "packs" "templates")
readonly ALIAS_MARKER="# agent-toolkit aliases (managed by install.sh)"

REPO_URL="$DEFAULT_REPO_URL"
DEST="$DEFAULT_DEST"
WRITE_ALIAS=true
RC_FILE=""

# --- Output helpers ---
# stderr-routed so tool output (if any) on stdout stays parseable.
_info() { printf '[INFO] %s\n' "$*" >&2; }
_warn() { printf '[WARN] %s\n' "$*" >&2; }
_err()  { printf '[ERROR] %s\n' "$*" >&2; }
_ok()   { printf '[ OK ] %s\n' "$*" >&2; }

show_help() {
    cat <<'EOF'
install.sh — Bootstrap agent-toolkit (clone, lock, alias)

USAGE
    bash install.sh [options]

OPTIONS
    --repo-url URL    Override clone source
                      (default: https://github.com/georgeokelly/agent-toolkit.git)
    --dest PATH       Override install location
                      (default: ~/.config/agent-toolkit)
    --no-alias        Skip writing aliases — you'll add them manually
    --rc-file FILE    Force a specific shell rc (default: auto-detect zsh/bash)
    -h, --help        Show this help

WHAT IT DOES
    1. git clone the toolkit repo (with submodules) into the destination
       — if the destination is already a git repo, skip clone (use
         scripts/async-agent-toolkit.sh to update an existing install)
       — if the destination exists but is NOT a git repo, fail (so we
         never silently overwrite unrelated content)
    2. chmod -R a-w on core/, packs/, templates/ (matches the lock targets
       used by async-agent-toolkit.sh, so an in-place re-lock is harmless)
    3. Append three aliases to the detected shell rc, guarded by a marker
       comment so re-runs do not duplicate the block:
           agent-sync          → scripts/agent-sync.sh
           agent-check         → scripts/agent-check.sh
           async-agent-toolkit   → bash scripts/async-agent-toolkit.sh

POST-INSTALL
    `source` your shell rc (or open a new terminal) before using the aliases.
    See README §3 "Quick Start" for per-project setup.

EXAMPLES
    # Default install
    bash install.sh

    # Install to a custom location, skip alias generation
    bash install.sh --dest ~/code/agent-toolkit --no-alias

    # Install for a non-default shell
    bash install.sh --rc-file ~/.config/fish/config.fish
    # NOTE: fish uses `function`/`alias`-equivalent syntax; this script writes
    # bash/zsh-style `alias name="..."` lines. Edit them by hand for fish.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url) REPO_URL="$2"; shift 2 ;;
            --dest)     DEST="$2"; shift 2 ;;
            --no-alias) WRITE_ALIAS=false; shift ;;
            --rc-file)  RC_FILE="$2"; shift 2 ;;
            -h|--help)  show_help; exit 0 ;;
            *)          _err "Unknown option: $1"; echo >&2; show_help; exit 2 ;;
        esac
    done
}

ensure_git() {
    if ! command -v git >/dev/null 2>&1; then
        _err "git not found in PATH. Install git first, then re-run."
        exit 1
    fi
}

clone_or_skip() {
    if [[ -d "$DEST/.git" ]]; then
        _info "$DEST is already a git repo — skipping clone."
        _info "To update an existing install, run: bash $DEST/scripts/async-agent-toolkit.sh"
        return 0
    fi
    if [[ -e "$DEST" ]]; then
        _err "$DEST exists but is not a git repo."
        _err "Move or remove it first to avoid clobbering unrelated content."
        exit 1
    fi
    _info "Cloning $REPO_URL -> $DEST"
    mkdir -p "$(dirname "$DEST")"
    # --recurse-submodules so extras/agent-extension is pulled in one shot;
    # init_submodules is the safety-net for older git versions where the flag
    # silently no-ops.
    git clone --recurse-submodules "$REPO_URL" "$DEST"
}

init_submodules() {
    # Only meaningful when .gitmodules exists (extras/ may be empty in forks
    # that strip the submodule). Idempotent: a no-op when already initialized.
    if [[ -d "$DEST/.git" ]] && [[ -f "$DEST/.gitmodules" ]]; then
        _info "Initializing submodules ..."
        git -C "$DEST" submodule update --init --recursive
    fi
}

apply_locks() {
    _info "Applying read-only locks on ${LOCK_TARGETS[*]} ..."
    local target
    for target in "${LOCK_TARGETS[@]}"; do
        if [[ -d "$DEST/$target" ]]; then
            # chmod -R a-w is idempotent and matches async-agent-toolkit' relock.
            chmod -R a-w "$DEST/$target"
        else
            _warn "$DEST/$target not found — skipping lock for this target."
        fi
    done
}

detect_rc() {
    if [[ -n "$RC_FILE" ]]; then
        return 0
    fi
    # Prefer $SHELL — it reflects the user's login shell, which is the
    # session install.sh's aliases will actually be loaded into. Fall back
    # to existing rc files if $SHELL is empty (e.g. some CI / non-interactive
    # contexts).
    case "${SHELL:-}" in
        */zsh)  RC_FILE="${HOME}/.zshrc" ;;
        */bash) RC_FILE="${HOME}/.bashrc" ;;
        *)
            if   [[ -f "${HOME}/.zshrc"  ]]; then RC_FILE="${HOME}/.zshrc"
            elif [[ -f "${HOME}/.bashrc" ]]; then RC_FILE="${HOME}/.bashrc"
            else
                _err "Cannot auto-detect shell rc file (\$SHELL=${SHELL:-unset})."
                _err "Pass --rc-file FILE explicitly, or use --no-alias and add"
                _err "aliases by hand following README §3."
                exit 1
            fi
            ;;
    esac
}

write_aliases() {
    # Marker-gated append — re-runs are no-ops, identical to the manifest
    # ownership pattern agent-sync uses for generated artifacts.
    if [[ -f "$RC_FILE" ]] && grep -qF "$ALIAS_MARKER" "$RC_FILE"; then
        _info "Aliases already present in $RC_FILE — skipping append."
        return 0
    fi
    _info "Appending aliases to $RC_FILE ..."
    # Ensure the rc file ends in a newline before our block, so we don't
    # collide with whatever the user already wrote on the last line.
    if [[ -f "$RC_FILE" ]] && [[ -n "$(tail -c1 "$RC_FILE" 2>/dev/null)" ]]; then
        printf '\n' >> "$RC_FILE"
    fi
    cat >> "$RC_FILE" <<EOF

$ALIAS_MARKER
alias agent-sync="$DEST/scripts/agent-sync.sh"
alias agent-check="$DEST/scripts/agent-check.sh"
alias async-agent-toolkit="bash $DEST/scripts/async-agent-toolkit.sh"
EOF
}

print_next_steps() {
    echo
    _ok "agent-toolkit installed at $DEST"
    echo
    echo "Next steps:"
    if $WRITE_ALIAS; then
        echo "  1. Reload your shell:  source $RC_FILE"
        echo "     (or open a new terminal)"
        echo "  2. cd into a project, then:  agent-sync ."
        echo "  3. Validate:                 agent-check ."
    else
        echo "  1. Add aliases manually (README §3) or invoke scripts directly:"
        echo "       bash $DEST/scripts/agent-sync.sh ."
        echo "       bash $DEST/scripts/agent-check.sh ."
    fi
    echo
    echo "To update later:  bash $DEST/scripts/async-agent-toolkit.sh"
}

main() {
    parse_args "$@"
    ensure_git
    clone_or_skip
    init_submodules
    apply_locks
    if $WRITE_ALIAS; then
        detect_rc
        write_aliases
    fi
    print_next_steps
}

main "$@"
