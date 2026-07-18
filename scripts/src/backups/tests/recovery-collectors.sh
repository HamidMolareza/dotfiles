#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
BACKUP_HOME="$PROJECT_DIR/backup-home"
SQLITE_HELPER="$PROJECT_DIR/lib/sqlite-backup.py"
TEST_ROOT="$(mktemp -d /tmp/backup-home-recovery-tests.XXXXXX)"

cleanup() {
  [[ "$TEST_ROOT" == /tmp/backup-home-recovery-tests.* ]] || exit 1
  rm -rf --one-file-system -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "Expected file: $1"; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "Expected '$2' in $1"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "Unexpected '$2' in $1"; }

expect_rc() {
  local expected="$1" output="$2" actual
  shift 2
  set +e
  "$@" >"$output" 2>&1
  actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || { sed -n '1,200p' "$output" >&2; fail "Expected rc=$expected, got $actual"; }
}

create_sqlite() {
  python3 - "$1" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("create table if not exists sample(value integer)")
connection.execute("insert into sample values (42)")
connection.commit()
connection.close()
PY
}

run_sensitive_policy_tests() {
  local root="$TEST_ROOT/sensitive" snapshot
  mkdir -p "$root/source" "$root/dest" "$root/config" "$root/fakebin"
  printf 'private\n' >"$root/source/data"
  : >"$root/manual"; : >"$root/collectors"; printf 'keep_last=1\n' >"$root/retention"
  cat >"$root/fakebin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/dev/test-destination\n'
EOF
  cat >"$root/fakebin/lsblk" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${TEST_ENCRYPTION_FS:-ext4}"
EOF
  chmod +x "$root/fakebin/findmnt" "$root/fakebin/lsblk"
  {
    printf 'include=%s\n' "$root/source"
    printf 'sensitive=yes\n'
    printf 'unencrypted_destination=warn\n'
  } >"$root/config/profile.conf"
  env PATH="$root/fakebin:$PATH" TEST_ENCRYPTION_FS=ext4 \
    "$BACKUP_HOME" --dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" --retention-file "$root/retention" \
    plan >"$root/plan" 2>&1
  assert_contains "$root/plan" "Destination encryption: not-detected (warn policy)"
  env PATH="$root/fakebin:$PATH" TEST_ENCRYPTION_FS=ext4 \
    "$BACKUP_HOME" --dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" --retention-file "$root/retention" \
    run --yes >"$root/run" 2>&1
  snapshot="$(find "$root/dest/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"
  assert_contains "$root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'sensitive_profile\tyes'
  assert_contains "$root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'destination_encryption_state\tnot-detected'
  assert_contains "$root/dest/snapshots/$snapshot/.backup-home/manifest.tsv" $'status\tsuccess-with-warnings'

  sed -i 's/unencrypted_destination=warn/unencrypted_destination=require/' "$root/config/profile.conf"
  expect_rc 1 "$root/require-failed" env PATH="$root/fakebin:$PATH" TEST_ENCRYPTION_FS=ext4 \
    "$BACKUP_HOME" --dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" --retention-file "$root/retention" plan
  env PATH="$root/fakebin:$PATH" TEST_ENCRYPTION_FS=$'ext4\ncrypto_LUKS' \
    "$BACKUP_HOME" --dest "$root/dest" --config-file "$root/config/profile.conf" \
    --manual-file "$root/manual" --collectors-file "$root/collectors" --retention-file "$root/retention" \
    plan >"$root/encrypted-plan"
  assert_contains "$root/encrypted-plan" "Destination encryption: detected (require policy)"
}

