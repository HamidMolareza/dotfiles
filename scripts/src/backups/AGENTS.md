# AGENTS.md

These instructions apply to all files under this backup-tool directory.

## Scope

This folder is for the new general home-backup tool and its supporting files.

Current source of truth:

- `app-requirements.md`

If implementation details conflict with this file, update the requirements first or keep the implementation aligned with the documented behavior.

## Primary Goal

Build and maintain a safe, inspectable backup tool for explicitly configured user
paths that:

- uses Bash as the implementation language for v1
- uses `rsync` as the backup engine
- creates snapshot-style backups instead of a single tarball
- keeps include and exclude definitions in a separate config directory

## Implementation Rules

- Use Bash for the main script unless requirements are explicitly changed.
- Prefer standard Ubuntu tools only: `bash`, `rsync`, `find`, `du`, `df`, `date`, `mkdir`, `readlink`, and similar base utilities.
- Keep the script readable and self-contained.
- Use `set -Eeuo pipefail` in executable shell scripts unless there is a documented reason not to.
- Keep comments short and focused on non-obvious behavior.
- Use English for code, comments, logs, help text, and documentation.

## Configuration Rules

- Include and exclude files, folders, and patterns must live under a dedicated `config/` directory, not inline in the script.
- Profile definitions belong under `config/profiles/`.
- Shared and local exclude rules belong under `config/excludes/`.
- Manual checklist data belongs under `config/manual/`.
- Prefer changing config files over hardcoding machine-specific paths in the script body.
- If a new profile or exclusion layer is introduced, document it in `app-requirements.md`.

## Safety Rules

- Do not design the tool to write backups into the source tree.
- Do not allow dangerous destinations such as `/`, the current user's home, or paths
  inside a backed-up source unless requirements explicitly change.
- Dry-run support is mandatory for write-capable operations.
- Restore behavior must not silently overwrite data.
- Sensitive paths such as `.ssh` and `.gnupg` must remain opt-in, not default.
- Exclude caches, trash, package caches, and build outputs by default unless requirements explicitly change.

## Backup Model Rules

- Prefer snapshot directories with sortable timestamps.
- Do not switch to archive-only backups as the primary model.
- `--link-dest` or similar space-saving behavior is acceptable only if restore remains straightforward.

## Change Discipline

- Keep changes minimal and focused.
- Do not add features that are outside `app-requirements.md` without updating the requirements.
- When behavior changes, update both the implementation and the requirements in the same task.
- Avoid introducing extra dependencies or framework-like structure for a small shell tool.

## Validation

Before considering work complete, prefer validating with:

- help output
- dry-run execution
- basic command-path checks for `plan`, `run`, `list`, `verify`, and `restore`

If validation is skipped or blocked, state that clearly.
