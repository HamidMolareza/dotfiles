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
