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

run_collector_flows() {
  local root="$TEST_ROOT/collectors"
  local required_root="$root/required"
  local optional_root="$root/optional"
  local inventory_root="$root/inventory"
  local dry_root="$root/dry"
  local snapshot
  local output
  local -a args

  write_base_case "$required_root"
  output="$required_root/output"
  # shellcheck disable=SC2016 # The generated collector expands this variable when it runs.
  printf '#!/usr/bin/env bash\nmkdir -p -- "$BACKUP_HOME_STAGE_DIR"\nexit 23\n' >"$required_root/fail-collector"
  chmod +x "$required_root/fail-collector"
  printf 'required|must-pass|%s\n' "$required_root/fail-collector" >"$required_root/collectors"
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
  printf 'optional|may-fail|%s\n' "$optional_root/fail-collector" >"$optional_root/collectors"
  args=(--dest "$optional_root/dest" --config-file "$optional_root/config/profile.conf" \
    --manual-file "$optional_root/manual" --collectors-file "$optional_root/collectors" \
    --retention-file "$optional_root/retention")
  env TMPDIR="$optional_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$optional_root/output"
  snapshot="$(latest_snapshot "$optional_root/dest")"
  assert_contains "$optional_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'status\tsuccess-with-warnings'
  assert_dir "$optional_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/may-fail"

  write_base_case "$inventory_root"
  mkdir -p "$inventory_root/fake-home"
  printf 'required|system-inventory|builtin:system-inventory\n' >"$inventory_root/collectors"
  args=(--dest "$inventory_root/dest" --config-file "$inventory_root/config/profile.conf" \
    --manual-file "$inventory_root/manual" --collectors-file "$inventory_root/collectors" \
    --retention-file "$inventory_root/retention")
  env HOME="$inventory_root/fake-home" TMPDIR="$inventory_root/tmp" \
    "$BACKUP_HOME" "${args[@]}" run --yes >"$inventory_root/output"
  snapshot="$(latest_snapshot "$inventory_root/dest")"
  assert_file "$inventory_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/system-inventory/RESTORE.md"
  assert_file "$inventory_root/dest/snapshots/$snapshot/.backup-home/artifacts/collectors/system-inventory/tool-versions.txt"

  write_base_case "$dry_root"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$dry_root/executed" >"$dry_root/sentinel-collector"
  chmod +x "$dry_root/sentinel-collector"
  printf 'required|sentinel|%s\n' "$dry_root/sentinel-collector" >"$dry_root/collectors"
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
  local handler
  local collector
  local -a args

  write_base_case "$filesystem_root"
  mkdir -p "$filesystem_root/target-home" "$filesystem_root/state"
  args=(--dest "$filesystem_root/dest" --config-file "$filesystem_root/config/profile.conf" \
    --manual-file "$filesystem_root/manual" --collectors-file "$filesystem_root/collectors" \
    --retention-file "$filesystem_root/retention")
  env TMPDIR="$filesystem_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$filesystem_root/output.run"
  snapshot="$(latest_snapshot "$filesystem_root/dest")"
  assert_contains "$filesystem_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'schema_version\t2'
  assert_contains "$filesystem_root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'source_uid\t'

  env XDG_STATE_HOME="$filesystem_root/state" "$BACKUP_HOME" "${args[@]}" \
    restore-plan "$snapshot" --target-home "$filesystem_root/target-home" \
    --staging-dir "$filesystem_root/staging-plan" \
    --map-path "$filesystem_root/source=$filesystem_root/target/restored" \
    >"$filesystem_root/output.plan"
  assert_contains "$filesystem_root/output.plan" "Manifest schema: 2"
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
  handler="$handler_root/handler"
  # shellcheck disable=SC2016 # The generated collector expands this variable when invoked.
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nprintf "collector guidance\\n" >"$BACKUP_HOME_STAGE_DIR/RESTORE.md"\n' >"$collector"
  chmod +x "$collector"
  {
    printf 'required|custom|%s\n' "$collector"
    printf 'required|unknown|%s\n' "$collector"
  } >"$handler_root/collectors"
  cat >"$handler" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  describe)
    printf 'component\tcustom.safe\tCustom safe restore\tautomatic\tsafe\trecommended\n'
    printf 'component\tcustom.destructive\tCustom destructive restore\tautomatic\tdestructive\toptional\n'
    ;;
  preflight) printf 'ok\tFake handler is ready\n' ;;
  apply) touch "$BACKUP_HOME_RESTORE_SESSION_DIR/$2.applied" ;;
  verify) test -f "$BACKUP_HOME_RESTORE_SESSION_DIR/$2.applied" ;;
  guide) printf 'Review the fake handler result.\n' ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$handler"
  printf 'custom|%s\n' "$handler" >"$handler_root/handlers"
  args=(--dest "$handler_root/dest" --config-file "$handler_root/config/profile.conf" \
    --manual-file "$handler_root/manual" --collectors-file "$handler_root/collectors" \
    --retention-file "$handler_root/retention" --handlers-file "$handler_root/handlers")
  env TMPDIR="$handler_root/tmp" "$BACKUP_HOME" "${args[@]}" run --yes >"$handler_root/output.run"
  snapshot="$(latest_snapshot "$handler_root/dest")"
  env XDG_STATE_HOME="$handler_root/state" "$BACKUP_HOME" "${args[@]}" \
    recover "$snapshot" --target-home "$handler_root/target-home" \
    --staging-dir "$handler_root/staging" --all --yes >"$handler_root/output.recover"
  session="$(latest_recovery_session "$handler_root/state")"
  state_file="$handler_root/state/backup-home/recovery/$session/state.tsv"
  assert_file "$handler_root/state/backup-home/recovery/$session/custom.safe.applied"
  assert_not_exists "$handler_root/state/backup-home/recovery/$session/custom.destructive.applied"
  assert_contains "$state_file" $'component\tcustom.destructive\tmanual-pending'

  env XDG_STATE_HOME="$handler_root/state" "$BACKUP_HOME" --dest "$handler_root/dest" \
    --handlers-file "$handler_root/handlers" recover --resume "$session" \
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

