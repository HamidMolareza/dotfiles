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
assert_not_exists() { [[ ! -e "$1" ]] || fail "Expected path to be absent: $1"; }
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
    "$PROJECT_DIR/collectors/credentials-recovery" restore describe >"$root/describe"
  assert_contains "$root/describe" $'component\tcredentials.ssh-gpg'
}

run_codex_collector_test() {
  local root="$TEST_ROOT/codex"
  mkdir -p "$root/home/.codex" "$root/home/.local/share/example-mcp" \
    "$root/stage" "$root/stage-auto" "$root/stage-required-fail"
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
    "$PROJECT_DIR/collectors/codex-mcp-recovery" restore describe >"$root/describe"
  assert_contains "$root/describe" $'component\tcodex.databases'
  assert_contains "$root/describe" $'component\tmcp.databases'
  create_sqlite "$root/home/.codex/unclassified.db"
  printf 'not-a-sqlite-database\n' >"$root/home/.codex/unreadable.db"
  env BACKUP_HOME_STAGE_DIR="$root/stage-auto" \
    BACKUP_HOME_SOURCE_HOME="$root/home" BACKUP_HOME_CODEX_MCP_CONFIG="$root/config" \
    "$PROJECT_DIR/collectors/codex-mcp-recovery" >"$root/automatic-output" 2>&1
  assert_file "$root/stage-auto/databases/codex/.codex/unclassified.db"
  python3 "$SQLITE_HELPER" check "$root/stage-auto/databases/codex/.codex/unclassified.db"
  assert_contains "$root/stage-auto/warnings.txt" \
    "Automatically included unconfigured SQLite file: .codex/unclassified.db"
  assert_contains "$root/stage-auto/warnings.txt" \
    "Automatically discovered SQLite file could not be backed up and was skipped: .codex/unreadable.db"
  assert_contains "$root/stage-auto/index.tsv" \
    $'sqlite\t.codex/unclassified.db\tdatabases/codex/.codex/unclassified.db\tsuccess\tcodex;'
  assert_contains "$root/stage-auto/index.tsv" "discovery=automatic"
  assert_not_exists "$root/stage-auto/databases/codex/.codex/unreadable.db"
  printf 'sqlite|codex|.codex/missing.sqlite\n' >>"$root/config"
  expect_rc 1 "$root/required-failure-output" env \
    BACKUP_HOME_STAGE_DIR="$root/stage-required-fail" \
    BACKUP_HOME_SOURCE_HOME="$root/home" BACKUP_HOME_CODEX_MCP_CONFIG="$root/config" \
    "$PROJECT_DIR/collectors/codex-mcp-recovery"
  assert_contains "$root/required-failure-output" \
    "Required Codex/MCP database file is missing: .codex/missing.sqlite"
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
    "$PROJECT_DIR/collectors/browser-recovery" restore describe >"$root/describe"
  assert_contains "$root/describe" $'component\tbrowser.bookmarks'
  assert_contains "$root/describe" $'component\tbrowser.onetab'
}

run_knowledge_collector_test() {
  local root="$TEST_ROOT/knowledge"
  mkdir -p "$root/home/my-files/learning-daily/course/sub" "$root/stage" "$root/target" "$root/session"
  printf 'notes\n' >"$root/home/my-files/learning-daily/course/notes.md"
  printf 'image\n' >"$root/home/my-files/learning-daily/course/sub/diagram.PNG"
  printf 'binary\n' >"$root/home/my-files/learning-daily/course/archive.zip"
  cat >"$root/config" <<'EOF'
source-relative|my-files/learning-daily
extensions|png,md,pdf
EOF
  env BACKUP_HOME_STAGE_DIR="$root/stage" BACKUP_HOME_SOURCE_HOME="$root/home" \
    BACKUP_HOME_KNOWLEDGE_CONFIG="$root/config" \
    "$PROJECT_DIR/collectors/knowledge-recovery" backup
  assert_file "$root/stage/files/my-files/learning-daily/course/notes.md"
  assert_file "$root/stage/files/my-files/learning-daily/course/sub/diagram.PNG"
  [[ ! -e "$root/stage/files/my-files/learning-daily/course/archive.zip" ]] \
    || fail "Knowledge collector copied an extension outside the allowlist"
  env BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_TARGET_HOME="$root/target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/knowledge-recovery" restore describe >"$root/describe"
  assert_contains "$root/describe" $'component\tknowledge.files'
  env BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_TARGET_HOME="$root/target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/knowledge-recovery" restore apply knowledge.files
  assert_file "$root/target/my-files/learning-daily/course/notes.md"

  printf 'source-relative\t../escaped-target\nextensions\tmd\n' >"$root/stage/selection.tsv"
  expect_rc 1 "$root/traversal-output" env BACKUP_HOME_ARTIFACT_DIR="$root/stage" \
    BACKUP_HOME_TARGET_HOME="$root/target" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/knowledge-recovery" restore apply knowledge.files
  assert_contains "$root/traversal-output" "Dot path segments are not allowed"
  [[ ! -e "$root/escaped-target" ]] || fail "Knowledge traversal wrote outside the target home"

  printf 'source-relative\tlinked-tree\nextensions\tmd\n' >"$root/stage/selection.tsv"
  mkdir -p "$root/outside-tree"
  printf 'outside\n' >"$root/outside-tree/file.md"
  ln -s "$root/outside-tree" "$root/stage/files/linked-tree"
  expect_rc 1 "$root/symlink-escape-output" env BACKUP_HOME_ARTIFACT_DIR="$root/stage" \
    BACKUP_HOME_TARGET_HOME="$root/target" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/knowledge-recovery" restore apply knowledge.files
  assert_contains "$root/symlink-escape-output" "escapes its artifact root"
  [[ ! -e "$root/target/linked-tree" ]] || fail "Knowledge symlink escape mutated the target"
}

