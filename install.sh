#!/bin/bash

set -e  # Exit on error
DOTFILES_DIR="$HOME/.dotfiles"
BACKUP_DIR="$HOME/backups/dotfiles/$(date +%Y-%m-%d_%H-%M-%S)"

backup_and_link_file() {
    local src="$DOTFILES_DIR/$1"
    local dest="$HOME/$1"

    if [ -L "$dest" ]; then
        echo "✔ Symlink exists: $dest — skipping"
        return
    fi

    if [ -e "$dest" ]; then
        echo "📦 Backing up existing file: $dest"
        mkdir -p "$BACKUP_DIR"
        mv "$dest" "$BACKUP_DIR/$1"
    fi

    echo "🔗 Linking $src → $dest"
    ln -sf "$src" "$dest"
}

backup_and_link_dir() {
    local src="$DOTFILES_DIR/$1"
    local dest="$HOME/$1"

    if [ -L "$dest" ]; then
        echo "✔ Symlink exists: $dest — skipping"
        return
    fi

    if [ -d "$dest" ]; then
        echo "📦 Backing up existing folder: $dest"
        mkdir -p "$BACKUP_DIR"
        mv "$dest" "$BACKUP_DIR/$1"

        echo "📂 Copying old contents into dotfiles repo: $src"
        mkdir -p "$src"
        cp -r "$BACKUP_DIR/$1/." "$src" 2>/dev/null || true
    fi

    echo "🔗 Linking $src → $dest"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
}

echo "=== Installing dotfiles ==="

# Files
backup_and_link_file ".bashrc"
backup_and_link_file ".zshrc"
backup_and_link_file ".aliases"
backup_and_link_file ".exports"

# Folders
backup_and_link_dir "docker-services"
backup_and_link_dir ".icons"
backup_and_link_dir "Templates"
backup_and_link_dir ".config"

backup_and_link_dir "scripts"
chmod +x -R $HOME/scripts


ln -sf $DOTFILES_DIR/nautilus/* $HOME/.local/share/nautilus/
chmod +x -R $HOME/.local/share/nautilus/

echo "✅ Symlinks created. Restart your shell to apply."
