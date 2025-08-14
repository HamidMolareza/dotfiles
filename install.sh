#!/bin/bash

set -e  # Exit on error
DOTFILES_DIR="$HOME/.dotfiles"
BACKUP_DIR="$HOME/backups/dotfiles/$(date +%Y-%m-%d_%H-%M-%S)"

backup_and_link_file() {
    local src="$1"
    local dest="$2"

    if [ -L "$dest" ]; then
        echo "✔ Symlink exists: $dest — skipping"
        return
    fi

    if [ -e "$dest" ]; then
        echo "📦 Backing up existing file: $dest"
        mkdir -p "$BACKUP_DIR"
        mv "$dest" "$BACKUP_DIR/$(basename "$dest")"
    fi

    echo "🔗 Linking $src → $dest"
    ln -sf "$src" "$dest"
}

backup_and_link_dir() {
    local src="$1"
    local dest="$2"

    if [ -L "$dest" ]; then
        echo "✔ Symlink exists: $dest — skipping"
        return
    fi

    if [ -d "$dest" ]; then
        echo "📦 Backing up existing folder: $dest"
        mkdir -p "$BACKUP_DIR"
        mv "$dest" "$BACKUP_DIR/$(basename "$dest")"

        echo "📂 Copying old contents into dotfiles repo: $src"
        mkdir -p "$src"
        cp -r "$BACKUP_DIR/$(basename "$dest")/." "$src" 2>/dev/null || true
    fi

    echo "🔗 Linking $src → $dest"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
}

echo "=== Installing dotfiles ==="

# Files
backup_and_link_file "$DOTFILES_DIR/.bashrc" "$HOME/.bashrc"
backup_and_link_file "$DOTFILES_DIR/.zshrc" "$HOME/.zshrc"
backup_and_link_file "$DOTFILES_DIR/.aliases" "$HOME/.aliases"
backup_and_link_file "$DOTFILES_DIR/.exports" "$HOME/.exports"

# Folders
backup_and_link_dir "$DOTFILES_DIR/docker-services" "$HOME/docker-services"
backup_and_link_dir "$DOTFILES_DIR/.icons" "$HOME/.icons"
backup_and_link_dir "$DOTFILES_DIR/Templates" "$HOME/Templates"
backup_and_link_dir "$DOTFILES_DIR/.config" "$HOME/.config"

backup_and_link_dir "$DOTFILES_DIR/scripts" "$HOME/scripts"
chmod +x -R $HOME/scripts

backup_and_link_dir $DOTFILES_DIR/nautilus/scripts $HOME/.local/share/nautilus/scripts
chmod +x -R $HOME/.local/share/nautilus/scripts

backup_and_link_dir $DOTFILES_DIR/.local/share/applications $HOME/.local/share/applications

echo "✅ Symlinks created. Restart your shell to apply."
