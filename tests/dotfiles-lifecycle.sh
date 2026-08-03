#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd -- "$(dirname -- "$SCRIPT_PATH")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "/tmp/dotfiles lifecycle.XXXXXX")"
PASS_COUNT=0

cleanup() {
    if [[ -n "${TEST_ROOT:-}" && "$TEST_ROOT" == "/tmp/dotfiles lifecycle."* ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: $*"
}

assert_file_content() {
    local path="$1"
    local expected="$2"
    [[ -f "$path" ]] || fail "Expected file: $path"
    [[ "$(<"$path")" == "$expected" ]] || fail "Unexpected content in $path"
}

assert_link_target() {
    local link="$1"
    local target="$2"
    [[ -L "$link" ]] || fail "Expected symlink: $link"
    [[ "$link" -ef "$target" ]] || fail "$link does not resolve to $target"
}

configure_git_repo() {
    local repo="$1"
    git -C "$repo" config user.name "Dotfiles Test"
    git -C "$repo" config user.email "dotfiles-test@example.invalid"
    git -C "$repo" config commit.gpgsign false
}

create_installer_fixture() {
    INSTALL_REPO="$TEST_ROOT/installer repo"
    mkdir -p -- \
        "$INSTALL_REPO/docker-services" \
        "$INSTALL_REPO/Templates" \
        "$INSTALL_REPO/.config" \
        "$INSTALL_REPO/.local/share/applications" \
        "$INSTALL_REPO/scripts" \
        "$INSTALL_REPO/nautilus/scripts" \
        "$INSTALL_REPO/agent-helpers/prompts/codex/prompt-one" \
        "$INSTALL_REPO/agent-helpers/prompts/gapcode/prompt-two" \
        "$INSTALL_REPO/agent-helpers/skills/shared/collision" \
        "$INSTALL_REPO/agent-helpers/skills/codex/collision" \
        "$INSTALL_REPO/agent-helpers/skills/gapcode/gap-only"

    cp -- "$PROJECT_ROOT/install.sh" "$INSTALL_REPO/install.sh"
    chmod +x -- "$INSTALL_REPO/install.sh"
    printf 'bashrc source\n' >"$INSTALL_REPO/.bashrc"
    printf 'zshrc source\n' >"$INSTALL_REPO/.zshrc"
    printf 'aliases source\n' >"$INSTALL_REPO/.aliases"
    printf 'exports source\n' >"$INSTALL_REPO/.exports"
    printf 'agent instructions\n' >"$INSTALL_REPO/agent-helpers/AGENTS.md"
    printf 'docker\n' >"$INSTALL_REPO/docker-services/managed"
    printf 'template\n' >"$INSTALL_REPO/Templates/managed"
    printf 'config\n' >"$INSTALL_REPO/.config/managed"
    printf 'desktop\n' >"$INSTALL_REPO/.local/share/applications/managed.desktop"
    printf 'script\n' >"$INSTALL_REPO/scripts/managed"
    printf 'nautilus\n' >"$INSTALL_REPO/nautilus/scripts/managed"
    printf 'prompt\n' >"$INSTALL_REPO/agent-helpers/prompts/codex/prompt-one/content"
    printf 'prompt\n' >"$INSTALL_REPO/agent-helpers/prompts/gapcode/prompt-two/content"
    printf 'shared\n' >"$INSTALL_REPO/agent-helpers/skills/shared/collision/source"
    printf 'codex\n' >"$INSTALL_REPO/agent-helpers/skills/codex/collision/source"
    printf 'gap\n' >"$INSTALL_REPO/agent-helpers/skills/gapcode/gap-only/source"

    git -C "$INSTALL_REPO" init --quiet --initial-branch=main
    configure_git_repo "$INSTALL_REPO"
    git -C "$INSTALL_REPO" add .
    git -C "$INSTALL_REPO" commit --quiet -m "fixture"
    INSTALL_HEAD="$(git -C "$INSTALL_REPO" rev-parse HEAD)"
}

assert_installer_checkout_unchanged() {
    [[ "$(git -C "$INSTALL_REPO" rev-parse HEAD)" == "$INSTALL_HEAD" ]] || fail "Installer fixture HEAD changed"
    [[ -z "$(git -C "$INSTALL_REPO" status --porcelain=v1 --untracked-files=all)" ]] || fail "Installer dirtied its source checkout"
    git -C "$INSTALL_REPO" diff --quiet || fail "Installer changed tracked worktree bytes or modes"
    git -C "$INSTALL_REPO" diff --cached --quiet || fail "Installer changed the index"
}

backup_count() {
    local home_dir="$1"
    if [[ ! -d "$home_dir/backups/dotfiles" ]]; then
        echo 0
        return
    fi
    find "$home_dir/backups/dotfiles" -mindepth 1 -maxdepth 1 -type d -printf '.' | wc -c
}

test_installer_lifecycle() {
    create_installer_fixture
    local home_dir="$TEST_ROOT/installer home"
    mkdir -p -- \
        "$home_dir/scripts" \
        "$home_dir/.local/share/nautilus/scripts" \
        "$home_dir/.codex" \
        "$home_dir/.gapcode" \
        "$home_dir/.icons"
    printf 'old bashrc\n' >"$home_dir/.bashrc"
    printf 'old home scripts\n' >"$home_dir/scripts/home.txt"
    printf 'old nautilus scripts\n' >"$home_dir/.local/share/nautilus/scripts/nautilus.txt"
    printf 'old codex agents\n' >"$home_dir/.codex/AGENTS.md"
    printf 'old gapcode agents\n' >"$home_dir/.gapcode/AGENTS.md"
    printf 'local icons\n' >"$home_dir/.icons/local"

    env HOME="$home_dir" "$INSTALL_REPO/install.sh" >"$TEST_ROOT/install-first.log"

    assert_link_target "$home_dir/.bashrc" "$INSTALL_REPO/.bashrc"
    assert_link_target "$home_dir/scripts" "$INSTALL_REPO/scripts"
    assert_link_target "$home_dir/.local/share/nautilus/scripts" "$INSTALL_REPO/nautilus/scripts"
    assert_link_target "$home_dir/.codex/skills/collision" "$INSTALL_REPO/agent-helpers/skills/codex/collision"
    assert_link_target "$home_dir/.gapcode/skills/collision" "$INSTALL_REPO/agent-helpers/skills/shared/collision"
    [[ ! -L "$home_dir/.icons" ]] || fail "Missing source should not replace the destination"
    assert_file_content "$home_dir/.icons/local" "local icons"
    [[ "$(backup_count "$home_dir")" == 1 ]] || fail "First install should create one backup root"

    local first_backup
    first_backup="$(find "$home_dir/backups/dotfiles" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ "$(stat -c '%a' "$first_backup")" == 700 ]] || fail "Backup root must be private"
    assert_file_content "$first_backup/.bashrc" "old bashrc"
    assert_file_content "$first_backup/scripts/home.txt" "old home scripts"
    assert_file_content "$first_backup/.local/share/nautilus/scripts/nautilus.txt" "old nautilus scripts"
    assert_file_content "$first_backup/.codex/AGENTS.md" "old codex agents"
    assert_file_content "$first_backup/.gapcode/AGENTS.md" "old gapcode agents"

    local bashrc_inode_before collision_inode_before
    bashrc_inode_before="$(stat -c '%i' "$home_dir/.bashrc")"
    collision_inode_before="$(stat -c '%i' "$home_dir/.codex/skills/collision")"
    env HOME="$home_dir" "$INSTALL_REPO/install.sh" >"$TEST_ROOT/install-second.log"
    [[ "$(backup_count "$home_dir")" == 1 ]] || fail "Idempotent rerun created another backup"
    [[ "$(stat -c '%i' "$home_dir/.bashrc")" == "$bashrc_inode_before" ]] || fail "Correct top-level link was recreated"
    [[ "$(stat -c '%i' "$home_dir/.codex/skills/collision")" == "$collision_inode_before" ]] || fail "Correct child link was recreated"

    local alternate="$home_dir/alternate-source"
    printf 'alternate\n' >"$alternate"
    unlink "$home_dir/.zshrc"
    unlink "$home_dir/.exports"
    ln -s -- "$home_dir/missing-source" "$home_dir/.zshrc"
    ln -s -- "$alternate" "$home_dir/.exports"
    env HOME="$home_dir" "$INSTALL_REPO/install.sh" >"$TEST_ROOT/install-repair.log"
    assert_link_target "$home_dir/.zshrc" "$INSTALL_REPO/.zshrc"
    assert_link_target "$home_dir/.exports" "$INSTALL_REPO/.exports"
    [[ "$(backup_count "$home_dir")" == 2 ]] || fail "Repair should create one new backup root"
    [[ -n "$(find "$home_dir/backups/dotfiles" -path '*/.zshrc' -type l -print -quit)" ]] || fail "Broken link was not backed up"
    [[ -n "$(find "$home_dir/backups/dotfiles" -path '*/.exports' -type l -print -quit)" ]] || fail "Wrong live link was not backed up"

    assert_installer_checkout_unchanged
    pass "installer reconciliation, backup isolation, precedence, and idempotency"
}

test_installer_partial_recovery() {
    local home_dir="$TEST_ROOT/recovery home"
    local shim_dir="$TEST_ROOT/failing tools"
    mkdir -p -- "$home_dir" "$shim_dir"
    printf 'recover me\n' >"$home_dir/.bashrc"
    cat >"$shim_dir/ln" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == */.bashrc ]]; then
    exit 42
fi
exec /usr/bin/ln "$@"
EOF
    chmod +x -- "$shim_dir/ln"

    set +e
    env HOME="$home_dir" PATH="$shim_dir:$PATH" "$INSTALL_REPO/install.sh" >"$TEST_ROOT/install-failure.log" 2>&1
    local status=$?
    set -e
    [[ $status -ne 0 ]] || fail "Injected link failure should fail the installer"
    [[ ! -e "$home_dir/.bashrc" && ! -L "$home_dir/.bashrc" ]] || fail "Failed destination should remain absent after its backup"
    local backup_path
    backup_path="$(find "$home_dir/backups/dotfiles" -path '*/.bashrc' -type f -print -quit)"
    assert_file_content "$backup_path" "recover me"

    env HOME="$home_dir" "$INSTALL_REPO/install.sh" >"$TEST_ROOT/install-recovery.log"
    assert_link_target "$home_dir/.bashrc" "$INSTALL_REPO/.bashrc"
    assert_file_content "$backup_path" "recover me"
    assert_installer_checkout_unchanged
    pass "installer partial failure is recoverable by rerunning"
}

