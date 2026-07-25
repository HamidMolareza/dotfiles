#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
BACKUP_HOME="$PROJECT_DIR/backup-home"
TEST_ROOT="$(mktemp -d /tmp/backup-home-integration.XXXXXX)"

cleanup() {
  rm -rf --one-file-system -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "Expected file: $1"
}

assert_dir() {
  [[ -d "$1" ]] || fail "Expected directory: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "Expected path to be absent: $1"
}

assert_contains() {
  local file="$1"
  local value="$2"
  grep -F -- "$value" "$file" >/dev/null || fail "Expected '$value' in $file"
}

assert_not_contains() {
  local file="$1"
  local value="$2"
  ! grep -F -- "$value" "$file" >/dev/null || fail "Unexpected '$value' in $file"
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

expect_rc() {
  local expected="$1"
  local output="$2"
  shift 2
  local actual
  set +e
  "$@" >"$output" 2>&1
  actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    sed -n '1,240p' "$output" >&2
    fail "Expected exit code $expected, got $actual for: $*"
  fi
}

write_base_case() {
  local root="$1"
  mkdir -p "$root/source/sub" "$root/dest" "$root/config/excludes" "$root/tmp"
  printf 'alpha\n' >"$root/source/a.txt"
  printf 'beta\n' >"$root/source/sub/b.txt"
  {
    printf 'include=%s\n' "$root/source"
    printf 'exclude_file=excludes/common.exclude\n'
  } >"$root/config/profile.conf"
  printf 'ignored\n' >"$root/config/excludes/common.exclude"
  : >"$root/manual"
  : >"$root/collectors"
  printf 'keep_last=1\n' >"$root/retention"
}

latest_snapshot() {
  local destination="$1"
  find "$destination/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | sort | tail -n 1
}

run_core_flow() {
  local root="$TEST_ROOT/core"
  local output="$root/output"
  local first
  local second
  local inode_first
  local inode_second
  local -a args

  write_base_case "$root"
  mkdir -p "$root/restore"
  args=(
    --dest "$root/dest"
    --config-file "$root/config/profile.conf"
    --manual-file "$root/manual"
    --collectors-file "$root/collectors"
    --retention-file "$root/retention"
  )

  "$BACKUP_HOME" --help >"$output.help"
  assert_contains "$output.help" "prune"
  assert_contains "$output.help" "drill"
  "$BACKUP_HOME" "${args[@]}" plan >"$output.plan"
  assert_contains "$output.plan" "$root/source"
  env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --dry-run >"$output.dry-run"
  assert_not_exists "$root/dest/snapshots"

  env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$output.run-1"
  first="$(latest_snapshot "$root/dest")"
  assert_file "$root/dest/snapshots/$first/.backup-home/manifest.tsv"
  assert_file "$root/dest/snapshots/$first/.backup-home/report.txt"
  assert_file "$root/dest/snapshots/$first/.backup-home/checksums.sha256"
  assert_contains "$root/dest/snapshots/$first/.backup-home/manifest.tsv" $'status\tsuccess'

  "$BACKUP_HOME" "${args[@]}" list >"$output.list"
  assert_contains "$output.list" "$first [success]"
  "$BACKUP_HOME" "${args[@]}" verify "$first" >"$output.verify"
  "$BACKUP_HOME" "${args[@]}" verify "$first" --deep >"$output.verify-deep"
  assert_contains "$output.verify-deep" "CHECKSUMS OK"

  "$BACKUP_HOME" "${args[@]}" restore "$first" --path "$root/source/sub" \
    --restore-to "$root/restore" >"$output.restore-dry"
  assert_not_exists "$root/restore${root}/source/sub/b.txt"
  "$BACKUP_HOME" "${args[@]}" restore "$first" --path "$root/source/sub" \
    --restore-to "$root/restore" --yes >"$output.restore-real"
  assert_file "$root/restore${root}/source/sub/b.txt"
  cmp "$root/source/sub/b.txt" "$root/restore${root}/source/sub/b.txt"
  "$BACKUP_HOME" "${args[@]}" drill "$first" --path "$root/source/sub" >"$output.drill"
  assert_contains "$output.drill" "Restore drill succeeded"
  expect_rc 1 "$output.traversal" "$BACKUP_HOME" "${args[@]}" restore "$first" \
    --path "$root/source/../source" --restore-to "$root/restore" --yes

  sleep 1
  printf 'gamma\n' >>"$root/source/a.txt"
  env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$output.run-2"
  second="$(latest_snapshot "$root/dest")"
  [[ "$first" != "$second" ]] || fail "Second snapshot reused the first timestamp"
  inode_first="$(stat -c '%d:%i' "$root/dest/snapshots/$first${root}/source/sub/b.txt")"
  inode_second="$(stat -c '%d:%i' "$root/dest/snapshots/$second${root}/source/sub/b.txt")"
  assert_equal "$inode_first" "$inode_second" "Unchanged file should be hard-linked"

  "$BACKUP_HOME" "${args[@]}" prune --keep-last 1 >"$output.prune-preview"
  assert_dir "$root/dest/snapshots/$first"
  assert_contains "$output.prune-preview" "$first"
  "$BACKUP_HOME" "${args[@]}" prune --keep-last 1 --yes >"$output.prune-real"
  assert_not_exists "$root/dest/snapshots/$first"
  assert_dir "$root/dest/snapshots/$second"
  assert_file "$(find "$root/dest/logs" -maxdepth 1 -name 'backup-home-prune-*.log' | head -n 1)"
  sed -i $'s/^schema_version\t3$/schema_version\t2/' \
    "$root/dest/snapshots/$second/.backup-home/manifest.tsv"
  "$BACKUP_HOME" "${args[@]}" verify "$second" >"$output.verify-v2"
  sed -i $'s/^schema_version\t2$/schema_version\t3/' \
    "$root/dest/snapshots/$second/.backup-home/manifest.tsv"

  exec {lock_fd}<>"$root/dest/.backup-home/run.lock"
  flock -x "$lock_fd"
  printf 'pid\t99999\ncommand\ttest-holder\n' >"$root/dest/.backup-home/lock-owner.tsv"
  expect_rc 75 "$output.lock" "$BACKUP_HOME" "${args[@]}" list
  assert_contains "$output.lock" "test-holder"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

run_zero_exclude_flow() {
  local root="$TEST_ROOT/zero-excludes"
  local snapshot
  local exclude_summary
  local -a args

  write_base_case "$root"
  printf 'include=%s\n' "$root/source" >"$root/config/profile.conf"
  args=(--dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" \
    --retention-file "$root/retention")

  "$BACKUP_HOME" "${args[@]}" plan >"$root/output.plan"
  exclude_summary="$(awk '/^Exclude files:$/ { getline; print; exit }' "$root/output.plan")"
  assert_equal "  - none" "$exclude_summary" "Zero-exclude plan summary"

  env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$root/output.run"
  snapshot="$(latest_snapshot "$root/dest")"
  assert_file "$root/dest/snapshots/$snapshot${root}/source/a.txt"
}

run_profile_symlink_flow() {
  local root="$TEST_ROOT/profile-symlink"
  local snapshot
  local -a args

  mkdir -p "$root/home/Desktop" "$root/home/my-files/temp" \
    "$root/home/my-files/learning-daily" "$root/dest" "$root/config" "$root/tmp"
  printf 'kept\n' >"$root/home/my-files/temp/data.txt"
  printf 'selected-by-collector-only\n' >"$root/home/my-files/learning-daily/notes.md"
  ln -s ../my-files/temp "$root/home/Desktop/temp"
  {
    printf 'include=%s\n' "$root/home/Desktop"
    printf 'include=%s\n' "$root/home/my-files"
    printf 'exclude_file=%s\n' "$root/config/excludes"
  } >"$root/config/profile.conf"
  printf '%s\n' "$root/home/my-files/learning-daily" >"$root/config/excludes"
  : >"$root/manual"
  : >"$root/collectors"
  printf 'keep_last=1\n' >"$root/retention"
  args=(--dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" \
    --retention-file "$root/retention")
  env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$root/output"
  snapshot="$(latest_snapshot "$root/dest")"
  [[ -L "$root/dest/snapshots/$snapshot${root}/home/Desktop/temp" ]] \
    || fail "Desktop/temp symlink was not preserved"
  assert_file "$root/dest/snapshots/$snapshot${root}/home/my-files/temp/data.txt"
  assert_not_exists "$root/dest/snapshots/$snapshot${root}/home/my-files/learning-daily"
}

run_collector_flows() {
  local root="$TEST_ROOT/collectors"
  local required_root="$root/required"
  local optional_root="$root/optional"
  local timeout_root="$root/timeout"
  local inventory_root="$root/inventory"
  local inventory_failure_root="$root/inventory-failure"
  local manual_root="$root/manual-optional"
  local dry_root="$root/dry"
  local snapshot
  local output
  local -a args

  write_base_case "$required_root"
  output="$required_root/output"
  # shellcheck disable=SC2016 # The generated collector expands this variable when it runs.
  printf '#!/usr/bin/env bash\nif [[ "${1:-}" == metadata ]]; then printf "protocol\\\\t1\\\\nbackup\\\\trequired\\\\nrestore\\\\tunsupported\\\\n"; exit; fi\nmkdir -p -- "$BACKUP_HOME_STAGE_DIR"\nprintf "partial\\n" >"$BACKUP_HOME_STAGE_DIR/partial.txt"\nexit 23\n' >"$required_root/fail-collector"
  chmod +x "$required_root/fail-collector"
  printf '10|required|must-pass|%s\n' "$required_root/fail-collector" >"$required_root/collectors"
  args=(--dest "$required_root/dest" --config-file "$required_root/config/profile.conf" \
    --manual-file "$required_root/manual" --collectors-file "$required_root/collectors" \
    --retention-file "$required_root/retention")
  expect_rc 23 "$output" env TMPDIR="$required_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes --ignore-errors
  [[ -z "$(find "$required_root/dest/snapshots" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true)" ]] \
    || fail "Required collector failure published a snapshot"
  [[ -z "$(find "$required_root/dest/snapshots" -mindepth 1 -maxdepth 1 -name '.incomplete-*' -print 2>/dev/null || true)" ]] \
    || fail "Required collector failure left incomplete data"
  assert_file "$(find "$required_root/dest/logs" -maxdepth 1 -name '*.failure.tsv' | head -n 1)"
  [[ -z "$(find "$required_root/tmp" -mindepth 1 -maxdepth 1 -name 'backup-home-stage.*' -print)" ]] \
    || fail "Required collector failure left staging data"

  write_base_case "$optional_root"
  cp "$required_root/fail-collector" "$optional_root/fail-collector"
  printf '10|optional|may-fail|%s\n' "$optional_root/fail-collector" >"$optional_root/collectors"
  args=(--dest "$optional_root/dest" --config-file "$optional_root/config/profile.conf" \
    --manual-file "$optional_root/manual" --collectors-file "$optional_root/collectors" \
    --retention-file "$optional_root/retention")
  env TMPDIR="$optional_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$optional_root/output"
  snapshot="$(latest_snapshot "$optional_root/dest")"
  assert_contains "$optional_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'status\tsuccess-with-warnings'
  output="$optional_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/may-fail"
  assert_dir "$output"
  assert_file "$output/failure.tsv"
  assert_contains "$output/failure.tsv" $'exit_code\t23'
  assert_contains "$output/failure.tsv" $'timed_out\tno'
  assert_not_exists "$output/partial.txt"

  write_base_case "$timeout_root"
  cat >"$timeout_root/slow-collector" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == metadata ]]; then
  printf 'protocol\t1\nbackup\trequired\nrestore\tunsupported\n'
  exit
fi
printf 'partial\n' >"$BACKUP_HOME_STAGE_DIR/partial.txt"
sleep 5
EOF
  cat >"$timeout_root/after-collector" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == metadata ]]; then
  printf 'protocol\t1\nbackup\trequired\nrestore\tunsupported\n'
  exit
fi
printf 'completed\n' >"$BACKUP_HOME_STAGE_DIR/completed.txt"
EOF
  chmod +x "$timeout_root/slow-collector" "$timeout_root/after-collector"
  {
    printf '10|optional|slow|%s|1\n' "$timeout_root/slow-collector"
    printf '20|optional|after|%s|5\n' "$timeout_root/after-collector"
  } >"$timeout_root/collectors"
  args=(--dest "$timeout_root/dest" --config-file "$timeout_root/config/profile.conf" \
    --manual-file "$timeout_root/manual" --collectors-file "$timeout_root/collectors" \
    --retention-file "$timeout_root/retention")
  env TMPDIR="$timeout_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$timeout_root/output"
  snapshot="$(latest_snapshot "$timeout_root/dest")"
  output="$timeout_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors"
  assert_contains "$timeout_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'status\tsuccess-with-warnings'
  assert_contains "$timeout_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'collector\tslow\toptional\tfailed\t124\t'
  assert_file "$output/slow/failure.tsv"
  assert_contains "$output/slow/failure.tsv" $'timed_out\tyes'
  assert_contains "$output/slow/failure.tsv" $'timeout_seconds\t1'
  assert_not_exists "$output/slow/partial.txt"
  assert_file "$output/after/completed.txt"

  write_base_case "$inventory_root"
  assert_not_contains "$BACKUP_HOME" "recover_system_inventory"
  mkdir -p "$inventory_root/fake-home"
  printf '10|required|system-inventory|%s\n' "$PROJECT_DIR/collectors/system-inventory" >"$inventory_root/collectors"
  args=(--dest "$inventory_root/dest" --config-file "$inventory_root/config/profile.conf" \
    --manual-file "$inventory_root/manual" --collectors-file "$inventory_root/collectors" \
    --retention-file "$inventory_root/retention")
  env HOME="$inventory_root/fake-home" TMPDIR="$inventory_root/tmp" \
    "$BACKUP_HOME" "${args[@]}" run --yes >"$inventory_root/output"
  snapshot="$(latest_snapshot "$inventory_root/dest")"
  assert_file "$inventory_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/system-inventory/RESTORE.md"
  assert_file "$inventory_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/system-inventory/tool-versions.tsv"

  write_base_case "$inventory_failure_root"
  mkdir -p "$inventory_failure_root/fake-home" "$inventory_failure_root/fakebin"
  cat >"$inventory_failure_root/fakebin/apt-mark" <<'EOF'
#!/usr/bin/env bash
printf 'partial-apt\n'
exit 7
EOF
  cat >"$inventory_failure_root/fakebin/dpkg" <<'EOF'
#!/usr/bin/env bash
printf 'partial-dpkg\tinstall\n'
exit 8
EOF
  cat >"$inventory_failure_root/fakebin/crontab" <<'EOF'
#!/usr/bin/env bash
printf 'permission denied: private diagnostic\n' >&2
exit 2
EOF
  chmod +x "$inventory_failure_root/fakebin/apt-mark" \
    "$inventory_failure_root/fakebin/dpkg" "$inventory_failure_root/fakebin/crontab"
  printf '10|required|system-inventory|%s\n' "$PROJECT_DIR/collectors/system-inventory" \
    >"$inventory_failure_root/collectors"
  args=(--dest "$inventory_failure_root/dest" \
    --config-file "$inventory_failure_root/config/profile.conf" \
    --manual-file "$inventory_failure_root/manual" \
    --collectors-file "$inventory_failure_root/collectors" \
    --retention-file "$inventory_failure_root/retention")
  env PATH="$inventory_failure_root/fakebin:$PATH" HOME="$inventory_failure_root/fake-home" \
    TMPDIR="$inventory_failure_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes \
    >"$inventory_failure_root/output"
  snapshot="$(latest_snapshot "$inventory_failure_root/dest")"
  assert_contains "$inventory_failure_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'status\tsuccess-with-warnings'
  assert_contains "$inventory_failure_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'collector\tsystem-inventory\trequired\twarning\t0\t'
  output="$inventory_failure_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/system-inventory"
  assert_contains "$output/warnings.txt" "APT manual package inventory failed"
  assert_contains "$output/warnings.txt" "dpkg selection inventory failed"
  assert_contains "$output/warnings.txt" "crontab inventory failed"
  assert_not_exists "$output/apt-manual.txt"
  assert_not_exists "$output/dpkg-selections.txt"
  assert_not_exists "$output/crontab.txt"

  write_base_case "$manual_root"
  printf 'Deferred contacts export\n' >"$manual_root/manual"
  printf '10|optional|manual-backup|%s\n' "$PROJECT_DIR/collectors/manual-backup" >"$manual_root/collectors"
  args=(--dest "$manual_root/dest" --config-file "$manual_root/config/profile.conf" \
    --manual-file "$manual_root/manual" --collectors-file "$manual_root/collectors" \
    --retention-file "$manual_root/retention")
  env TMPDIR="$manual_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$manual_root/output"
  snapshot="$(latest_snapshot "$manual_root/dest")"
  assert_file "$manual_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/manual-backup/RESTORE.md"
  assert_file "$manual_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/manual-backup/checksums.sha256"
  assert_contains "$manual_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'collector\tmanual-backup\toptional\twarning\t0\t'
  assert_contains "$manual_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'status\tsuccess-with-warnings'

  write_base_case "$dry_root"
  # shellcheck disable=SC2016 # The generated collector expands its argument.
  printf '#!/usr/bin/env bash\nif [[ "${1:-}" == metadata ]]; then printf "protocol\\\\t1\\\\nbackup\\\\trequired\\\\nrestore\\\\tunsupported\\\\n"; exit; fi\ntouch %q\n' "$dry_root/executed" >"$dry_root/sentinel-collector"
  chmod +x "$dry_root/sentinel-collector"
  printf '10|required|sentinel|%s\n' "$dry_root/sentinel-collector" >"$dry_root/collectors"
  args=(--dest "$dry_root/dest" --config-file "$dry_root/config/profile.conf" \
    --manual-file "$dry_root/manual" --collectors-file "$dry_root/collectors" \
    --retention-file "$dry_root/retention")
  env TMPDIR="$dry_root/tmp" "$BACKUP_HOME" "${args[@]}" run --dry-run >"$dry_root/output"
  assert_not_exists "$dry_root/executed"
}