run_system_inventory_collector_test() {
  local root="$TEST_ROOT/system-inventory"
  local before after
  mkdir -p "$root/home/.config/nautilus" "$root/home/.dotfiles/nautilus/scripts" \
    "$root/home/.local/share/nautilus" "$root/stage" "$root/fakebin" "$root/session" \
    "$root/restore-stage" "$root/partial-dconf-stage"
  printf 'nautilus-setting\n' >"$root/home/.config/nautilus/preferences"
  printf '#!/usr/bin/env bash\nprintf fixture\n' >"$root/home/.dotfiles/nautilus/scripts/fixture-script"
  chmod +x "$root/home/.dotfiles/nautilus/scripts/fixture-script"
  ln -s "$root/home/.dotfiles/nautilus/scripts" "$root/home/.local/share/nautilus/scripts"
  printf '[desktop]\nvalue=backup\n' >"$root/dconf-state"
  printf '[backup]\nlocation=original\n' >"$root/deja-state"
  printf '0 1 * * * backup-command\n' >"$root/crontab-state"
  cat >"$root/fakebin/dconf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
scope="${2:-/}"
[[ "${1:-}" != reset ]] || scope="${3:-/}"
case "${1:-}" in
  dump)
    if [[ "${TEST_DCONF_PARTIAL_DUMP:-0}" -eq 1 ]]; then
      printf '[partial]\nvalue=incomplete\n'
      exit 7
    fi
    [[ "${TEST_DCONF_FAIL_DUMP:-0}" -eq 0 ]] || exit 9
    [[ "$scope" == /org/gnome/deja-dup/ ]] && cat "$TEST_DEJA_STATE" || cat "$TEST_DCONF_STATE"
    ;;
  load)
    [[ "$scope" == /org/gnome/deja-dup/ ]] && cat >"$TEST_DEJA_STATE" || cat >"$TEST_DCONF_STATE"
    ;;
  reset)
    printf '%s\n' "$scope" >>"$TEST_DCONF_LOG"
    [[ "$scope" == /org/gnome/deja-dup/ ]] && : >"$TEST_DEJA_STATE" || : >"$TEST_DCONF_STATE"
    ;;
  *) exit 1 ;;
esac
EOF
  cat >"$root/fakebin/apt-mark" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == showmanual ]] || exit 1
printf 'git\n'
EOF
  cat >"$root/fakebin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --get-selections ]] || exit 1
printf 'git\tinstall\n'
EOF
  cat >"$root/fakebin/crontab" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == -l ]]; then
  if [[ -f "$TEST_CRONTAB_STATE" ]]; then cat "$TEST_CRONTAB_STATE"; else printf 'no crontab for fixture\n' >&2; exit 1; fi
else
  cp -- "$1" "$TEST_CRONTAB_STATE"