create_update_fixture() {
    local name="$1"
    CASE_ROOT="$TEST_ROOT/update cases/$name"
    ORIGIN="$CASE_ROOT/origin.git"
    PUBLISHER="$CASE_ROOT/publisher"
    CLIENT="$CASE_ROOT/client repo"
    CASE_HOME="$CASE_ROOT/home"
    MARKER="$CASE_ROOT/installer-runs"
    mkdir -p -- "$CASE_ROOT" "$CASE_HOME"

    git init --bare --quiet "$ORIGIN"
    git init --quiet --initial-branch=main "$PUBLISHER"
    configure_git_repo "$PUBLISHER"
    cp -- "$PROJECT_ROOT/update.sh" "$PUBLISHER/update.sh"
    chmod +x -- "$PUBLISHER/update.sh"
    cat >"$PUBLISHER/install.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${INSTALL_MARKER:?}"
printf 'run\n' >>"$INSTALL_MARKER"
exit "${INSTALL_EXIT_CODE:-0}"
EOF
    chmod +x -- "$PUBLISHER/install.sh"
    printf 'base a\n' >"$PUBLISHER/a.txt"
    printf 'base b\n' >"$PUBLISHER/b.txt"
    printf 'base c\n' >"$PUBLISHER/c.txt"
    printf 'ignored.txt\n' >"$PUBLISHER/.gitignore"
    git -C "$PUBLISHER" add .
    git -C "$PUBLISHER" commit --quiet -m "initial"
    git -C "$PUBLISHER" remote add origin "$ORIGIN"
    git -C "$PUBLISHER" push --quiet -u origin main
    git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
    git clone --quiet "$ORIGIN" "$CLIENT"
    configure_git_repo "$CLIENT"
}