run_docker_config_flow() {
  local root="$TEST_ROOT/docker-config"
  local output="$root/output"
  local config="$root/local.conf"

  mkdir -p "$root/stage"
  cp "$PROJECT_DIR/config/docker-recovery/local.conf.sample" "$config"
  (
    # shellcheck source=lib/docker-recovery-config
    source "$PROJECT_DIR/lib/docker-recovery-config"
    load_docker_recovery_config "$config"
    assert_equal "Projects/TaskSorter" "$TASKSORTER_SOURCE_RELATIVE" "sample TaskSorter path"
    assert_equal "sql-server-db" "$MSSQL_CONTAINER" "sample SQL Server container"
  )

  expect_rc 1 "$output.missing" env \
    BACKUP_HOME_STAGE_DIR="$root/stage" \
    BACKUP_HOME_DOCKER_RECOVERY_CONFIG="$root/missing.conf" \
    "$PROJECT_DIR/collectors/docker-recovery"
  assert_contains "$output.missing" "Docker recovery config not found"

  cp "$config" "$root/invalid.conf"
  printf 'unknown_key=value\n' >>"$root/invalid.conf"
  expect_rc 1 "$output.invalid" env \
    BACKUP_HOME_STAGE_DIR="$root/stage" \
    BACKUP_HOME_DOCKER_RECOVERY_CONFIG="$root/invalid.conf" \
    "$PROJECT_DIR/collectors/docker-recovery"
  assert_contains "$output.invalid" "Unknown Docker recovery config key"
}

