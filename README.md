# Dotfiles

This repository contains configuration files and scripts to set up and manage a personalized Linux environment. It includes shell aliases, environment exports, custom scripts, and configuration files for various applications and desktop environments.

## Structure

- `.aliases`, `.bashrc`, `.zshrc`, `.exports`: Shell configuration files for Bash and Zsh.
- `.config/`: Application and desktop environment configuration files.
- `.icons/`: Custom icons.
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

## Customization

- Edit `.aliases`, `.bashrc`, `.zshrc`, and `.exports` to add or modify shell settings.
- Add application configs to `.config/` as needed.
- Place custom icons in `.icons/`.
- Add scripts to `scripts/` for automation or setup tasks.

## License

See [LICENSE](LICENSE) for details.