publish_file() {
    local path="$1"
    local content="$2"
    local message="$3"
    printf '%s\n' "$content" >"$PUBLISHER/$path"
    git -C "$PUBLISHER" add -- "$path"
    git -C "$PUBLISHER" commit --quiet -m "$message"
    git -C "$PUBLISHER" push --quiet
}

run_update() {
    set +e
    UPDATE_OUTPUT="$(env HOME="$CASE_HOME" INSTALL_MARKER="$MARKER" INSTALL_EXIT_CODE="${INSTALL_EXIT_CODE_FOR_TEST:-0}" "$CLIENT/update.sh" "$@" 2>&1)"
    UPDATE_STATUS=$?
    set -e
}

assert_update_succeeded() {
    [[ $UPDATE_STATUS -eq 0 ]] || fail "Updater failed unexpectedly: $UPDATE_OUTPUT"
}

assert_update_refused() {
    [[ $UPDATE_STATUS -ne 0 ]] || fail "Updater should have refused the state"
    [[ ! -e "$MARKER" ]] || fail "Installer ran after updater refusal"
}

test_update_current_and_behind() {
    create_update_fixture "current"
    run_update
    assert_update_succeeded
    run_update
    assert_update_succeeded
    [[ "$(wc -l <"$MARKER")" == 2 ]] || fail "Current updater should run installer on each invocation"

    create_update_fixture "clean behind"
    publish_file remote.txt "remote" "remote change"
    run_update
    assert_update_succeeded
    assert_file_content "$CLIENT/remote.txt" "remote"
    git -C "$CLIENT" merge-base --is-ancestor '@{u}' HEAD || fail "Client did not reach upstream"
    pass "updater current, repeat, and clean fast-forward"
}