latest_recovery_session() {
  local state_root="$1"
  find "$state_root/backup-home/recovery" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | sort | tail -n 1
}

run_recovery_flows() {
  local root="$TEST_ROOT/recovery"
  local filesystem_root="$root/filesystem"
  local handler_root="$root/handler"
  local snapshot
  local session
  local state_file
  local collector
  local -a args

  write_base_case "$filesystem_root"
  mkdir -p "$filesystem_root/target-home" "$filesystem_root/state"
  args=(--dest "$filesystem_root/dest" --config-file "$filesystem_root/config/profile.conf" \
    --manual-file "$filesystem_root/manual" --collectors-file "$filesystem_root/collectors" \
    --retention-file "$filesystem_root/retention")
  env TMPDIR="$filesystem_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$filesystem_root/output.run"
  snapshot="$(latest_snapshot "$filesystem_root/dest")"
  assert_contains "$filesystem_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'schema_version\t3'
  assert_contains "$filesystem_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'source_uid\t'

  env XDG_STATE_HOME="$filesystem_root/state" "$BACKUP_HOME" "${args[@]}" \
    restore-plan "$snapshot" --target-home "$filesystem_root/target-home" \
    --staging-dir "$filesystem_root/staging-plan" \
    --map-path "$filesystem_root/source=$filesystem_root/target/restored" \
    >"$filesystem_root/output.plan"
  assert_contains "$filesystem_root/output.plan" "Manifest schema: 3"
  assert_contains "$filesystem_root/output.plan" "files.1"

  env XDG_STATE_HOME="$filesystem_root/state" "$BACKUP_HOME" "${args[@]}" \
    recover "$snapshot" --target-home "$filesystem_root/target-home" \
    --staging-dir "$filesystem_root/staging-1" \
    --map-path "$filesystem_root/source=$filesystem_root/target/restored" \
    --component files.1 --yes >"$filesystem_root/output.recover-1"
  assert_file "$filesystem_root/target/restored/a.txt"
  cmp "$filesystem_root/source/a.txt" "$filesystem_root/target/restored/a.txt"

  sleep 1
  printf 'conflict\n' >"$filesystem_root/target/restored/a.txt"
  env XDG_STATE_HOME="$filesystem_root/state" "$BACKUP_HOME" "${args[@]}" \
    recover "$snapshot" --target-home "$filesystem_root/target-home" \
    --staging-dir "$filesystem_root/staging-2" \
    --map-path "$filesystem_root/source=$filesystem_root/target/restored" \
    --component files.1 --yes >"$filesystem_root/output.recover-conflict"
  session="$(latest_recovery_session "$filesystem_root/state")"
  state_file="$filesystem_root/state/backup-home/recovery/$session/state.tsv"
  assert_contains "$state_file" $'component\tfiles.1\tmanual-pending'
  assert_contains "$filesystem_root/target/restored/a.txt" "conflict"

  env XDG_STATE_HOME="$filesystem_root/state" "$BACKUP_HOME" --dest "$filesystem_root/dest" \
    recover --resume "$session" --approve-destructive files.1 --yes \
    >"$filesystem_root/output.resume"
  cmp "$filesystem_root/source/a.txt" "$filesystem_root/target/restored/a.txt"
  assert_contains "$state_file" $'component\tfiles.1\tverified'
  assert_file "$filesystem_root/state/backup-home/recovery/$session/pre-restore/files.1${filesystem_root}/target/restored/a.txt"

  write_base_case "$handler_root"
  mkdir -p "$handler_root/state" "$handler_root/target-home"
  collector="$handler_root/collector"
  cat >"$collector" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  metadata)
    [[ -z "${BACKUP_HOME_AMBIENT_SENTINEL:-}" ]]
    [[ -z "${BACKUP_HOME_RESTORE_SESSION_DIR:-}" ]]
    [[ -z "${BACKUP_HOME_GITHUB_CONFIG:-}" ]]
    printf 'protocol\t1\nbackup\trequired\n'
    [[ "${BACKUP_HOME_COLLECTOR_NAME:-}" == custom ]] \
      && printf 'restore\tsupported\n' || printf 'restore\tunsupported\n'
    ;;
  backup)
    [[ -z "${BACKUP_HOME_AMBIENT_SENTINEL:-}" ]]
    [[ -z "${BACKUP_HOME_TARGET_HOME:-}" ]]
    [[ -z "${BACKUP_HOME_GITHUB_CONFIG:-}" ]]
    [[ "${BACKUP_HOME_ARTIFACT_DIR:-}" == "$BACKUP_HOME_STAGE_DIR" ]]
    [[ -n "$BACKUP_HOME_MANUAL_FILE" && -n "$BACKUP_HOME_COLLECTOR_STARTED_AT" ]]
    printf 'collector guidance\n' >"$BACKUP_HOME_STAGE_DIR/RESTORE.md"
    ;;
  restore)
    shift
    case "$1" in
      describe)
    printf 'component\tcustom.safe\tCustom safe restore\tautomatic\tsafe\trecommended\n'
    printf 'component\tcustom.destructive\tCustom destructive restore\tautomatic\tdestructive\toptional\n'
    ;;
      preflight) printf 'ok\tFake collector is ready\n' ;;
      apply)
        [[ -z "${BACKUP_HOME_AMBIENT_SENTINEL:-}" ]]
        [[ -z "${BACKUP_HOME_GITHUB_CONFIG:-}" ]]
        [[ -n "${BACKUP_HOME_COLLECTOR_TIMEOUT_SECONDS:-}" ]]
        [[ -n "$BACKUP_HOME_RUN_ID" && -n "$BACKUP_HOME_RUN_STARTED_AT" ]]
        [[ -n "$BACKUP_HOME_COLLECTOR_STARTED_AT" && -n "$BACKUP_HOME_MANUAL_FILE" ]]
        [[ "$BACKUP_HOME_STAGE_DIR" == "$BACKUP_HOME_RESTORE_STAGING_DIR" ]]
        [[ "$BACKUP_HOME_DRY_RUN" == "$BACKUP_HOME_RESTORE_DRY_RUN" ]]
        env | sed -n '/^BACKUP_HOME_/s/=.*$/=<set>/p' | sort \
          >"$BACKUP_HOME_RESTORE_SESSION_DIR/$2.context"
        touch "$BACKUP_HOME_RESTORE_SESSION_DIR/$2.applied"
        ;;
      verify) test -f "$BACKUP_HOME_RESTORE_SESSION_DIR/$2.applied" ;;
      guide) printf 'Review the fake collector result.\n' ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$collector"
  {
    printf '10|required|custom|%s\n' "$collector"
    printf '20|required|unknown|%s\n' "$collector"
  } >"$handler_root/collectors"
  args=(--dest "$handler_root/dest" --config-file "$handler_root/config/profile.conf" \
    --manual-file "$handler_root/manual" --collectors-file "$handler_root/collectors" \
    --retention-file "$handler_root/retention")
  env TMPDIR="$handler_root/tmp" BACKUP_HOME_AMBIENT_SENTINEL=leak \
    BACKUP_HOME_TARGET_HOME=/ambient/target BACKUP_HOME_GITHUB_CONFIG=/ambient/github \
    "$BACKUP_HOME" "${args[@]}" run --yes >"$handler_root/output.run"
  snapshot="$(latest_snapshot "$handler_root/dest")"
  env XDG_STATE_HOME="$handler_root/state" BACKUP_HOME_AMBIENT_SENTINEL=leak \
    BACKUP_HOME_STAGE_DIR=/ambient/stage BACKUP_HOME_GITHUB_CONFIG=/ambient/github \
    "$BACKUP_HOME" "${args[@]}" \
    recover "$snapshot" --target-home "$handler_root/target-home" \
    --staging-dir "$handler_root/staging" --all --yes >"$handler_root/output.recover"
  session="$(latest_recovery_session "$handler_root/state")"
  state_file="$handler_root/state/backup-home/recovery/$session/state.tsv"
  assert_file "$handler_root/state/backup-home/recovery/$session/custom.safe.applied"
  assert_file "$handler_root/state/backup-home/recovery/$session/custom.safe.context"
  assert_not_exists "$handler_root/state/backup-home/recovery/$session/custom.destructive.applied"
  assert_contains "$state_file" $'component\tcustom.destructive\tmanual-pending'

  env XDG_STATE_HOME="$handler_root/state" "$BACKUP_HOME" --dest "$handler_root/dest" \
    --collectors-file "$handler_root/collectors" recover --resume "$session" \
    --approve-destructive custom.destructive --yes >"$handler_root/output.resume"
  assert_file "$handler_root/state/backup-home/recovery/$session/custom.destructive.applied"
  assert_contains "$state_file" $'component\tcustom.destructive\tverified'

  sleep 1
  env XDG_STATE_HOME="$handler_root/state" "$BACKUP_HOME" "${args[@]}" \
    recover "$snapshot" --target-home "$handler_root/target-home" \
    --staging-dir "$handler_root/staging-fallback" \
    --component collector.unknown.artifacts --yes >"$handler_root/output.fallback"
  assert_file "$handler_root/staging-fallback/artifacts/unknown/RESTORE.md"
}