run_failure_and_integrity_flows() {
  local root="$TEST_ROOT/failures"
  local rsync_root="$root/rsync"
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
  mkdir -p "$legacy_root/dest/snapshots/$legacy_name${legacy_root}/source/sub"
  cp "$legacy_root/source/a.txt" "$legacy_root/dest/snapshots/$legacy_name${legacy_root}/source/a.txt"
  cp "$legacy_root/source/sub/b.txt" "$legacy_root/dest/snapshots/$legacy_name${legacy_root}/source/sub/b.txt"
  args=(--dest "$legacy_root/dest" --config-file "$legacy_root/config/profile.conf" \
    --manual-file "$legacy_root/manual" --collectors-file "$legacy_root/collectors" \
    --retention-file "$legacy_root/retention")
  "$BACKUP_HOME" "${args[@]}" list >"$legacy_root/output.list"
  assert_contains "$legacy_root/output.list" "$legacy_name [legacy]"
  "$BACKUP_HOME" "${args[@]}" verify "$legacy_name" >"$legacy_root/output.verify" 2>&1
  assert_contains "$legacy_root/output.verify" "Legacy snapshot"
  expect_rc 1 "$legacy_root/output.deep" "$BACKUP_HOME" "${args[@]}" verify "$legacy_name" --deep
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
    printf 'trap "exit 130" TERM INT\n'
    printf 'touch %q\n' "$root/ready"
    printf 'while :; do sleep 1; done\n'
  } >"$root/wait-collector"
  chmod +x "$root/wait-collector"
  printf 'required|waiter|%s\n' "$root/wait-collector" >"$root/collectors"
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

main() {
  local dependency
  for dependency in rsync flock sha256sum shuf shellcheck setsid; do
    command -v "$dependency" >/dev/null 2>&1 || fail "Missing test dependency: $dependency"
  done
  run_core_flow
  run_zero_exclude_flow
  run_collector_flows
  run_docker_config_flow
  run_recovery_flows
  run_failure_and_integrity_flows
  run_signal_cleanup_flow
  printf 'All backup-home integration tests passed.\n'
}

main "$@"