test_update_dirty_nonoverlap() {
    create_update_fixture "dirty nonoverlap"
    printf 'local unstaged\n' >"$CLIENT/a.txt"
    printf 'local staged\n' >"$CLIENT/c.txt"
    git -C "$CLIENT" add c.txt
    printf 'local untracked\n' >"$CLIENT/local.txt"
    publish_file b.txt "remote b" "remote nonoverlap"
    run_update
    assert_update_succeeded
    assert_file_content "$CLIENT/a.txt" "local unstaged"
    assert_file_content "$CLIENT/c.txt" "local staged"
    assert_file_content "$CLIENT/local.txt" "local untracked"
    assert_file_content "$CLIENT/b.txt" "remote b"
    git -C "$CLIENT" diff --quiet -- a.txt && fail "Unstaged change was lost"
    git -C "$CLIENT" diff --cached --quiet -- c.txt && fail "Staged change was lost"
    pass "updater preserves staged, unstaged, and untracked non-overlapping changes"
}

test_update_overlap_guards() {
    create_update_fixture "tracked overlap"
    printf 'local tracked\n' >"$CLIENT/a.txt"
    publish_file a.txt "remote tracked" "tracked overlap"
    local head_before
    head_before="$(git -C "$CLIENT" rev-parse HEAD)"
    run_update
    assert_update_refused
    [[ "$(git -C "$CLIENT" rev-parse HEAD)" == "$head_before" ]] || fail "Tracked overlap changed HEAD"
    assert_file_content "$CLIENT/a.txt" "local tracked"

    create_update_fixture "staged overlap"
    printf 'local staged\n' >"$CLIENT/a.txt"
    git -C "$CLIENT" add a.txt
    publish_file a.txt "remote staged" "staged overlap"
    head_before="$(git -C "$CLIENT" rev-parse HEAD)"
    run_update
    assert_update_refused
    [[ "$(git -C "$CLIENT" rev-parse HEAD)" == "$head_before" ]] || fail "Staged overlap changed HEAD"
    assert_file_content "$CLIENT/a.txt" "local staged"

    create_update_fixture "untracked overlap"
    printf 'local untracked\n' >"$CLIENT/collision.txt"
    publish_file collision.txt "remote untracked" "untracked overlap"
    run_update
    assert_update_refused
    assert_file_content "$CLIENT/collision.txt" "local untracked"

    create_update_fixture "ignored overlap"
    printf 'local ignored\n' >"$CLIENT/ignored.txt"
    printf 'remote ignored\n' >"$PUBLISHER/ignored.txt"
    git -C "$PUBLISHER" add -f ignored.txt
    git -C "$PUBLISHER" commit --quiet -m "ignored overlap"
    git -C "$PUBLISHER" push --quiet
    run_update
    assert_update_refused
    assert_file_content "$CLIENT/ignored.txt" "local ignored"
    pass "updater refuses tracked, staged, untracked, and ignored overlaps without data loss"
}

