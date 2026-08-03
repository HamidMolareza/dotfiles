#!/usr/bin/env bash

set -Eeuo pipefail

if [[ -z "${HOME:-}" || "$HOME" != /* || "$HOME" == "/" ]]; then
    echo "HOME must be a non-root absolute path." >&2
    exit 1
fi

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
DOTFILES_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
AGENT_HELPERS_DIR="$DOTFILES_DIR/agent-helpers"
BACKUP_PARENT="$HOME/backups/dotfiles"
BACKUP_DIR=""
HAS_AGENT_HOME=false

ensure_backup_dir() {
    if [[ -n "$BACKUP_DIR" ]]; then
        return
    fi

    local previous_umask
    previous_umask="$(umask)"
    umask 077

    mkdir -p -- "$BACKUP_PARENT"
    if [[ -L "$BACKUP_PARENT" || ! -d "$BACKUP_PARENT" ]]; then
        echo "Backup parent is not a safe directory: $BACKUP_PARENT" >&2
        exit 1
    fi

    chmod 700 -- "$BACKUP_PARENT"
    BACKUP_DIR="$(mktemp -d "$BACKUP_PARENT/$(date +%Y-%m-%d_%H-%M-%S).XXXXXX")"
    chmod 700 -- "$BACKUP_DIR"
    umask "$previous_umask"
}

backup_destination() {
    local dest="$1"

    case "$dest" in
        "$HOME"/*) ;;
        *)
            echo "Refusing to back up a path outside HOME: $dest" >&2
            exit 1
            ;;
    esac

    local relative_path="${dest#"$HOME"/}"
    case "/$relative_path/" in
        */../* | */./*)
            echo "Refusing unsafe backup path: $dest" >&2
            exit 1
            ;;
    esac

    ensure_backup_dir

    local backup_path="$BACKUP_DIR/$relative_path"
    if [[ -e "$backup_path" || -L "$backup_path" ]]; then
        echo "Backup destination already exists: $backup_path" >&2
        exit 1
    fi

    mkdir -p -- "$(dirname -- "$backup_path")"
    echo "Backing up $dest -> $backup_path"
    mv -- "$dest" "$backup_path"
}

ensure_link() {
    local src="$1"
    local dest="$2"

    if [[ "$src" == "$dest" ]]; then
        echo "Source and destination must be different paths: $src" >&2
        exit 1
    fi

    if [[ ! -e "$src" ]]; then
        echo "Source does not exist: $src; skipping"
        return
    fi

    if [[ -L "$dest" && "$dest" -ef "$src" ]]; then
        echo "Symlink is correct: $dest"
        return
    fi

    if [[ -e "$dest" || -L "$dest" ]]; then
        backup_destination "$dest"
    fi

    mkdir -p -- "$(dirname -- "$dest")"
    echo "Linking $src -> $dest"
    ln -s -- "$src" "$dest"
}

link_directory_children() {
    local src_dir="$1"
    local dest_dir="$2"

    if [[ ! -d "$src_dir" ]]; then
        echo "Source directory does not exist: $src_dir; skipping"
        return
    fi

    local entries=("$src_dir"/*)
    if [[ ! -e "${entries[0]}" ]]; then
        echo "No entries in $src_dir; skipping"
        return
    fi

    local entry
    for entry in "${entries[@]}"; do
        ensure_link "$entry" "$dest_dir/$(basename -- "$entry")"
    done
}

link_merged_directory_children() {
    local shared_dir="$1"
    local agent_dir="$2"
    local dest_dir="$3"
    local -A desired=()
    local entry

    if [[ -d "$shared_dir" ]]; then
        for entry in "$shared_dir"/*; do
            [[ -e "$entry" ]] || continue
            desired["$(basename -- "$entry")"]="$entry"
        done
    fi

    if [[ -d "$agent_dir" ]]; then
        for entry in "$agent_dir"/*; do
            [[ -e "$entry" ]] || continue
            desired["$(basename -- "$entry")"]="$entry"
        done
    fi

    if [[ ${#desired[@]} -eq 0 ]]; then
        echo "No shared or agent-specific entries for $dest_dir; skipping"
        return
    fi

    local names=()
    mapfile -t names < <(printf '%s\n' "${!desired[@]}" | LC_ALL=C sort)

    local name
    for name in "${names[@]}"; do
        ensure_link "${desired[$name]}" "$dest_dir/$name"
    done
}

configure_agent_home() {
    local agent_home="$1"
    local agent_name="$2"

    if [[ ! -d "$agent_home" ]]; then
        return
    fi

    ensure_link "$AGENT_HELPERS_DIR/AGENTS.md" "$agent_home/AGENTS.md"
    link_directory_children "$AGENT_HELPERS_DIR/prompts/$agent_name" "$agent_home/prompts"
    link_merged_directory_children \
        "$AGENT_HELPERS_DIR/skills/shared" \
        "$AGENT_HELPERS_DIR/skills/$agent_name" \
        "$agent_home/skills"

    HAS_AGENT_HOME=true
}

echo "=== Installing dotfiles from $DOTFILES_DIR ==="

ensure_link "$DOTFILES_DIR/.bashrc" "$HOME/.bashrc"
ensure_link "$DOTFILES_DIR/.zshrc" "$HOME/.zshrc"
ensure_link "$DOTFILES_DIR/.aliases" "$HOME/.aliases"
ensure_link "$DOTFILES_DIR/.exports" "$HOME/.exports"

ensure_link "$DOTFILES_DIR/docker-services" "$HOME/docker-services"
ensure_link "$DOTFILES_DIR/.icons" "$HOME/.icons"
ensure_link "$DOTFILES_DIR/Templates" "$HOME/Templates"
ensure_link "$DOTFILES_DIR/.config" "$HOME/.config"
ensure_link "$DOTFILES_DIR/.local/share/applications" "$HOME/.local/share/applications"
ensure_link "$DOTFILES_DIR/scripts" "$HOME/scripts"
ensure_link "$DOTFILES_DIR/nautilus/scripts" "$HOME/.local/share/nautilus/scripts"

configure_agent_home "$HOME/.codex" "codex"
configure_agent_home "$HOME/.gapcode" "gapcode"

if [[ "$HAS_AGENT_HOME" == false ]]; then
    ensure_link "$AGENT_HELPERS_DIR/AGENTS.md" "$HOME/AGENTS.md"
fi

if [[ -n "$BACKUP_DIR" ]]; then
    echo "Backup created at $BACKUP_DIR"
fi

echo "Dotfiles installation complete. Restart affected shells or applications to reload configuration."