run_sqlite_helper_test() {
  local root="$TEST_ROOT/sqlite" writer
  mkdir -p "$root"
  cat >"$root/writer.py" <<'PY'
import pathlib
import sqlite3
import sys
import time
database, ready = sys.argv[1:]
connection = sqlite3.connect(database)
connection.execute("pragma journal_mode=wal")
connection.execute("create table events(value integer)")
connection.execute("insert into events values (42)")
connection.commit()
pathlib.Path(ready).touch()
time.sleep(30)
PY
  python3 "$root/writer.py" "$root/live.sqlite" "$root/ready" &
  writer=$!
  for _ in {1..100}; do [[ -e "$root/ready" ]] && break; sleep 0.05; done
  [[ -e "$root/ready" ]] || fail "Live SQLite fixture did not start"
  python3 "$SQLITE_HELPER" backup "$root/live.sqlite" "$root/backup.sqlite"
  python3 "$SQLITE_HELPER" check "$root/backup.sqlite"
  [[ "$(python3 - "$root/backup.sqlite" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("select value from events").fetchone()[0])
PY
)" == 42 ]] || fail "SQLite online backup missed WAL data"
  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
}

run_credentials_collector_test() {
  local root="$TEST_ROOT/credentials"
  mkdir -p "$root/home/Private/.ssh" "$root/home/.local/share/keyrings" "$root/stage"
  printf 'fixture-private-key\n' >"$root/home/Private/.ssh/id_test"
  chmod 600 "$root/home/Private/.ssh/id_test"
  printf 'fixture-keyring\n' >"$root/home/.local/share/keyrings/login.keyring"
  printf 'ssh-gpg|Private/.ssh\nkeyring|.local/share/keyrings\n' >"$root/config"
  env BACKUP_HOME_STAGE_DIR="$root/stage" BACKUP_HOME_SOURCE_HOME="$root/home" \
    BACKUP_HOME_CREDENTIALS_CONFIG="$root/config" "$PROJECT_DIR/collectors/credentials-recovery"
  assert_file "$root/stage/ssh-gpg.tar"
  assert_file "$root/stage/keyring.tar"
  tar -tf "$root/stage/ssh-gpg.tar" >"$root/members"
  assert_contains "$root/members" "Private/.ssh/id_test"
  assert_not_contains "$root/stage/index.tsv" "fixture-private-key"
  mkdir -p "$root/target" "$root/session"
  env BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_TARGET_HOME="$root/target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/restore-handlers/credentials-recovery" describe >"$root/describe"
  assert_contains "$root/describe" $'component\tcredentials.ssh-gpg'
}

run_codex_collector_test() {
  local root="$TEST_ROOT/codex"
  mkdir -p "$root/home/.codex" "$root/home/.local/share/example-mcp" "$root/stage"
  create_sqlite "$root/home/.codex/state.sqlite"
  printf 'legacy-format\n' >"$root/home/.local/share/example-mcp/legacy.db"
  cat >"$root/config" <<'EOF'
sqlite|codex|.codex/state.sqlite
static|mcp|.local/share/example-mcp/legacy.db
candidate-root|.codex
candidate-root|.local/share/example-mcp
EOF
  env BACKUP_HOME_STAGE_DIR="$root/stage" BACKUP_HOME_SOURCE_HOME="$root/home" \
    BACKUP_HOME_CODEX_MCP_CONFIG="$root/config" "$PROJECT_DIR/collectors/codex-mcp-recovery"
  assert_file "$root/stage/databases/codex/.codex/state.sqlite"
  python3 "$SQLITE_HELPER" check "$root/stage/databases/codex/.codex/state.sqlite"
  mkdir -p "$root/target" "$root/session"
  env BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_TARGET_HOME="$root/target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/restore-handlers/codex-mcp-recovery" describe >"$root/describe"
  assert_contains "$root/describe" $'component\tcodex.databases'
  assert_contains "$root/describe" $'component\tmcp.databases'
  create_sqlite "$root/home/.codex/unclassified.db"
  mkdir -p "$root/stage-fail"
  expect_rc 1 "$root/unclassified-output" env BACKUP_HOME_STAGE_DIR="$root/stage-fail" \
    BACKUP_HOME_SOURCE_HOME="$root/home" BACKUP_HOME_CODEX_MCP_CONFIG="$root/config" \
    "$PROJECT_DIR/collectors/codex-mcp-recovery"
  assert_contains "$root/unclassified-output" "Unconfigured SQLite-like file"
}

run_browser_collector_test() {
  local root="$TEST_ROOT/browser" profile="$TEST_ROOT/browser/home/firefox/test.default" uuid="fixture-uuid"
  mkdir -p "$profile/bookmarkbackups" "$profile/sessionstore-backups" \
    "$profile/storage/default/moz-extension+++$uuid/idb" "$root/home/chrome/Default" "$root/stage"
  cat >"$root/home/firefox/profiles.ini" <<'EOF'
[Profile0]
Name=default
IsRelative=1
Path=test.default
Default=1
EOF
  python3 - "$profile/prefs.js" "$uuid" <<'PY'
import json, pathlib, sys
mapping = json.dumps({"extension@one-tab.com": sys.argv[2]})
pathlib.Path(sys.argv[1]).write_text(f'user_pref("extensions.webextensions.uuids", {json.dumps(mapping)});\n')
PY
  printf '{"addons":[{"id":"extension@one-tab.com","version":"1","active":true}]}\n' >"$profile/extensions.json"
  printf 'bookmark-fixture\n' >"$profile/bookmarkbackups/latest.jsonlz4"
  printf 'session-fixture\n' >"$profile/sessionstore-backups/recovery.jsonlz4"
  create_sqlite "$profile/storage/default/moz-extension+++$uuid/idb/onetab.sqlite"
  printf '{"extensions":{"settings":{}}}\n' >"$root/home/chrome/Default/Preferences"
  printf '{"roots":{}}\n' >"$root/home/chrome/Default/Bookmarks"
  printf 'firefox-root|firefox\nchromium-root|chrome\nfirefox-extension|onetab|extension@one-tab.com|required\n' >"$root/config"
  env BACKUP_HOME_STAGE_DIR="$root/stage" BACKUP_HOME_SOURCE_HOME="$root/home" \
    BACKUP_HOME_BROWSER_CONFIG="$root/config" "$PROJECT_DIR/collectors/browser-recovery"
  assert_file "$root/stage/firefox/test.default/bookmarkbackups/latest.jsonlz4"
  assert_file "$root/stage/firefox/extensions/onetab/storage/idb/onetab.sqlite"
  assert_file "$root/stage/chromium/Default/extensions-inventory.json"
  [[ -z "$(find "$root/stage" \( -name Cookies -o -name History \) -print -quit)" ]] \
    || fail "Browser collector copied forbidden raw profile data"
  mkdir -p "$root/target" "$root/session"
  env BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_TARGET_HOME="$root/target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" BACKUP_HOME_BROWSER_CONFIG="$root/config" \
    "$PROJECT_DIR/restore-handlers/browser-recovery" describe >"$root/describe"
  assert_contains "$root/describe" $'component\tbrowser.bookmarks'
  assert_contains "$root/describe" $'component\tbrowser.onetab'
}

run_freshness_fallback_tests() {
  local root="$TEST_ROOT/freshness" bundle
  mkdir -p "$root/fakebin" "$root/github-success-home" "$root/github-success-stage"
  cat >"$root/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == auth && "${2:-}" == token ]]; then
  printf 'fixture-token\n'
elif [[ "${1:-}" == api && "${2:-}" == user ]]; then
  printf 'test\n'
elif [[ "${1:-}" == api && "$*" == *'/user/migrations?per_page=1'* ]]; then
  :
elif [[ "${1:-}" == api && "$*" == *'/user/repos?'* ]]; then
  [[ "$*" != *'--jq'* ]] || exit 88
  printf '[[]]\n'
elif [[ "${1:-}" == api && "$*" == *'/gists?'* ]]; then
  [[ "$*" != *'--jq'* ]] || exit 88
  printf '[[]]\n'
else
  exit 1
fi
EOF
  chmod +x "$root/fakebin/gh"
  printf 'account|test\ncache-relative|backups/github\nmax-age-hours|168\n' >"$root/github-success-config"
  env PATH="$root/fakebin:$PATH" BACKUP_HOME_STAGE_DIR="$root/github-success-stage" \
    BACKUP_HOME_SOURCE_HOME="$root/github-success-home" BACKUP_HOME_GITHUB_CONFIG="$root/github-success-config" \
    "$PROJECT_DIR/collectors/github-recovery"
  assert_contains "$root/github-success-stage/index.tsv" $'github-account\ttest\tbackups/github/accounts/test\tsuccess'
  assert_file "$root/github-success-stage/credentials/test.token"
  mkdir -p "$root/github-target" "$root/github-session" "$root/github-snapshot"
  env BACKUP_HOME_ARTIFACT_DIR="$root/github-success-stage" BACKUP_HOME_SOURCE_HOME="$root/github-success-home" \
    BACKUP_HOME_TARGET_HOME="$root/github-target" BACKUP_HOME_RESTORE_SESSION_DIR="$root/github-session" \
    BACKUP_HOME_SNAPSHOT_DIR="$root/github-snapshot" BACKUP_HOME_GITHUB_CONFIG="$root/github-success-config" \
    "$PROJECT_DIR/restore-handlers/github-recovery" describe >"$root/github-describe"
  assert_contains "$root/github-describe" $'component\tgithub.credentials'
  assert_contains "$root/github-describe" $'component\tgithub.remote-rebuild'

  mkdir -p "$root/github-home/backups/github/accounts/test" "$root/github-stage"
  cat >"$root/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$root/fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$root/fakebin/gh" "$root/fakebin/ssh"
  date +%s >"$root/github-home/backups/github/accounts/test/.last-success"
  printf 'account|test\ncache-relative|backups/github\nmax-age-hours|168\n' >"$root/github-config"
  env PATH="$root/fakebin:$PATH" BACKUP_HOME_STAGE_DIR="$root/github-stage" \
    BACKUP_HOME_SOURCE_HOME="$root/github-home" BACKUP_HOME_GITHUB_CONFIG="$root/github-config" \
    "$PROJECT_DIR/collectors/github-recovery"
  assert_contains "$root/github-stage/index.tsv" $'github-account\ttest\tbackups/github/accounts/test\tcached'

  mkdir -p "$root/server-home/backups/server/test/20260101T000000Z/databases" "$root/server-stage"
  bundle="$root/server-home/backups/server/test/20260101T000000Z"
  printf 'cached\n' >"$bundle/bundle.tsv"
  cat >"$root/server-config" <<'EOF'
host|test-server
cache-relative|backups/server/test
max-age-hours|24
config-path|/etc/example
config-exclude|/var/lib/example/*/access.log
sqlite|state|/var/lib/example/state.db|systemd:example.service
EOF
  env PATH="$root/fakebin:$PATH" BACKUP_HOME_STAGE_DIR="$root/server-stage" \
    BACKUP_HOME_SOURCE_HOME="$root/server-home" BACKUP_HOME_SERVER_CONFIG="$root/server-config" \
    "$PROJECT_DIR/collectors/server-recovery"
  assert_file "$root/server-stage/bundle/bundle.tsv"
  mkdir -p "$root/server-stage/bundle/databases" "$root/server-target" "$root/server-session"
  printf 'archive\n' >"$root/server-stage/bundle/server-config.tar"
  printf 'database\n' >"$root/server-stage/bundle/databases/state.sqlite"
  printf 'label\tremote_path\tservice\tartifact\tmode\tuid\tgid\nstate\t/var/lib/example/state.db\tsystemd:example.service\tdatabases/state.sqlite\t600\t0\t0\n' \
    >"$root/server-stage/bundle/databases.tsv"
  env BACKUP_HOME_ARTIFACT_DIR="$root/server-stage" BACKUP_HOME_TARGET_HOME="$root/server-target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/server-session" BACKUP_HOME_SERVER_CONFIG="$root/server-config" \
    "$PROJECT_DIR/restore-handlers/server-recovery" describe >"$root/server-describe"
  assert_contains "$root/server-describe" $'component\tserver.foundation'
  touch -d '2 days ago' "$bundle"
  mkdir -p "$root/server-stage-stale"
  expect_rc 1 "$root/server-stale-output" env PATH="$root/fakebin:$PATH" \
    BACKUP_HOME_STAGE_DIR="$root/server-stage-stale" BACKUP_HOME_SOURCE_HOME="$root/server-home" \
    BACKUP_HOME_SERVER_CONFIG="$root/server-config" "$PROJECT_DIR/collectors/server-recovery"
}

main() {
  local dependency
  for dependency in bash find gh git python3 rsync sha256sum ssh tar; do
    command -v "$dependency" >/dev/null 2>&1 || fail "Missing test dependency: $dependency"
  done
  run_sensitive_policy_tests
  run_sqlite_helper_test
  run_credentials_collector_test
  run_codex_collector_test
  run_browser_collector_test
  run_freshness_fallback_tests
  printf 'All recovery collector tests passed.\n'
}

main "$@"