fi
EOF
  chmod +x "$root/fakebin/dconf" "$root/fakebin/crontab" "$root/fakebin/apt-mark" \
    "$root/fakebin/dpkg"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_STAGE_DIR="$root/stage" \
    BACKUP_HOME_SOURCE_HOME="$root/home" \
    "$PROJECT_DIR/collectors/system-inventory" backup
  assert_file "$root/stage/dconf.ini"
  assert_file "$root/stage/deja-dup.dconf"
  assert_file "$root/stage/tool-versions.tsv"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" TEST_DCONF_PARTIAL_DUMP=1 \
    BACKUP_HOME_STAGE_DIR="$root/partial-dconf-stage" \
    BACKUP_HOME_SOURCE_HOME="$root/home" \
    "$PROJECT_DIR/collectors/system-inventory" backup
  assert_contains "$root/partial-dconf-stage/warnings.txt" "dconf export inventory failed"
  assert_contains "$root/partial-dconf-stage/warnings.txt" "Deja Dup dconf export inventory failed"
  assert_not_exists "$root/partial-dconf-stage/dconf.ini"
  assert_not_exists "$root/partial-dconf-stage/deja-dup.dconf"
  [[ -z "$(find "$root/partial-dconf-stage" -name '*.tmp.*' -print -quit)" ]] \
    || fail "Failed dconf inventory left a partial temporary artifact"
  [[ -d "$root/stage/nautilus/.local/share/nautilus/scripts" \
    && ! -L "$root/stage/nautilus/.local/share/nautilus/scripts" ]] \
    || fail "Nautilus source symlink was not materialized as a regular artifact directory"
  assert_file "$root/stage/nautilus/.local/share/nautilus/scripts/fixture-script"
  [[ -z "$(find "$root/stage/nautilus" -type l -print -quit)" ]] \
    || fail "Nautilus backup artifact unexpectedly contains a symlink"
  printf 'curl\ngit\n' >"$root/stage/apt-manual.txt"
  printf 'git\tinstall\n' >"$root/stage/dpkg-selections.txt"
  printf 'Name Version Rev Tracking Publisher Notes\nexample 1 1 latest/stable test -\n' >"$root/stage/snap-list.txt"
  printf 'org.example.App\tstable\tflathub\n' >"$root/stage/flatpak-apps.tsv"
  before="$(sha256sum "$root/dconf-state" "$root/deja-state" "$root/crontab-state")"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore describe >"$root/describe"
  assert_contains "$root/describe" $'component\tsystem.dconf'
  assert_contains "$root/describe" $'component\tsystem.deja-dup'
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore preflight system.dconf >"$root/preflight"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore guide system.dconf >"$root/guide"
  after="$(sha256sum "$root/dconf-state" "$root/deja-state" "$root/crontab-state")"
  [[ "$before" == "$after" ]] || fail "Read-only system restore actions mutated user state"

  printf '[desktop]\nvalue=current\nextra=must-be-removed\n' >"$root/dconf-state"
  expect_rc 1 "$root/no-approval" env PATH="$root/fakebin:$PATH" \
    TEST_DCONF_STATE="$root/dconf-state" TEST_DEJA_STATE="$root/deja-state" \
    TEST_CRONTAB_STATE="$root/crontab-state" BACKUP_HOME_ARTIFACT_DIR="$root/stage" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.dconf
  assert_contains "$root/dconf-state" "value=current"
  expect_rc 1 "$root/preservation-failure" env PATH="$root/fakebin:$PATH" \
    TEST_DCONF_STATE="$root/dconf-state" TEST_DEJA_STATE="$root/deja-state" \
    TEST_CRONTAB_STATE="$root/crontab-state" TEST_DCONF_FAIL_DUMP=1 \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.dconf
  assert_contains "$root/preservation-failure" "Could not preserve current dconf state"
  assert_contains "$root/dconf-state" "value=current"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.dconf
  assert_contains "$root/session/pre-restore/system.dconf/dconf.ini" "extra=must-be-removed"
  assert_contains "$root/dconf.log" "/"
  assert_not_contains "$root/dconf-state" "extra=must-be-removed"
  [[ "$(stat -c %a "$root/session/pre-restore/system.dconf")" == 700 ]] \
    || fail "System dconf safety directory is not private"
  [[ "$(stat -c %a "$root/session/pre-restore/system.dconf/dconf.ini")" == 600 ]] \
    || fail "System dconf safety file is not private"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore verify system.dconf
  printf '[desktop]\nvalue=tampered\n' >"$root/dconf-state"
  expect_rc 1 "$root/dconf-mismatch" env PATH="$root/fakebin:$PATH" \
    TEST_DCONF_STATE="$root/dconf-state" TEST_DEJA_STATE="$root/deja-state" \
    TEST_CRONTAB_STATE="$root/crontab-state" BACKUP_HOME_ARTIFACT_DIR="$root/stage" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore verify system.dconf

  printf '[backup]\nlocation=current\n' >"$root/deja-state"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.deja-dup
  assert_contains "$root/session/pre-restore/system.deja-dup/deja-dup.dconf" "location=current"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore verify system.deja-dup

  printf '5 4 * * * current-command\n' >"$root/crontab-state"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    TEST_DCONF_LOG="$root/dconf.log" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.crontab
  assert_contains "$root/session/pre-restore/system.crontab/crontab.txt" "current-command"
  env PATH="$root/fakebin:$PATH" TEST_DCONF_STATE="$root/dconf-state" \
    TEST_DEJA_STATE="$root/deja-state" TEST_CRONTAB_STATE="$root/crontab-state" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore verify system.crontab
  printf '9 9 * * * tampered\n' >"$root/crontab-state"
  expect_rc 1 "$root/crontab-mismatch" env PATH="$root/fakebin:$PATH" \
    TEST_DCONF_STATE="$root/dconf-state" TEST_DEJA_STATE="$root/deja-state" \
    TEST_CRONTAB_STATE="$root/crontab-state" BACKUP_HOME_ARTIFACT_DIR="$root/stage" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    "$PROJECT_DIR/collectors/system-inventory" restore verify system.crontab

  expect_rc 20 "$root/packages-output" env PATH="$root/fakebin:$PATH" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_RESTORE_STAGING_DIR="$root/restore-stage" \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.packages
  assert_file "$root/restore-stage/artifacts/system.packages/PACKAGE-RECOVERY.md"
  assert_file "$root/restore-stage/artifacts/system.packages/dpkg-selections.txt"
  assert_file "$root/restore-stage/artifacts/system.packages/snap-list.txt"
  assert_file "$root/restore-stage/artifacts/system.packages/flatpak-apps.tsv"
  assert_contains "$root/restore-stage/artifacts/system.packages/missing-apt-manual.txt" "curl"
  assert_not_contains "$root/restore-stage/artifacts/system.packages/missing-apt-manual.txt" "git"

  expect_rc 20 "$root/nautilus-output" env PATH="$root/fakebin:$PATH" \
    BACKUP_HOME_ARTIFACT_DIR="$root/stage" BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_RESTORE_STAGING_DIR="$root/restore-stage" BACKUP_HOME_TARGET_HOME="$root/home" \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.nautilus
  assert_file "$root/restore-stage/artifacts/system.nautilus/NAUTILUS-RECOVERY.md"
  assert_file "$root/restore-stage/artifacts/system.nautilus/data/.local/share/nautilus/scripts/fixture-script"
  assert_contains "$root/restore-stage/artifacts/system.nautilus/NAUTILUS-RECOVERY.md" \
    "No files were merged into the target home"

  mkdir -p "$root/malicious-artifact/nautilus" "$root/malicious-outside" \
    "$root/malicious-restore-stage"
  cp -a -- "$root/stage/." "$root/malicious-artifact/"
  ln -s "$root/malicious-outside" "$root/malicious-artifact/nautilus/escape"
  expect_rc 1 "$root/nautilus-malicious-output" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/malicious-artifact" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/session" \
    BACKUP_HOME_RESTORE_STAGING_DIR="$root/malicious-restore-stage" \
    BACKUP_HOME_TARGET_HOME="$root/home" \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.nautilus
  assert_contains "$root/nautilus-malicious-output" \
    "Nautilus recovery artifact must not contain symlinks"
  [[ ! -e "$root/malicious-restore-stage/artifacts/system.nautilus" ]] \
    || fail "Rejected Nautilus artifact left a misleading staged recovery"
  [[ -z "$(find "$root/malicious-outside" -mindepth 1 -print -quit)" ]] \
    || fail "Malicious Nautilus artifact wrote outside recovery staging"

  mkdir -p "$root/failure-fakebin" "$root/failure-stage" "$root/absent-stage" \
    "$root/dpkg-only-artifact" "$root/dpkg-only-restore-stage"
  cat >"$root/failure-fakebin/apt-mark" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_INVENTORY_MODE:-failure}" == failure ]]; then
  printf 'partial-apt\n'
  exit 7
