#!/bin/bash

set -e  # Exit on error

DOTFILES_DIR="$HOME/.dotfiles"
BACKUP_DIR="$HOME/backups/dotfiles/$(date +%Y-%m-%d_%H-%M-%S)"
AGENT_HELPERS_DIR="$DOTFILES_DIR/agent-helpers"

backup_and_link() {
    local src="$1"
    local dest="$2"

    if [ ! -e "$src" ]; then
        echo "⚠ Source does not exist: $src — skipping"
        return
    fi

    if [ -L "$dest" ]; then
        echo "✔ Symlink exists: $dest — skipping"
        return
    fi

    if [ -e "$dest" ]; then
        mkdir -p "$BACKUP_DIR"
        local name
        name="$(basename "$dest")"

        if [ -d "$dest" ]; then
            echo "📦 Backing up existing folder: $dest"
            mv "$dest" "$BACKUP_DIR/$name"

            echo "📂 Copying old contents into dotfiles repo: $src"
            mkdir -p "$src"
            cp -r "$BACKUP_DIR/$name/." "$src" 2>/dev/null || true
        else
            echo "📦 Backing up existing file: $dest"
            mv "$dest" "$BACKUP_DIR/$name"
        fi
    fi

    echo "🔗 Linking $src → $dest"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
}

link_directory_children() {
    local src_dir="$1"
    local dest_dir="$2"
    local backup_scope="$3"

    if [ ! -d "$src_dir" ]; then
        echo "⚠ Source directory does not exist: $src_dir — skipping"
        return
    fi

    mkdir -p "$dest_dir"

    local entry
    local name
    local dest

    shopt -s nullglob
    local entries=("$src_dir"/*)

    if [ ${#entries[@]} -eq 0 ]; then
        shopt -u nullglob
        echo "ℹ No entries in $src_dir — skipping"
        return
    fi

    for entry in "${entries[@]}"; do
        name="$(basename "$entry")"
        dest="$dest_dir/$name"

        if [ -L "$dest" ]; then
            echo "🔄 Refreshing symlink: $dest"
        elif [ -e "$dest" ]; then
            mkdir -p "$BACKUP_DIR/$backup_scope"
            echo "📦 Backing up existing path: $dest"
            mv "$dest" "$BACKUP_DIR/$backup_scope/$name"
        fi

        echo "🔗 Linking $entry → $dest"
        ln -sfn "$entry" "$dest"
    done

    shopt -u nullglob
}

configure_agent_home() {
    local agent_home="$1"
    local agent_name="$2"

    if [ ! -d "$agent_home" ]; then
        return
    fi

    backup_and_link "$AGENT_HELPERS_DIR/AGENTS.md" "$agent_home/AGENTS.md"
    link_directory_children "$AGENT_HELPERS_DIR/prompts/$agent_name" "$agent_home/prompts" "$agent_name-prompts"
    link_directory_children "$AGENT_HELPERS_DIR/skills/shared" "$agent_home/skills" "$agent_name-skills-shared"
    link_directory_children "$AGENT_HELPERS_DIR/skills/$agent_name" "$agent_home/skills" "$agent_name-skills-agent"

    HAS_AGENT_HOME=true
}

echo "=== Installing dotfiles ==="

# Files
backup_and_link "$DOTFILES_DIR/.bashrc" "$HOME/.bashrc"
backup_and_link "$DOTFILES_DIR/.zshrc" "$HOME/.zshrc"
backup_and_link "$DOTFILES_DIR/.aliases" "$HOME/.aliases"
backup_and_link "$DOTFILES_DIR/.exports" "$HOME/.exports"

# Folders
backup_and_link "$DOTFILES_DIR/docker-services" "$HOME/docker-services"
backup_and_link "$DOTFILES_DIR/.icons" "$HOME/.icons"
backup_and_link "$DOTFILES_DIR/Templates" "$HOME/Templates"
backup_and_link "$DOTFILES_DIR/.config" "$HOME/.config"
backup_and_link $DOTFILES_DIR/.local/share/applications $HOME/.local/share/applications

backup_and_link "$DOTFILES_DIR/scripts" "$HOME/scripts"
chmod +x -R $HOME/scripts

backup_and_link $DOTFILES_DIR/nautilus/scripts $HOME/.local/share/nautilus/scripts
chmod +x -R $HOME/.local/share/nautilus/scripts

# Agents

HAS_AGENT_HOME=false

configure_agent_home "$HOME/.codex" "codex"
configure_agent_home "$HOME/.gapcode" "gapcode"

if [ "$HAS_AGENT_HOME" = false ]; then
    backup_and_link "$AGENT_HELPERS_DIR/AGENTS.md" "$HOME/AGENTS.md"
fi

echo "✅ Symlinks created. Restart your shell to apply."