run_manifest_compatibility_flow() {
  local root="$TEST_ROOT/manifest-compat"
  local source_snapshot
  local v1="2025-01-01_01-00-00"
  local v2="2025-01-01_02-00-00"
  local -a args

  write_base_case "$root"
  mkdir -p "$root/state-v1" "$root/state-v2" "$root/restore-v1" "$root/restore-v2" \
    "$root/target-v1" "$root/target-v2"
  args=(--dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" \
    --retention-file "$root/retention")
  env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$root/output.run"
  source_snapshot="$(latest_snapshot "$root/dest")"
  cp -a -- "$root/dest/snapshots/$source_snapshot" "$root/dest/snapshots/$v1"
  cp -a -- "$root/dest/snapshots/$source_snapshot" "$root/dest/snapshots/$v2"
  sed -i \
    -e $'s/^schema_version\t3$/schema_version\t1/' \
    -e $"s/^snapshot\t.*/snapshot\t$v1/" \
    -e '/^source_user\t/d' -e '/^source_uid\t/d' -e '/^source_gid\t/d' -e '/^source_home\t/d' \
    "$root/dest/snapshots/$v1/.backup-home/manifest.tsv"
  sed -i \
    -e $'s/^schema_version\t3$/schema_version\t2/' \
    -e $"s/^snapshot\t.*/snapshot\t$v2/" \
    "$root/dest/snapshots/$v2/.backup-home/manifest.tsv"

  "$BACKUP_HOME" "${args[@]}" list >"$root/output.list"
  assert_contains "$root/output.list" "$v1 [success]"
  assert_contains "$root/output.list" "$v2 [success]"
  "$BACKUP_HOME" "${args[@]}" verify "$v1" >"$root/output.verify-v1"
  "$BACKUP_HOME" "${args[@]}" verify "$v2" >"$root/output.verify-v2"
  "$BACKUP_HOME" "${args[@]}" restore "$v1" --path "$root/source/a.txt" \
    --restore-to "$root/restore-v1" --yes >"$root/output.restore-v1"
  "$BACKUP_HOME" "${args[@]}" restore "$v2" --path "$root/source/a.txt" \
    --restore-to "$root/restore-v2" --yes >"$root/output.restore-v2"
  assert_file "$root/restore-v1${root}/source/a.txt"
  assert_file "$root/restore-v2${root}/source/a.txt"

  env XDG_STATE_HOME="$root/state-v1" "$BACKUP_HOME" "${args[@]}" \
    restore-plan "$v1" --target-home "$root/target-v1" \
    --staging-dir "$root/staging-plan-v1" \
    --map-path "$root/source=$root/target-v1/restored" >"$root/output.plan-v1"
  assert_contains "$root/output.plan-v1" "Manifest schema: 1"
  assert_contains "$root/output.plan-v1" "Source identity was inferred"
  env XDG_STATE_HOME="$root/state-v1" "$BACKUP_HOME" "${args[@]}" \
    recover "$v1" --target-home "$root/target-v1" --staging-dir "$root/staging-v1" \
    --map-path "$root/source=$root/target-v1/restored" --component files.1 --yes \
    >"$root/output.recover-v1"
  assert_file "$root/target-v1/restored/a.txt"

  env XDG_STATE_HOME="$root/state-v2" "$BACKUP_HOME" "${args[@]}" \
    restore-plan "$v2" --target-home "$root/target-v2" \
    --staging-dir "$root/staging-plan-v2" \
    --map-path "$root/source=$root/target-v2/restored" >"$root/output.plan-v2"
  assert_contains "$root/output.plan-v2" "Manifest schema: 2"
  env XDG_STATE_HOME="$root/state-v2" "$BACKUP_HOME" "${args[@]}" \
    recover "$v2" --target-home "$root/target-v2" --staging-dir "$root/staging-v2" \
    --map-path "$root/source=$root/target-v2/restored" --component files.1 --yes \
    >"$root/output.recover-v2"
  assert_file "$root/target-v2/restored/a.txt"
}

run_failure_and_integrity_flows() {
  local root="$TEST_ROOT/failures"
  local rsync_root="$root/rsync"
  local vanished_root="$root/rsync-vanished"
  local tamper_root="$root/tamper"
  local legacy_root="$root/legacy"
  local snapshot
  local legacy_name="2025-01-01_00-00-00"
  local -a args

  write_base_case "$rsync_root"
  mkdir -p "$rsync_root/fakebin"
  printf '#!/usr/bin/env bash\nexit 23\n' >"$rsync_root/fakebin/rsync"
  chmod +x "$rsync_root/fakebin/rsync"
  args=(--dest "$rsync_root/dest" --config-file "$rsync_root/config/profile.conf" \
    --manual-file "$rsync_root/manual" --collectors-file "$rsync_root/collectors" \
    --retention-file "$rsync_root/retention")
  expect_rc 23 "$rsync_root/output" env TMPDIR="$rsync_root/tmp" PATH="$rsync_root/fakebin:$PATH" \
    "$BACKUP_HOME" "${args[@]}" run --yes --ignore-errors
  [[ -z "$(find "$rsync_root/dest/snapshots" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true)" ]] \
    || fail "Rsync failure published a snapshot"
  assert_file "$(find "$rsync_root/dest/logs" -maxdepth 1 -name '*.failure.tsv' | head -n 1)"

  write_base_case "$vanished_root"
  mkdir -p "$vanished_root/fakebin"
  cat >"$vanished_root/fakebin/rsync" <<'EOF'
#!/usr/bin/env bash
set -u
/usr/bin/rsync "$@"
rc=$?
[[ "$rc" -eq 0 ]] || exit "$rc"
for argument in "$@"; do
  [[ "$argument" != --relative ]] || exit 24
done
exit 0
EOF
  chmod +x "$vanished_root/fakebin/rsync"
  args=(--dest "$vanished_root/dest" --config-file "$vanished_root/config/profile.conf" \
    --manual-file "$vanished_root/manual" --collectors-file "$vanished_root/collectors" \
    --retention-file "$vanished_root/retention")
  env TMPDIR="$vanished_root/tmp" PATH="$vanished_root/fakebin:$PATH" \
    "$BACKUP_HOME" "${args[@]}" run --yes >"$vanished_root/output"
  snapshot="$(latest_snapshot "$vanished_root/dest")"
  assert_contains "$vanished_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'status\tsuccess-with-warnings'
  assert_contains "$vanished_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'rsync_exit_code\t24'
  assert_contains "$vanished_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" \
    $'warning\tRsync reported vanished source files (rc=24)'

  write_base_case "$tamper_root"
  rm -f "$tamper_root/source/sub/b.txt"
  args=(--dest "$tamper_root/dest" --config-file "$tamper_root/config/profile.conf" \
    --manual-file "$tamper_root/manual" --collectors-file "$tamper_root/collectors" \
    --retention-file "$tamper_root/retention")
  env TMPDIR="$tamper_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$tamper_root/output.run"
  snapshot="$(latest_snapshot "$tamper_root/dest")"
  "$BACKUP_HOME" "${args[@]}" verify "$snapshot" --deep >"$tamper_root/output.before"
  printf 'omega\n' >"$tamper_root/dest/snapshots/$snapshot${tamper_root}/source/a.txt"
  expect_rc 1 "$tamper_root/output.after" "$BACKUP_HOME" "${args[@]}" verify "$snapshot" --deep --ignore-errors
  assert_contains "$tamper_root/output.after" "CHECKSUM VERIFICATION FAILED"

  write_base_case "$legacy_root"
  mkdir -p "$legacy_root/dest/snapshots/$legacy_name${legacy_root}/source/sub" \
    "$legacy_root/dest/snapshots/$legacy_name/home/fixture" \
    "$legacy_root/restore" "$legacy_root/target-home" "$legacy_root/state"
  cp "$legacy_root/source/a.txt" "$legacy_root/dest/snapshots/$legacy_name${legacy_root}/source/a.txt"
  cp "$legacy_root/source/sub/b.txt" "$legacy_root/dest/snapshots/$legacy_name${legacy_root}/source/sub/b.txt"
  printf 'legacy-home\n' >"$legacy_root/dest/snapshots/$legacy_name/home/fixture/data.txt"
  args=(--dest "$legacy_root/dest" --config-file "$legacy_root/config/profile.conf" \
    --manual-file "$legacy_root/manual" --collectors-file "$legacy_root/collectors" \
    --retention-file "$legacy_root/retention")
  "$BACKUP_HOME" "${args[@]}" list >"$legacy_root/output.list"
  assert_contains "$legacy_root/output.list" "$legacy_name [legacy]"
  "$BACKUP_HOME" "${args[@]}" verify "$legacy_name" >"$legacy_root/output.verify" 2>&1
  assert_contains "$legacy_root/output.verify" "Legacy snapshot"
  expect_rc 1 "$legacy_root/output.deep" "$BACKUP_HOME" "${args[@]}" verify "$legacy_name" --deep
  "$BACKUP_HOME" "${args[@]}" restore "$legacy_name" --path "$legacy_root/source/a.txt" \
    --restore-to "$legacy_root/restore" --yes >"$legacy_root/output.restore"
  assert_file "$legacy_root/restore${legacy_root}/source/a.txt"
  expect_rc 1 "$legacy_root/output.plan-blocked" env XDG_STATE_HOME="$legacy_root/state" \
    "$BACKUP_HOME" "${args[@]}" restore-plan "$legacy_name" \
    --target-home "$legacy_root/target-home" --staging-dir "$legacy_root/staging-plan"
  assert_contains "$legacy_root/output.plan-blocked" "requires --allow-legacy"
  env XDG_STATE_HOME="$legacy_root/state" "$BACKUP_HOME" "${args[@]}" \
    restore-plan "$legacy_name" --allow-legacy --target-home "$legacy_root/target-home" \
    --staging-dir "$legacy_root/staging-plan-allowed" \
    --map-path "/home/fixture=$legacy_root/legacy-target" >"$legacy_root/output.plan-allowed"
  assert_contains "$legacy_root/output.plan-allowed" "Legacy snapshot has no manifest"
  env XDG_STATE_HOME="$legacy_root/state" "$BACKUP_HOME" "${args[@]}" \
    recover "$legacy_name" --allow-legacy --target-home "$legacy_root/target-home" \
    --staging-dir "$legacy_root/staging-recover" \
    --map-path "/home/fixture=$legacy_root/legacy-target" --component files.1 --yes \
    >"$legacy_root/output.recover"
  assert_file "$legacy_root/legacy-target/data.txt"
}

run_signal_cleanup_flow() {
  local root="$TEST_ROOT/signal"
  local pid
  local rc
  local index
  local -a args

  command -v setsid >/dev/null 2>&1 || fail "setsid is required for signal cleanup test"
  write_base_case "$root"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # The generated collector expands its argument.
    printf 'if [[ "${1:-}" == metadata ]]; then printf "protocol\\\\t1\\\\nbackup\\\\trequired\\\\nrestore\\\\tunsupported\\\\n"; exit; fi\n'
    printf 'trap "exit 130" TERM INT\n'
    printf 'touch %q\n' "$root/ready"
    printf 'while :; do sleep 1; done\n'
  } >"$root/wait-collector"
  chmod +x "$root/wait-collector"
  printf '10|required|waiter|%s\n' "$root/wait-collector" >"$root/collectors"
  args=(--dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" \
    --retention-file "$root/retention")

  setsid env TMPDIR="$root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$root/output" 2>&1 &
  pid=$!
  for ((index = 0; index < 50; index++)); do
    [[ -e "$root/ready" ]] && break
    sleep 0.1
  done
  [[ -e "$root/ready" ]] || fail "Signal test collector did not start"
  kill -TERM -- "-$pid"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "Interrupted run returned success"
  [[ -z "$(find "$root/dest/snapshots" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true)" ]] \
    || fail "Interrupted run published a snapshot"
  [[ -z "$(find "$root/tmp" -mindepth 1 -maxdepth 1 -name 'backup-home-stage.*' -print)" ]] \
    || fail "Interrupted run left staging data"
  assert_file "$(find "$root/dest/logs" -maxdepth 1 -name '*.failure.tsv' | head -n 1)"
}

run_collector_protocol_flow() {
  local root="$TEST_ROOT/protocol"
  local collector="$root/collector"
  local -a args

  write_base_case "$root"
  cat >"$collector" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  metadata)
    [[ -z "${BACKUP_HOME_AMBIENT_SENTINEL:-}" ]]
    [[ -z "${BACKUP_HOME_STAGE_DIR:-}" ]]
    [[ -z "${BACKUP_HOME_GITHUB_CONFIG:-}" ]]
    [[ -n "${BACKUP_HOME_COLLECTOR_TIMEOUT_SECONDS:-}" ]]
    printf 'protocol\t1\nbackup\trequired\nrestore\tunsupported\n'
    ;;
  backup)
    [[ -z "${BACKUP_HOME_AMBIENT_SENTINEL:-}" ]]
    [[ -z "${BACKUP_HOME_TARGET_HOME:-}" ]]
    [[ -z "${BACKUP_HOME_GITHUB_CONFIG:-}" ]]
    printf '%s\n' "$BACKUP_HOME_COLLECTOR_NAME" >>"$ORDER_FILE"
    env | sed -n '/^BACKUP_HOME_/s/=.*$/=<set>/p' | sort >"$BACKUP_HOME_STAGE_DIR/context.txt"
    [[ "$BACKUP_HOME_PROTOCOL_VERSION" == 1 ]]
    [[ -n "$BACKUP_HOME_COLLECTOR_PRIORITY" && -n "$BACKUP_HOME_RUN_ID" ]]
    [[ -n "$BACKUP_HOME_COLLECTOR_TIMEOUT_SECONDS" ]]
    [[ -n "$BACKUP_HOME_MANUAL_FILE" && -n "$BACKUP_HOME_COLLECTOR_STARTED_AT" ]]
    [[ "$BACKUP_HOME_STAGE_DIR" == "$BACKUP_HOME_ARTIFACT_DIR" ]]
    [[ -n "$BACKUP_HOME_SOURCE_UID" && -n "$BACKUP_HOME_HOSTNAME" ]]
    ;;
  restore) exit 64 ;;