fi
printf 'git\n'
EOF
  cat >"$root/failure-fakebin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_INVENTORY_MODE:-failure}" == failure ]]; then
  printf 'partial-dpkg\tinstall\n'
  exit 8
fi
printf 'git\tinstall\n'
EOF
  cat >"$root/failure-fakebin/crontab" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_INVENTORY_MODE:-failure}" == absent ]]; then
  printf 'no crontab for fixture\n' >&2
  exit 1
fi
printf 'permission denied: SENSITIVE_STDERR_MUST_NOT_LEAK\n' >&2
exit 2
EOF
  chmod +x "$root/failure-fakebin/apt-mark" "$root/failure-fakebin/dpkg" \
    "$root/failure-fakebin/crontab"
  env PATH="$root/failure-fakebin:$root/fakebin:$PATH" TEST_INVENTORY_MODE=failure \
    TEST_DCONF_STATE="$root/dconf-state" TEST_DEJA_STATE="$root/deja-state" \
    TEST_DCONF_LOG="$root/dconf.log" BACKUP_HOME_STAGE_DIR="$root/failure-stage" \
    BACKUP_HOME_SOURCE_HOME="$root/home" \
    "$PROJECT_DIR/collectors/system-inventory" backup
  assert_contains "$root/failure-stage/warnings.txt" \
    "APT manual package inventory failed; apt-manual.txt was not created"
  assert_contains "$root/failure-stage/warnings.txt" \
    "dpkg selection inventory failed; dpkg-selections.txt was not created"
  assert_contains "$root/failure-stage/warnings.txt" \
    "crontab inventory failed; crontab.txt was not created"
  assert_contains "$root/failure-stage/index.tsv" $'inventory\tsystem\tsystem\twarning'
  assert_not_contains "$root/failure-stage/warnings.txt" "SENSITIVE_STDERR_MUST_NOT_LEAK"
  [[ ! -e "$root/failure-stage/apt-manual.txt" \
    && ! -e "$root/failure-stage/dpkg-selections.txt" \
    && ! -e "$root/failure-stage/crontab.txt" ]] \
    || fail "Failed inventory command left a stale or partial artifact"
  assert_contains "$root/failure-stage/crontab-status.tsv" $'status\terror'

  env PATH="$root/failure-fakebin:$root/fakebin:$PATH" TEST_INVENTORY_MODE=absent \
    TEST_DCONF_STATE="$root/dconf-state" TEST_DEJA_STATE="$root/deja-state" \
    TEST_DCONF_LOG="$root/dconf.log" BACKUP_HOME_STAGE_DIR="$root/absent-stage" \
    BACKUP_HOME_SOURCE_HOME="$root/home" \
    "$PROJECT_DIR/collectors/system-inventory" backup
  assert_contains "$root/absent-stage/crontab-status.tsv" $'status\tabsent'
  if [[ -f "$root/absent-stage/warnings.txt" ]]; then
    assert_not_contains "$root/absent-stage/warnings.txt" "crontab inventory failed"
  fi

  printf 'git\tinstall\n' >"$root/dpkg-only-artifact/dpkg-selections.txt"
  env BACKUP_HOME_ARTIFACT_DIR="$root/dpkg-only-artifact" \
    "$PROJECT_DIR/collectors/system-inventory" restore describe >"$root/dpkg-only-describe"
  assert_contains "$root/dpkg-only-describe" $'component\tsystem.packages'
  expect_rc 20 "$root/dpkg-only-output" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/dpkg-only-artifact" \
    BACKUP_HOME_RESTORE_STAGING_DIR="$root/dpkg-only-restore-stage" \
    "$PROJECT_DIR/collectors/system-inventory" restore apply system.packages
  assert_file "$root/dpkg-only-restore-stage/artifacts/system.packages/dpkg-selections.txt"
}

