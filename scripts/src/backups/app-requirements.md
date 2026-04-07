# Backup Home Script Requirements

## Purpose

Create a command-line backup script for the current Ubuntu workstation that backs up
important files and folders from explicitly configured absolute paths to a
user-selected destination.

The default focus is `/home/home`, but the rules file may also include other
absolute paths such as mounted external folders.

## Target Environment

- OS: Ubuntu 24.04
- Shell: `zsh`, but the script itself should run with `bash`
- Primary home root: `/home/home`
- Additional source roots: allowed when explicitly listed in the rules file
- Primary usage: local backup to an external disk or mounted filesystem
- Available backup engine: `rsync 3.2.7`

## Implementation Decision

- Language: Bash
- Primary engine: `rsync`
- Rationale: the script is orchestration around standard Linux tools, should stay
  easy to audit, and should keep runtime dependencies minimal

## Main Goals

- back up important personal and development data from a simple rules file
- use one backup rules file for include and exclude logic
- support dry runs before real writes
- support repeatable snapshot-style backups
- make partial restore easy
- keep the script understandable and maintainable

## Backup Model

- create snapshot directories instead of one giant tarball
- create a timestamped snapshot for each run
- use sortable names such as `YYYY-MM-DD_HH-mm-ss`
- keep the destination layout easy to inspect with normal filesystem tools
- preserve path structure and metadata as supported by `rsync`

## Required Commands

The script must support:

- `plan`
- `manual`
- `run`
- `list`
- `verify`
- `restore`
- `help`

## Required Global Options

- `--dest PATH`
- `--config-file PATH`
- `--manual-file PATH`
- `--dry-run`
- `--verbose`
- `--yes`
- `--ignore-errors`
- `--log-file PATH`

## Backup Rules File

The backup selection config must live in a single rules file.

Default file name:

- `backup-home.rules`

The script should also allow the user to pass a different file path with
`--config-file`.

### Rules Format

- one rule per line
- `#` starts a comment
- blank lines are ignored
- a normal line includes an absolute path or glob pattern
- a line starting with `!` excludes an absolute path, absolute glob, or a global name such as `node_modules`
- inline comments after whitespace are allowed

Examples:

```text
# include a full folder
/home/home/my-files

# include only matching files
/home/home/Downloads/*.txt

# exclude a path or pattern
!/home/home/Desktop/temp

# exclude matching names anywhere under included roots
!node_modules
!bin
```

## Manual Checklist File

The script should support a separate manual checklist file for informational items.

Default file name:

- `backup-home.manual`

The script should also allow the user to pass a different checklist path with:

- `--manual-file`

Format:

- one checklist item per line
- `#` starts a comment
- blank lines are ignored
- each line may be either `Title` or `Title | Description`
- the description part is optional

Examples:

- OTP
- Mobile Contacts
- Google Authenticator | Copy exported backup files
- Bookmarks

### Manual Command Behavior

- if no custom path is provided, use the default manual checklist file name
- show one task at a time
- wait for user confirmation before moving to the next task
- allow skipping the pause with `--yes`
- during a real backup run, create a temporary staging folder for manual checklist files
- open that staging folder for the user when possible and wait before continuing
- name staging subfolders from manual task titles
- when a manual task has a description, create `task.txt` in that task folder with the title and description
- include the staged manual files in that backup run
- remove the staging folder when the script exits, including cancellation and interrupts

## Safety Requirements

- refuse to run if `--dest` is missing where required
- refuse clearly dangerous destinations such as `/`
- refuse destinations inside any configured source path
- check that the destination exists or can be created
- estimate available free space before a real backup
- support dry-run mode for every write-capable command
- print a clear summary before starting a real backup
- show an estimated size breakdown for each resolved backup root during planning and backup startup, with exclude rules reflected in the estimate
- if a configured backup path does not exist, show a warning and continue
- support an option to continue on recoverable backup or verification errors

## Logging and Output

- each real backup run should write a dated log file by default
- logs should include the rules file, destination, start time, end time, and final status
- console output should be human-readable and concise by default
- `--verbose` should expose more detailed `rsync` output
- errors should be explicit and actionable

## Restore Requirements

- support restoring an entire snapshot
- support restoring a single path from a snapshot
- support restoring to an alternate destination path
- default restore to dry-run unless `--yes` is provided
- do not silently overwrite data without a clear confirmation path

## Verification Requirements

- confirm that the target snapshot exists
- confirm that expected paths derived from the current rules file are present
- report snapshot size and basic file counts
- full checksum verification is out of scope for v1

## Incremental Snapshot Behavior

- create distinct timestamped snapshots
- use `rsync --link-dest` when practical to reduce storage usage
- keep restore behavior transparent even when hard links are used

## Non-Functional Requirements

- keep the script readable and self-contained
- avoid nonstandard dependencies
- work on a default Ubuntu installation with `bash`, `find`, `du`, `df`, and `rsync`
- fail fast on invalid input
- use English for help text, comments, and logs

## Out of Scope for v1

- cloud backup providers
- database-aware dumps
- Docker volume export automation
- encrypted storage built into the script
- GUI or TUI interfaces
- full checksum verification of all files

## Acceptance Criteria

The v1 script is acceptable when all of the following are true:

- a user can preview the active rules with `plan`
- a user can run a dry-run backup with `run --dry-run`
- a user can run a real backup to an external destination
- a timestamped snapshot directory is created successfully
- the rules file can both include and exclude paths
- the `manual` command prints checklist items from `backup-home.manual`
- a user can list snapshots and restore one path from a chosen snapshot
- the script logs its work and exits with a meaningful status code
