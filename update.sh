#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ./update.sh [--help]

Fetch the configured upstream, fast-forward the current dotfiles branch when
safe, and run install.sh. Local changes are never stashed, reset, rebased, or
merged automatically.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h | --help)
            [[ $# -eq 1 ]] || die "--help does not accept additional arguments."
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1. Run ./update.sh --help for usage."
            ;;
    esac
fi

for command_name in git readlink; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command is missing: $command_name"
done

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"

git_output() {
    git -C "$REPO_ROOT" "$@"
}

detected_root="$(git_output rev-parse --show-toplevel 2>/dev/null)" || die "$REPO_ROOT is not a Git worktree."
detected_root="$(readlink -f -- "$detected_root")"
[[ "$detected_root" == "$REPO_ROOT" ]] || die "update.sh must be run from the root dotfiles checkout."

operation_in_progress() {
    local git_dir
    git_dir="$(git_output rev-parse --absolute-git-dir)" || return 1

    local marker
    for marker in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
        if [[ -e "$git_dir/$marker" ]]; then
            printf '%s' "$marker"
            return 0
        fi
    done

    return 1
}

if [[ -n "$(git_output ls-files -u)" ]]; then
    git_output status --short >&2 || true
    die "Unresolved Git conflicts exist. Resolve them or abort the active Git operation, then rerun."
fi

if operation="$(operation_in_progress)"; then
    git_output status --short >&2 || true
    die "Git operation is still in progress ($operation). Continue or abort it explicitly, then rerun."
fi

branch="$(git_output symbolic-ref --quiet --short HEAD 2>/dev/null)" || die "Detached HEAD detected. Switch to the intended branch, then rerun."
upstream="$(git_output rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || \
    die "Branch $branch has no upstream. Configure it explicitly, for example: git branch --set-upstream-to=origin/main $branch"
remote="$(git_output config --get "branch.$branch.remote" 2>/dev/null)" || die "Could not determine the upstream remote for $branch."

hidden_index_paths=()
while IFS= read -r -d '' record; do
    tag="${record:0:1}"
    if [[ "$tag" == "S" || "$tag" =~ [a-z] ]]; then
        hidden_index_paths+=("${record:2}")
    fi
done < <(git_output ls-files -v -z)

if [[ ${#hidden_index_paths[@]} -gt 0 ]]; then
    printf 'Paths with skip-worktree or assume-unchanged flags:\n' >&2
    printf '  %s\n' "${hidden_index_paths[@]}" >&2
    die "Clear these index flags and review their local content before updating."
fi

if [[ -n "$(git_output status --short)" ]]; then
    warn "Local staged, unstaged, or untracked changes were found. Git will preserve them only when they do not overlap incoming paths."
    git_output status --short >&2
fi

if [[ "$remote" == "." ]]; then
    echo "Using local upstream $upstream; no network fetch is required."
else
    echo "Fetching $remote..."
    git_output fetch --prune "$remote" || die "Fetch failed. Check network access, authentication, and the remote configuration. No installer was run."
fi

git_output rev-parse --verify "${upstream}^{commit}" >/dev/null 2>&1 || \
    die "Upstream $upstream is missing after fetch. Verify the branch and remote configuration."

read -r ahead behind < <(git_output rev-list --left-right --count "HEAD...$upstream")

if ((ahead > 0 && behind > 0)); then
    git_output log --oneline --left-right --decorate "HEAD...$upstream" >&2 || true
    die "Local and upstream histories have diverged ($ahead local, $behind remote). Merge $upstream manually, resolve any conflicts, and rerun."
fi

if ((behind > 0)); then
    head_before="$(git_output rev-parse HEAD)"
    echo "Fast-forwarding $branch by $behind commit(s)..."
    if ! git_output merge --ff-only --no-autostash --no-overwrite-ignore "$upstream"; then
        head_after="$(git_output rev-parse HEAD 2>/dev/null || true)"
        git_output status --short >&2 || true
        if [[ "$head_before" == "$head_after" ]]; then
            die "Fast-forward was refused and HEAD was left unchanged. Review the reported overlapping tracked, untracked, staged, or ignored paths; commit or move only those paths, then rerun."
        fi
        die "Fast-forward failed after HEAD changed unexpectedly. Do not reset automatically; inspect git status and reflog before recovery."
    fi
elif ((ahead > 0)); then
    warn "Local branch is ahead of $upstream by $ahead commit(s); push is still pending."
else
    echo "Repository is already current with $upstream."
fi

git_output merge-base --is-ancestor "$upstream" HEAD || die "Post-update verification failed: $upstream is not an ancestor of HEAD. No installer was run."

INSTALLER="$REPO_ROOT/install.sh"
[[ -f "$INSTALLER" && ! -L "$INSTALLER" && -x "$INSTALLER" ]] || die "install.sh must be a regular executable file."

head_entry="$(git_output ls-tree HEAD -- install.sh)"
read -r head_mode head_type head_blob head_path <<<"$head_entry"
[[ "$head_mode" == "100755" && "$head_type" == "blob" && "$head_path" == "install.sh" ]] || \
    die "HEAD does not contain the expected executable install.sh."

index_entry="$(git_output ls-files -s -- install.sh)"
read -r index_mode index_blob index_stage index_path <<<"$index_entry"
[[ "$index_mode" == "100755" && "$index_stage" == "0" && "$index_path" == "install.sh" ]] || \
    die "The index does not contain a clean executable install.sh."

installer_tag="$(git_output ls-files -v -- install.sh)"
[[ "$installer_tag" == "H install.sh" ]] || die "install.sh has an unsafe index flag or unexpected tracked state."
[[ "$index_blob" == "$head_blob" ]] || die "install.sh has staged changes. Commit or restore them before running the updater."

worktree_blob="$(git_output hash-object -- "$INSTALLER")"
[[ "$worktree_blob" == "$head_blob" ]] || die "install.sh has unstaged content changes. Review them before running the updater."

echo "Running verified installer..."
if ! "$INSTALLER"; then
    die "The repository may already be updated, but install.sh failed. Fix the reported issue and rerun ./install.sh."
fi

echo "Dotfiles update complete at $(git_output rev-parse --short HEAD)."