run_optional_collector_contract_tests() {
  local root="$TEST_ROOT/optional-contracts"
  mkdir -p "$root" "$root/fakebin" "$root/gitlab-stage"
  "$PROJECT_DIR/collectors/manual-backup" metadata >"$root/manual-metadata"
  assert_contains "$root/manual-metadata" $'restore\tunsupported'
  expect_rc 64 "$root/manual-restore" "$PROJECT_DIR/collectors/manual-backup" restore describe
  "$PROJECT_DIR/collectors/gitlab-recovery" metadata >"$root/gitlab-metadata"
  assert_contains "$root/gitlab-metadata" $'restore\tsupported'
  expect_rc 1 "$root/gitlab-missing" env BACKUP_HOME_STAGE_DIR="$root/stage" \
    BACKUP_HOME_SOURCE_HOME="$root" BACKUP_HOME_GITLAB_CONFIG="$root/missing.conf" \
    "$PROJECT_DIR/collectors/gitlab-recovery" backup
  assert_contains "$root/gitlab-missing" "GitLab recovery config not found"
  cat >"$root/fakebin/glab" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_GLAB_LOG"
if [[ "${*: -1}" == user ]]; then
  printf '{"username":"%s"}\n' "${TEST_GLAB_USERNAME:-Example}"
else
  printf '[{"path_with_namespace":"example/project","ssh_url_to_repo":"git@example.invalid:example/project.git"}]\n'
fi
EOF
  cat >"$root/fakebin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --mirror ]]; then
  mkdir -p -- "$5"
  printf 'fixture\n' >"$5/HEAD"
  exit 0
fi
exit 1
EOF
  chmod +x "$root/fakebin/glab" "$root/fakebin/git"
  printf 'host|gitlab.example\naccount|example\ntoken-env|GITLAB_TOKEN\nscope|membership\napi-client|glab\n' >"$root/gitlab.conf"
  env PATH="$root/fakebin:$PATH" TEST_GLAB_LOG="$root/glab.log" \
    BACKUP_HOME_STAGE_DIR="$root/gitlab-stage" \
    BACKUP_HOME_SOURCE_HOME="$root" BACKUP_HOME_GITLAB_CONFIG="$root/gitlab.conf" \
    "$PROJECT_DIR/collectors/gitlab-recovery" backup
  assert_file "$root/gitlab-stage/projects.json"
  assert_file "$root/gitlab-stage/mirrors/example/project.git/HEAD"
  assert_file "$root/gitlab-stage/checksums.sha256"
  assert_contains "$root/glab.log" "api --hostname gitlab.example user"
  assert_contains "$root/glab.log" "projects?membership=true"
  mkdir -p "$root/gitlab-mismatch-stage"
  expect_rc 1 "$root/gitlab-account-mismatch" env PATH="$root/fakebin:$PATH" \
    TEST_GLAB_LOG="$root/glab-mismatch.log" TEST_GLAB_USERNAME=someone-else \
    BACKUP_HOME_STAGE_DIR="$root/gitlab-mismatch-stage" BACKUP_HOME_SOURCE_HOME="$root" \
    BACKUP_HOME_GITLAB_CONFIG="$root/gitlab.conf" \
    "$PROJECT_DIR/collectors/gitlab-recovery" backup
  assert_contains "$root/gitlab-account-mismatch" "does not match configured account"
  assert_not_contains "$root/glab-mismatch.log" "projects?membership=true"
  mkdir -p "$root/gitlab-target" "$root/gitlab-session"
  env BACKUP_HOME_ARTIFACT_DIR="$root/gitlab-stage" BACKUP_HOME_TARGET_HOME="$root/gitlab-target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/gitlab-session" \
    "$PROJECT_DIR/collectors/gitlab-recovery" restore describe >"$root/gitlab-describe"
  assert_contains "$root/gitlab-describe" $'component\tgitlab.local-mirrors'
  env BACKUP_HOME_ARTIFACT_DIR="$root/gitlab-stage" BACKUP_HOME_TARGET_HOME="$root/gitlab-target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/gitlab-session" BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/gitlab-recovery" restore apply gitlab.local-mirrors
  assert_file "$root/gitlab-target/gitlab-recovery/projects.json"

  cat >"$root/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cat >/dev/null
url="${*: -1}"
printf '%s\n' "$url" >>"$TEST_CURL_LOG"
case "$url" in
  *'/api/v4/user') printf '{"username":"%s"}\n' "${TEST_CURL_USERNAME:-EXAMPLE}" ;;
  *'page=1') printf '[{"path_with_namespace":"member/page-one","ssh_url_to_repo":"git@example.invalid:member/page-one.git"}]\n' ;;
  *'page=2') printf '[{"path_with_namespace":"member/page-two","ssh_url_to_repo":"git@example.invalid:member/page-two.git"}]\n' ;;
  *) printf '[]\n' ;;