esac
EOF
  chmod +x "$collector"
  args=(--dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" \
    --retention-file "$root/retention")

  {
    printf '20|required|later|%s\n' "$collector"
    printf '10|required|earlier|%s|5\n' "$collector"
  } >"$root/collectors"
  "$BACKUP_HOME" "${args[@]}" plan >"$root/plan"
  assert_contains "$root/plan" "timeout=5s"
  assert_contains "$root/plan" "timeout=1800s"
  env ORDER_FILE="$root/order" TMPDIR="$root/tmp" BACKUP_HOME_AMBIENT_SENTINEL=leak \
    BACKUP_HOME_TARGET_HOME=/ambient/target BACKUP_HOME_GITHUB_CONFIG=/ambient/github \
    "$BACKUP_HOME" "${args[@]}" run --yes >"$root/output"
  assert_equal $'earlier\nlater' "$(cat "$root/order")" "Collector priority order"
  snapshot="$(latest_snapshot "$root/dest")"
  assert_file "$root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/earlier/context.txt"
  assert_contains "$root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'collector\tearlier\trequired\tsuccess\t0\t'
  assert_contains "$root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'\t10\t1\tunsupported'

  printf 'required|legacy|%s\n' "$collector" >"$root/collectors"
  expect_rc 1 "$root/old-format" "$BACKUP_HOME" "${args[@]}" plan
  assert_contains "$root/old-format" "Legacy 3-column collector entry"
  {
    printf '10|required|one|%s\n' "$collector"
    printf '10|required|two|%s\n' "$collector"
  } >"$root/collectors"
  expect_rc 1 "$root/duplicate-priority" "$BACKUP_HOME" "${args[@]}" plan
  assert_contains "$root/duplicate-priority" "Duplicate collector priority"
  {
    printf '10|required|same|%s\n' "$collector"
    printf '20|required|same|%s\n' "$collector"
  } >"$root/collectors"
  expect_rc 1 "$root/duplicate-name" "$BACKUP_HOME" "${args[@]}" plan
  assert_contains "$root/duplicate-name" "Duplicate collector name"
  printf 'first|required|invalid|%s\n' "$collector" >"$root/collectors"
  expect_rc 1 "$root/invalid-priority" "$BACKUP_HOME" "${args[@]}" plan
  assert_contains "$root/invalid-priority" "non-negative integer"
  printf '10|required|invalid-timeout|%s|0\n' "$collector" >"$root/collectors"
  expect_rc 1 "$root/invalid-timeout" "$BACKUP_HOME" "${args[@]}" plan
  assert_contains "$root/invalid-timeout" "timeout must be a positive integer"
}

main() {
  local dependency
  for dependency in rsync flock sha256sum shuf shellcheck setsid timeout; do
    command -v "$dependency" >/dev/null 2>&1 || fail "Missing test dependency: $dependency"
  done
  run_core_flow
  run_zero_exclude_flow
  run_profile_symlink_flow
  run_collector_flows
  run_docker_config_flow
  run_recovery_flows
  run_manifest_compatibility_flow
  run_failure_and_integrity_flows
  run_signal_cleanup_flow
  run_collector_protocol_flow
  printf 'All backup-home integration tests passed.\n'
}

main "$@"
