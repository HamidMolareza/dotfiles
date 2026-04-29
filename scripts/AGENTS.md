# AGENTS.md

These instructions apply to all files under `/home/home/.dotfiles/scripts` unless a deeper `AGENTS.md` overrides them.

## Scope

- This repository is a personal CLI toolbox.
- `src/backups/AGENTS.md` already defines narrower rules for `/home/home/.dotfiles/scripts/src/backups` and takes precedence there.

## Repository Shape

- `exports` is the bootstrap entrypoint. It sets `SCRIPTS_DIR="$HOME/scripts"`, exports `LIBS_DIR`, and adds selected `src/*` folders to `PATH`.
- `src/` contains user-facing commands grouped by topic such as `git`, `network`, `media`, `system`, `dev`, `codex`, and `utils`.
- Most commands are extensionless executables intended to be run directly from `PATH`.
- `libs/common_functions.sh` is the shared shell helper library for scripts that opt into sourcing it.
- The code lives in this dotfiles repository, but runtime path assumptions still point at `$HOME/scripts`. Preserve that unless the user asks for a coordinated migration.

## Placement Rules

- Put new commands in the most specific existing `src/<topic>/` folder that fits.
- Create a new top-level folder under `src/` only when no existing category is a reasonable home.
- If you add a new top-level `src/<topic>/` folder, update `exports` so that folder is added to `PATH`.
- Preserve existing command names unless the user explicitly asks for a rename.
- Prefer extensionless filenames for user-facing commands. Use `.sh` only when matching an existing local pattern or when the script is clearly maintenance-oriented.

## Language Rules

- Default to Bash for small automation, wrappers, file operations, system tasks, and command composition.
- Use Python for tools that need richer parsing, API handling, structured output, interactive selection, or more involved text processing.
- Prefer single-file CLIs unless there is a clear maintenance reason to split code.
- Avoid adding frameworks, packaging layers, or non-trivial dependency trees for small utilities.
- Use English for code, comments, help text, and logs.

## Shell Conventions

- For new Bash scripts, prefer `#!/usr/bin/env bash` unless a nearby file clearly standardizes on `#!/bin/bash` and consistency matters more.
- Prefer `set -Eeuo pipefail` in new non-trivial Bash scripts. Do not mass-apply it to legacy scripts unless you are already refactoring and have verified behavior.
- Quote paths and variable expansions consistently.
- Check external dependencies before use.
- Keep help text near the top of the file and make failure messages direct.
- If a script is standalone, prefer explicit checks or the `command-exists` command that is exposed through `PATH`.
- If a script already sources `libs/common_functions.sh`, use its helper functions such as `command_exists` and `echo_info` rather than inventing a parallel pattern in the same file.
- Do not convert simple standalone scripts into sourced multi-file tools unless that materially reduces duplication.

## Safety Rules

- Many commands here touch system configuration, networking, Git state, SSH, GPG, Docker, startup entries, and user files. Favor safe defaults.
- Prefer additive flags, clear usage text, and dry-run or preview behavior for write-capable operations when practical.
- Do not silently make destructive changes to system configuration or user data.
- Avoid drive-by cleanup of unrelated legacy inconsistencies unless the user asked for that cleanup.

## Proxy Defaults

- Scripts under `src/` that perform network requests should honor the current process proxy environment by default, including `http_proxy`, `https_proxy`, `all_proxy`, and uppercase variants.
- Do not silently unset proxy variables, pass no-proxy flags, disable client proxy discovery, or force a built-in proxy by default.
- Explicit user choices may override the environment. Examples include a `--proxy VALUE` argument, a script-specific proxy argument, a `--direct`/`--no-proxy` option, or a dedicated helper whose purpose is to clear proxy settings.
- When adding or changing network scripts, document whether proxy handling follows the current environment, an explicit proxy parameter, or an explicit direct/no-proxy mode.

## Validation

- There is no central automated test suite for this repository. Validate the specific scripts you changed.
- For Bash changes, run `bash -n <script>`.
- For Python changes, run `python3 -m py_compile <script>`.
- If formatting is needed, prefer `shfmt` for shell files.
- Prefer `-h` or `--help` checks and other non-destructive invocations.
- Do not validate by running live commands that change system state, DNS, proxy settings, startup entries, backups, cloud state, or Git history unless the user explicitly asked for that validation.
- If you add a command that should be reachable from `PATH`, verify that `exports` exposes its folder.