esac
EOF
  chmod +x "$root/fakebin/curl"
  printf 'host|gitlab.example\naccount|example\ntoken-env|TEST_GITLAB_TOKEN\nscope|membership\napi-client|curl\n' >"$root/gitlab-curl.conf"
  mkdir -p "$root/gitlab-curl-stage"
  env PATH="$root/fakebin:$PATH" TEST_CURL_LOG="$root/curl.log" TEST_GITLAB_TOKEN=fixture-secret \
    BACKUP_HOME_STAGE_DIR="$root/gitlab-curl-stage" BACKUP_HOME_SOURCE_HOME="$root" \
    BACKUP_HOME_GITLAB_CONFIG="$root/gitlab-curl.conf" \
    "$PROJECT_DIR/collectors/gitlab-recovery" backup
  assert_file "$root/gitlab-curl-stage/mirrors/member/page-one.git/HEAD"
  assert_file "$root/gitlab-curl-stage/mirrors/member/page-two.git/HEAD"
  assert_contains "$root/curl.log" "projects?membership=true"
  assert_contains "$root/curl.log" "page=1"
  assert_contains "$root/curl.log" "page=2"
  assert_contains "$root/curl.log" "page=3"
  assert_not_contains "$root/curl.log" "fixture-secret"
  mkdir -p "$root/gitlab-curl-mismatch-stage"
  expect_rc 1 "$root/gitlab-curl-account-mismatch" env PATH="$root/fakebin:$PATH" \
    TEST_CURL_LOG="$root/curl-mismatch.log" TEST_CURL_USERNAME=someone-else \
    TEST_GITLAB_TOKEN=fixture-secret BACKUP_HOME_STAGE_DIR="$root/gitlab-curl-mismatch-stage" \
    BACKUP_HOME_SOURCE_HOME="$root" BACKUP_HOME_GITLAB_CONFIG="$root/gitlab-curl.conf" \
    "$PROJECT_DIR/collectors/gitlab-recovery" backup
  assert_not_contains "$root/curl-mismatch.log" "projects?membership=true"

  mkdir -p "$root/gitlab-outside" "$root/gitlab-symlink-home" "$root/gitlab-symlink-session"
  ln -s "$root/gitlab-outside" "$root/gitlab-symlink-home/gitlab-recovery"
  expect_rc 1 "$root/gitlab-target-symlink" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/gitlab-stage" BACKUP_HOME_TARGET_HOME="$root/gitlab-symlink-home" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/gitlab-symlink-session" BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/gitlab-recovery" restore apply gitlab.local-mirrors
  assert_contains "$root/gitlab-target-symlink" "must not contain symlinks"
  [[ -z "$(find "$root/gitlab-outside" -mindepth 1 -print -quit)" ]] \
    || fail "GitLab restore followed a target symlink outside the target home"
  mkdir -p "$root/gitlab-safe-home/gitlab-recovery" "$root/gitlab-safety-session/safety"
  printf 'existing\n' >"$root/gitlab-safe-home/gitlab-recovery/existing"
  ln -s "$root/gitlab-outside" "$root/gitlab-safety-session/safety/gitlab.local-mirrors"
  expect_rc 1 "$root/gitlab-safety-symlink" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/gitlab-stage" BACKUP_HOME_TARGET_HOME="$root/gitlab-safe-home" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/gitlab-safety-session" \
    BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/gitlab-recovery" restore apply gitlab.local-mirrors
  assert_contains "$root/gitlab-safety-symlink" "must not contain symlinks"
  [[ -z "$(find "$root/gitlab-outside" -mindepth 1 -print -quit)" ]] \
    || fail "GitLab restore wrote a false safety copy through a symlink"
  cp -a -- "$root/gitlab-stage" "$root/gitlab-symlink-artifact"
  rm -- "$root/gitlab-symlink-artifact/projects.json"
  printf 'outside metadata\n' >"$root/gitlab-outside/projects.json"
  ln -s "$root/gitlab-outside/projects.json" "$root/gitlab-symlink-artifact/projects.json"
  expect_rc 1 "$root/gitlab-artifact-symlink" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/gitlab-symlink-artifact" \
    BACKUP_HOME_TARGET_HOME="$root/gitlab-safe-home" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/gitlab-session" \
    "$PROJECT_DIR/collectors/gitlab-recovery" restore describe
  assert_contains "$root/gitlab-artifact-symlink" "artifacts must not contain symlinks"
}

