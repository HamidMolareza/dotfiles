# Dotfiles

This repository contains configuration files and scripts to set up and manage a personalized Linux environment. It includes shell aliases, environment exports, custom scripts, and configuration files for various applications and desktop environments.

## Structure

- `.aliases`, `.bashrc`, `.zshrc`, `.exports`: Shell configuration files for Bash and Zsh.
- `.config/`: Application and desktop environment configuration files.
- `.icons/`: Custom icons.
- `agent-helpers/`: Git-backed prompts, skills, and shared agent instructions exposed through symlinks.
- `docker-services/`: Docker-related service files.
- `scripts/`: Utility and setup scripts.
- `Templates/`: Document templates.
- `install.sh`: Installation script to set up the dotfiles on a new system.
- `update.sh`: Safe Git fast-forward and installer refresh for an existing checkout.

## Usage

1. Clone the repository:
   ```sh
   git clone https://github.com/HamidMolareza/dotfiles.git ~/.dotfiles
   ```
2. Run the installation script:
   ```sh
   cd ~/.dotfiles
   ./install.sh
   ```
3. Review and customize configuration files as needed.

The installer is idempotent. Correct symlinks are left untouched. Existing
files, directories, and wrong or broken symlinks are moved to a private,
uniquely named directory under `~/backups/dotfiles/` before their replacement
links are created.

## Updating An Existing Installation

Run the updater from the checkout after changes have been pushed from another
system:

```sh
cd ~/.dotfiles
./update.sh
```

The updater fetches the configured upstream and performs only a fast-forward
integration. Staged, unstaged, untracked, and ignored local files are preserved
when they do not overlap incoming paths. If Git detects an overlap, unresolved
conflict, operation in progress, detached HEAD, missing upstream, or divergent
history, the updater stops without stashing, resetting, rebasing, or merging
the divergent history.

A fetch can still update remote-tracking refs even when later integration is
refused. If Git integration succeeds but `install.sh` fails, the Git update is
kept; fix the reported installer problem and rerun `./install.sh`. The updater
also refuses to execute an uncommitted or index-hidden copy of `install.sh`.

Use `./update.sh --help` for the concise command reference. The updater never
pushes local commits; an ahead-only branch is installed with a warning that a
push is still pending.

## Optional Script Dependencies

`install.sh` only backs up and links dotfiles; it does not install system or
language packages. Scripts that have optional dependencies keep a dependency-free
fallback where practical and document their own setup.

For example, `codex-auth` works with a numbered menu by default and can use an
isolated `prompt-toolkit` environment for its enhanced picker. See
[`scripts/src/codex/codex-auth.md`](scripts/src/codex/codex-auth.md) for setup.

## Canonical IDE Paths

Desktop symlinks can expose the same project through multiple logical paths.
Use the portable IDE setup command to ensure Nautilus, desktop launchers, and
CLI commands resolve existing project paths before opening them:

```sh
ide-realpath-setup --dry-run
ide-realpath-setup
```

The command supports Rider, WebStorm, PyCharm, DataGrip, VS Code, and the
Nautilus terminal action. Run `ide-realpath-setup --help` for executable
overrides, refresh, and uninstall options. The script is self-contained and can
also be copied and run directly on another Ubuntu system.

## Customization

- Edit `.aliases`, `.bashrc`, `.zshrc`, and `.exports` to add or modify shell settings.
- Add application configs to `.config/` as needed.
- Add agent prompts and skills under `agent-helpers/`, then run `./install.sh` to refresh symlinks into agent homes.
- Place custom icons in `.icons/`.
- Add scripts to `scripts/` for automation or setup tasks.
- SSH transfer helpers live under `scripts/src/ssh`; see `scp-download` and `scp-upload` for easier `scp` downloads and uploads.

## License

See [LICENSE](LICENSE) for details.