test_update_topology_guards() {
    create_update_fixture "diverged"
    printf 'local commit\n' >"$CLIENT/local-commit.txt"
    git -C "$CLIENT" add local-commit.txt
    git -C "$CLIENT" commit --quiet -m "local"
    publish_file remote.txt "remote commit" "remote"
    run_update
    assert_update_refused

    create_update_fixture "ahead only"
    printf 'local commit\n' >"$CLIENT/local-commit.txt"
    git -C "$CLIENT" add local-commit.txt
    git -C "$CLIENT" commit --quiet -m "local"
    run_update
    assert_update_succeeded
    [[ "$UPDATE_OUTPUT" == *"push is still pending"* ]] || fail "Ahead-only warning was missing"

    create_update_fixture "no upstream"
    git -C "$CLIENT" branch --unset-upstream
    run_update
    assert_update_refused

    create_update_fixture "detached"
    git -C "$CLIENT" checkout --quiet --detach
    run_update
    assert_update_refused

    create_update_fixture "fetch failure"
    git -C "$CLIENT" remote set-url origin "$CASE_ROOT/missing-origin.git"
    run_update
    assert_update_refused
    pass "updater handles ahead, diverged, detached, missing-upstream, and fetch failures"
}

test_update_operation_and_index_guards() {
    create_update_fixture "operation markers"
    local git_dir
    git_dir="$(git -C "$CLIENT" rev-parse --absolute-git-dir)"
    local marker
    for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
        printf '%s\n' "$(git -C "$CLIENT" rev-parse HEAD)" >"$git_dir/$marker"
        run_update
        assert_update_refused
        rm -f -- "$git_dir/$marker"
    done
    for marker in rebase-merge rebase-apply sequencer; do
        mkdir -p -- "$git_dir/$marker"
        run_update
        assert_update_refused
        rmdir -- "$git_dir/$marker"
    done

    create_update_fixture "skip worktree"
    git -C "$CLIENT" update-index --skip-worktree a.txt
    run_update
    assert_update_refused

    create_update_fixture "assume unchanged"
    git -C "$CLIENT" update-index --assume-unchanged a.txt
    run_update
    assert_update_refused
    pass "updater refuses in-progress operations and hidden index flags"
}

test_update_installer_integrity_and_cli() {
    create_update_fixture "dirty installer"
    printf '# local change\n' >>"$CLIENT/install.sh"
    run_update
    assert_update_refused

    create_update_fixture "staged installer"
    printf '# staged change\n' >>"$CLIENT/install.sh"
    git -C "$CLIENT" add install.sh
    run_update
    assert_update_refused

    create_update_fixture "installer mode"
    chmod -x -- "$CLIENT/install.sh"
    run_update
    assert_update_refused

    create_update_fixture "installer failure"
    INSTALL_EXIT_CODE_FOR_TEST=23
    run_update
    unset INSTALL_EXIT_CODE_FOR_TEST
    [[ $UPDATE_STATUS -ne 0 ]] || fail "Installer failure should propagate"
    [[ -e "$MARKER" ]] || fail "Failing installer did not run"

    create_update_fixture "cli"
    git -C "$CLIENT" remote set-url origin "$CASE_ROOT/missing-origin.git"
    run_update --help
    assert_update_succeeded
    [[ ! -e "$MARKER" ]] || fail "Help ran the installer"
    run_update --unknown
    assert_update_refused
    pass "updater verifies installer integrity, propagates failure, and keeps help side-effect free"
}

test_installer_lifecycle
test_installer_partial_recovery
test_update_current_and_behind
test_update_dirty_nonoverlap
test_update_overlap_guards
test_update_topology_guards
test_update_operation_and_index_guards
test_update_installer_integrity_and_cli

echo "All $PASS_COUNT lifecycle groups passed."