run_manual_collector_test() {
  local root="$TEST_ROOT/manual"
  mkdir -p "$root/stage" "$root/stage-empty" "$root/stage-noninteractive" \
    "$root/stage-optional" "$root/fakebin"
  printf 'Contacts | Export contacts\nOTP\n' >"$root/manual.conf"
  cat >"$root/fakebin/xdg-open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$root/fakebin/xdg-open"
  expect_rc 1 "$root/noninteractive" env PATH="$root/fakebin:$PATH" \
    BACKUP_HOME_STAGE_DIR="$root/stage-noninteractive" BACKUP_HOME_MANUAL_FILE="$root/manual.conf" \
    "$PROJECT_DIR/collectors/manual-backup" backup
  assert_contains "$root/noninteractive" "requires an interactive terminal"
  env PATH="$root/fakebin:$PATH" BACKUP_HOME_COLLECTOR_MODE=optional \
    BACKUP_HOME_STAGE_DIR="$root/stage-optional" BACKUP_HOME_MANUAL_FILE="$root/manual.conf" \
    "$PROJECT_DIR/collectors/manual-backup" backup
  assert_contains "$root/stage-optional/warnings.txt" \
    "Manual staging was deferred for 2 checklist item(s)"
  assert_contains "$root/stage-optional/index.tsv" $'manual\tchecklist\ttasks\twarning'
  [[ "$(find "$root/stage-optional/tasks" -mindepth 2 -maxdepth 2 -name task.txt | wc -l)" -eq 2 ]] \
    || fail "Optional manual collector did not preserve the deferred checklist"
  printf '# no manual tasks\n   # still empty\n\n' >"$root/manual-empty.conf"
  env PATH="$root/fakebin:$PATH" BACKUP_HOME_STAGE_DIR="$root/stage-empty" \
    BACKUP_HOME_MANUAL_FILE="$root/manual-empty.conf" \
    "$PROJECT_DIR/collectors/manual-backup" backup
  assert_file "$root/stage-empty/RESTORE.md"
  assert_file "$root/stage-empty/index.tsv"
  assert_file "$root/stage-empty/checksums.sha256"
  printf '\n' | script -qec \
    "env PATH='$root/fakebin:$PATH' BACKUP_HOME_STAGE_DIR='$root/stage' BACKUP_HOME_MANUAL_FILE='$root/manual.conf' '$PROJECT_DIR/collectors/manual-backup' backup" \
    /dev/null >"$root/interactive-output"
  [[ "$(find "$root/stage/tasks" -mindepth 2 -maxdepth 2 -name task.txt | wc -l)" -eq 2 ]] \
    || fail "Manual collector did not create one staging directory per task"
  assert_file "$root/stage/index.tsv"
  assert_file "$root/stage/checksums.sha256"
  assert_file "$root/stage/RESTORE.md"
}

run_active_config_boundary_test() {
  local profile="$PROJECT_DIR/config/profiles/home.conf"
  local excludes="$PROJECT_DIR/config/excludes/local.exclude"
  local collectors="$PROJECT_DIR/config/collectors/enabled.conf"
  local codex="$PROJECT_DIR/config/codex-mcp-recovery/local.conf"
  local github="$PROJECT_DIR/config/github-recovery/local.conf"
  local credentials="$PROJECT_DIR/config/credentials-recovery/local.conf"
  local browser="$PROJECT_DIR/config/browser-recovery/local.conf"
  [[ "$(grep -c '^include=/home/home/.dotfiles$' "$profile")" -eq 1 ]] \
    || fail "The dotfiles include must appear exactly once"
  assert_not_contains "$profile" "include=/home/home/.dotfiles/docker-services"
  assert_not_contains "$profile" "include=/home/home/.config/WirePanelClient"
  assert_not_contains "$profile" "include=/home/home/.config/codex-mcp"
  assert_not_contains "$profile" "include=/home/home/backups/github"
  assert_not_contains "$profile" "include=/home/home/backups/joplin"
  assert_not_contains "$profile" "include=/home/home/backups/server"
  assert_contains "$profile" "unencrypted_destination=allow"
  assert_contains "$collectors" \
    "900|optional|manual-backup|/home/home/.dotfiles/scripts/src/backups/collectors/manual-backup|60"
  [[ "$(grep -Ev '^[[:space:]]*(#|$)' "$collectors" | awk -F '|' '$2 != "optional" {count++} END {print count + 0}')" -eq 0 ]] \
    || fail "Every active collector must be optional"
  [[ "$(grep -Ev '^[[:space:]]*(#|$)' "$collectors" | awk -F '|' 'NF != 5 || $5 !~ /^[1-9][0-9]*$/ {count++} END {print count + 0}')" -eq 0 ]] \
    || fail "Every active collector must have a positive timeout"
  assert_contains "$browser" "firefox-root|snap/firefox/common/.mozilla/firefox"
  assert_contains "$browser" "chromium-root|.config/google-chrome"
  assert_not_contains "$browser" "firefox-extension|"
  assert_contains "$codex" \
    "sqlite|mcp|.local/share/codex-mcp/codebase-memory-mcp/tdesktop-local.db"
  assert_contains "$codex" \
    "sqlite|mcp|.local/share/codex-mcp/codebase-memory-mcp/tad-moadian-sdk.db"
  assert_contains "$codex" \
    "sqlite|mcp|.local/share/codex-mcp/codebase-memory-mcp/codex.db"
  assert_contains "$codex" \
    "sqlite|mcp|.local/share/codex-mcp/codebase-memory-mcp/tad-moadian-sdk-official-references.db"
  assert_not_contains "$excludes" "/home/home/Desktop/temp"
  assert_contains "$excludes" "/home/home/my-files/learning-daily"
  [[ -L /home/home/Desktop/temp ]] || fail "Desktop/temp must remain a symlink"
  [[ "$(readlink -f /home/home/Desktop/temp)" == /home/home/my-files/temp ]] \
    || fail "Desktop/temp must point to my-files/temp"
  [[ "$(grep -c '^account|' "$github")" -eq 1 ]] || fail "GitHub config must select exactly one account"
  assert_contains "$github" "account|hamidmolareza"
  assert_not_contains "$github" "wmolareza"
  assert_not_contains "$credentials" 'github|.config/gh'
  assert_contains "$excludes" '/home/home/.dotfiles/.config/gh'
}

run_freshness_fallback_tests() {
  local root="$TEST_ROOT/freshness" bundle
  mkdir -p "$root/fakebin" "$root/github-success-home/backups/github/accounts/other" "$root/github-success-stage"
  date +%s >"$root/github-success-home/backups/github/accounts/other/.last-success"
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
  assert_contains "$root/github-success-stage/index.tsv" $'github-account\ttest\tcache/accounts/test\tsuccess'
  assert_file "$root/github-success-stage/cache/accounts/test/.last-success"
  [[ ! -e "$root/github-success-stage/cache/accounts/other" ]] \
    || fail "GitHub collector staged an unconfigured account"
  assert_file "$root/github-success-stage/credentials/test.token"
  mkdir -p "$root/github-target" "$root/github-session" "$root/github-snapshot"
  env BACKUP_HOME_ARTIFACT_DIR="$root/github-success-stage" BACKUP_HOME_SOURCE_HOME="$root/github-success-home" \
    BACKUP_HOME_TARGET_HOME="$root/github-target" BACKUP_HOME_RESTORE_SESSION_DIR="$root/github-session" \
    BACKUP_HOME_SNAPSHOT_DIR="$root/github-snapshot" BACKUP_HOME_GITHUB_CONFIG="$root/github-success-config" \
    "$PROJECT_DIR/collectors/github-recovery" restore describe >"$root/github-describe"
  assert_contains "$root/github-describe" $'component\tgithub.credentials'
  assert_contains "$root/github-describe" $'component\tgithub.remote-rebuild'
  mkdir -p "$root/github-outside" "$root/github-symlink-target/backups/github" \
    "$root/github-symlink-session"
  ln -s "$root/github-outside" "$root/github-symlink-target/backups/github/accounts"
  expect_rc 1 "$root/github-target-symlink" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/github-success-stage" \
    BACKUP_HOME_TARGET_HOME="$root/github-symlink-target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/github-symlink-session" \
    BACKUP_HOME_GITHUB_CONFIG="$root/github-success-config" BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/github-recovery" restore apply github.local-mirrors
  assert_contains "$root/github-target-symlink" "must not contain symlinks"
  [[ -z "$(find "$root/github-outside" -mindepth 1 -print -quit)" ]] \
    || fail "GitHub restore followed a target symlink outside the target home"

  mkdir -p "$root/github-safe-target" "$root/github-safety-session/safety"
  ln -s "$root/github-outside" "$root/github-safety-session/safety/github.local-mirrors"
  expect_rc 1 "$root/github-safety-symlink" env \
    BACKUP_HOME_ARTIFACT_DIR="$root/github-success-stage" \
    BACKUP_HOME_TARGET_HOME="$root/github-safe-target" \
    BACKUP_HOME_RESTORE_SESSION_DIR="$root/github-safety-session" \
    BACKUP_HOME_GITHUB_CONFIG="$root/github-success-config" BACKUP_HOME_DESTRUCTIVE_APPROVED=1 \
    "$PROJECT_DIR/collectors/github-recovery" restore apply github.local-mirrors
  assert_contains "$root/github-safety-symlink" "must not contain symlinks"
  [[ -z "$(find "$root/github-outside" -mindepth 1 -print -quit)" ]] \
    || fail "GitHub restore wrote a false safety copy through a symlink"

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
  assert_contains "$root/github-stage/index.tsv" $'github-account\ttest\tcache/accounts/test\tcached'

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
    "$PROJECT_DIR/collectors/server-recovery" restore describe >"$root/server-describe"
  assert_contains "$root/server-describe" $'component\tserver.foundation'
  touch -d '2 days ago' "$bundle"
  mkdir -p "$root/server-stage-stale"
  expect_rc 1 "$root/server-stale-output" env PATH="$root/fakebin:$PATH" \
    BACKUP_HOME_STAGE_DIR="$root/server-stage-stale" BACKUP_HOME_SOURCE_HOME="$root/server-home" \
    BACKUP_HOME_SERVER_CONFIG="$root/server-config" "$PROJECT_DIR/collectors/server-recovery"
}

main() {
  local dependency
  for dependency in bash find gh git python3 rsync script sha256sum ssh tar; do
    command -v "$dependency" >/dev/null 2>&1 || fail "Missing test dependency: $dependency"
  done
  run_sensitive_policy_tests
  run_sqlite_helper_test
  run_credentials_collector_test
  run_codex_collector_test
  run_browser_collector_test
  run_knowledge_collector_test
  run_system_inventory_collector_test
  run_optional_collector_contract_tests
  run_manual_collector_test
  run_active_config_boundary_test
  run_freshness_fallback_tests
  printf 'All recovery collector tests passed.\n'
}

main "$@"
