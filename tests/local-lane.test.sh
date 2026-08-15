#!/usr/bin/env bash

set -euo pipefail
umask 077

# Ambient and host Git configuration must not reach the suite: insteadOf
# rewrites, commit.gpgsign, and hooks all change observable Git behaviour.
unset "${!GIT_CONFIG@}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

test_path="$(readlink -f "${BASH_SOURCE[0]}")"
fleet_root="$(cd "$(dirname "$test_path")/.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Negative cases assert the exact refusal, not merely a nonzero status: a guard
# that dies for an unrelated reason is not the guard under test. Descriptor 7
# is closed in the child so a lock this suite holds is contended honestly.
capture_failure() {
  local error_file="$1"
  local expected="$2"
  local label="$3"
  local status=0
  shift 3

  "$@" >/dev/null 2>"$error_file" 7>&- || status=$?
  [[ "$status" -ne 0 ]] || fail "$label unexpectedly succeeded"
  grep -q -- "$expected" "$error_file" ||
    fail "$label did not refuse with '$expected'; got: $(cat "$error_file")"
}

# Post-lock rechecks are only observable while the tested process holds the
# lock, so the harness waits for that instead of guessing with a sleep.
wait_for_lock_held() {
  local attempt
  for ((attempt = 0; attempt < 400; attempt++)); do
    flock -n "$state_root/session.lock" true 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

wait_for_stopped() {
  local pid="$1"
  local attempt state
  for ((attempt = 0; attempt < 400; attempt++)); do
    state="$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1)"
    [[ "$state" != T ]] || return 0
    sleep 0.05
  done
  return 1
}

source_clone="$temp_root/source"
workspace="$temp_root/workspace"
home_root="$temp_root/home"
state_root="$home_root/.local/state/opencode-fleet"
mkdir -p "$home_root"
git init -q -b main "$source_clone"
git -C "$source_clone" config user.name "Fleet Test"
git -C "$source_clone" config user.email "fleet@example.invalid"
printf 'base\n' >"$source_clone/tracked.txt"
git -C "$source_clone" add tracked.txt
git -C "$source_clone" commit -qm "initial"
git -C "$source_clone" remote add origin git@github.com:Ayyitskevin/Example.git

manifest="$temp_root/repos.json"
jq -n --arg workspace "$workspace" '{
  schemaVersion: 1,
  owner: "Ayyitskevin",
  workspaceRoot: $workspace,
  repositories: [
    {
      name: "Example",
      fullName: "Ayyitskevin/Example",
      state: "active",
      defaultBranch: "main",
      risk: "standard",
      githubMode: "manual-build"
    },
    {
      name: "Empty",
      fullName: "Ayyitskevin/Empty",
      state: "placeholder",
      defaultBranch: "main",
      risk: "placeholder",
      githubMode: "disabled"
    },
    {
      name: "Contended",
      fullName: "Ayyitskevin/Contended",
      state: "active",
      defaultBranch: "main",
      risk: "standard",
      githubMode: "manual-build"
    }
  ]
}' >"$manifest"

# A second catalogued repository that has not been provisioned yet: clone
# provisioning is the sync-clones path that reaches the global session lock.
contended_source="$temp_root/source-contended"
git init -q -b main "$contended_source"
git -C "$contended_source" config user.name "Fleet Test"
git -C "$contended_source" config user.email "fleet@example.invalid"
printf 'base\n' >"$contended_source/tracked.txt"
git -C "$contended_source" add tracked.txt
git -C "$contended_source" commit -qm "initial"
git -C "$contended_source" remote add origin git@github.com:Ayyitskevin/Contended.git

provision_env=(
  OPENCODE_FLEET_HOME="$home_root"
  OPENCODE_FLEET_MANIFEST="$manifest"
  OPENCODE_FLEET_WORKSPACE_ROOT="$workspace"
  OPENCODE_FLEET_STATE_ROOT="$state_root"
)

sync_bad_home="$temp_root/sync-bad-home"
sync_bad_outside="$temp_root/sync-bad-outside"
mkdir -p "$sync_bad_home" "$sync_bad_outside"
ln -s "$sync_bad_outside" "$sync_bad_home/.local"
if env \
  OPENCODE_FLEET_HOME="$sync_bad_home" \
  OPENCODE_FLEET_MANIFEST="$manifest" \
  OPENCODE_FLEET_WORKSPACE_ROOT="$workspace" \
  OPENCODE_FLEET_STATE_ROOT="$sync_bad_home/.local/state/opencode-fleet" \
  "$fleet_root/scripts/sync-clones" Example --source "$source_clone" \
  >/dev/null 2>&1; then
  printf 'sync-clones accepted a symlinked state-root ancestor\n' >&2
  exit 1
fi
[[ ! -e "$sync_bad_outside/state" ]] ||
  { printf 'sync-clones wrote through a symlinked state root\n' >&2; exit 1; }

preview="$(
  env "${provision_env[@]}" "$fleet_root/scripts/sync-clones" \
    Example --source "$source_clone"
)"
jq -e '.action == "clone" and .method == "local-no-hardlinks"' <<<"$preview" >/dev/null
[[ ! -e "$workspace" ]] ||
  { printf 'clone preview mutated workspace\n' >&2; exit 1; }

env "${provision_env[@]}" "$fleet_root/scripts/sync-clones" \
  Example --source "$source_clone" --apply >/dev/null
dedicated_clone="$workspace/Example"
[[ -d "$dedicated_clone/.git" && ! -L "$dedicated_clone/.git" ]] ||
  { printf 'independent clone was not created\n' >&2; exit 1; }
dedicated_origin="$(git -C "$dedicated_clone" config --get remote.origin.url)"
[[ "$dedicated_origin" == "git@github.com:Ayyitskevin/Example.git" ]] ||
  { printf 'provisioned origin is not canonical\n' >&2; exit 1; }
commit="$(git -C "$source_clone" rev-parse HEAD)"
source_object="$source_clone/.git/objects/${commit:0:2}/${commit:2}"
target_object="$dedicated_clone/.git/objects/${commit:0:2}/${commit:2}"
[[ "$(stat -c %i "$source_object")" != "$(stat -c %i "$target_object")" ]] ||
  { printf 'local provisioning retained hardlinked Git objects\n' >&2; exit 1; }

mkdir -p "$home_root/.config/opencode" "$home_root/.local/bin"
printf 'previous-config\n' >"$home_root/.config/opencode/opencode.jsonc"
printf '#!/usr/bin/env bash\nprintf previous-launcher\n' >"$home_root/.local/bin/oc"
chmod 700 "$home_root/.local/bin/oc"

install_env=(
  OPENCODE_FLEET_HOME="$home_root"
  OPENCODE_FLEET_STATE_ROOT="$state_root"
)

bad_install_config="$temp_root/bad-install-config.json"
sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" |
  jq '.provider.ollama.options.baseURL = "https://example.invalid/v1"' \
  >"$bad_install_config"
if env "${install_env[@]}" OPENCODE_FLEET_CONFIG="$bad_install_config" \
  "$fleet_root/scripts/install-local" >/dev/null 2>&1; then
  printf 'installer accepted a remote provider base URL\n' >&2
  exit 1
fi
for install_filter in \
  '.enabled_providers = ["ollama", "openai"]' \
  '.permission.grep = "allow"' \
  '.permission.lsp = "allow"' \
  '.permission.search = "allow"'; do
  sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" |
    jq "$install_filter" >"$bad_install_config"
  if env "${install_env[@]}" OPENCODE_FLEET_CONFIG="$bad_install_config" \
    "$fleet_root/scripts/install-local" >/dev/null 2>&1; then
    printf 'installer accepted provider/content-tool drift\n' >&2
    exit 1
  fi
done
bad_install_routes="$temp_root/bad-install-routes.json"
jq '.routes.build.model = "ollama/qwen3.6:35b"' \
  "$fleet_root/config/model-routes.json" >"$bad_install_routes"
if env "${install_env[@]}" OPENCODE_FLEET_ROUTES="$bad_install_routes" \
  "$fleet_root/scripts/install-local" >/dev/null 2>&1; then
  printf 'installer accepted a non-canonical local model route\n' >&2
  exit 1
fi

install_preview="$(env "${install_env[@]}" "$fleet_root/scripts/install-local")"
jq -e '.action == "install-local" and .applyRequired == true' \
  <<<"$install_preview" >/dev/null
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc"

mkdir -p "$state_root"
jq -n '{schemaVersion: 1, sentinel: "previous-install-record"}' \
  >"$state_root/install.json"
exec 7>"$state_root/session.lock"
flock -n 7
if env "${install_env[@]}" "$fleet_root/scripts/install-local" --apply \
  >/dev/null 2>&1 7>&-; then
  printf 'local installer bypassed the shared session lock\n' >&2
  exit 1
fi
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc"
grep -q 'previous-launcher' "$home_root/.local/bin/oc"
jq -e '.sentinel == "previous-install-record"' "$state_root/install.json" >/dev/null
flock -u 7
set +e
env "${install_env[@]}" \
  OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_TEST_FAIL_AFTER_FIRST_TARGET=1 \
  "$fleet_root/scripts/install-local" --apply >/dev/null 2>"$temp_root/install-fault.err"
install_fault_status=$?
set -e
[[ "$install_fault_status" -ne 0 ]] ||
  { printf 'injected local install failure unexpectedly succeeded\n' >&2; exit 1; }
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc"
grep -q 'previous-launcher' "$home_root/.local/bin/oc"
jq -e '.sentinel == "previous-install-record"' "$state_root/install.json" >/dev/null
failed_install_record="$(find "$state_root/install-backups" \
  -name install.json.failed-transaction -print -quit)"
[[ -n "$failed_install_record" ]] ||
  { printf 'failed local install transaction was not preserved\n' >&2; exit 1; }
jq -e '.status == "prepared" and .transactionId != ""' \
  "$failed_install_record" >/dev/null

env "${install_env[@]}" "$fleet_root/scripts/install-local" --apply >/dev/null
[[ -f "$home_root/.config/opencode/opencode.jsonc" &&
   "$(stat -c %a "$home_root/.config/opencode/opencode.jsonc")" == 600 ]] ||
  { printf 'installed config type or mode is wrong\n' >&2; exit 1; }
[[ -L "$home_root/.local/bin/oc" &&
   "$(readlink -f "$home_root/.local/bin/oc")" == "$fleet_root/scripts/oc" ]] ||
  { printf 'canonical launcher symlink was not installed\n' >&2; exit 1; }
jq -e '
  .status == "installed" and .completedAt != "" and
  .config.backup != "" and .launcher.backup != ""
' \
  "$state_root/install.json" >/dev/null

launcher_backup="$(jq -r '.launcher.backup' "$state_root/install.json")"
mv "$launcher_backup" "$temp_root/launcher-backup-held"
if env "${install_env[@]}" "$fleet_root/scripts/rollback" \
  install --apply >/dev/null 2>&1; then
  printf 'rollback accepted an incomplete backup set\n' >&2
  exit 1
fi
[[ -L "$home_root/.local/bin/oc" ]] ||
  { printf 'failed rollback moved a target before validating all backups\n' >&2; exit 1; }
mv "$temp_root/launcher-backup-held" "$launcher_backup"

env "${install_env[@]}" "$fleet_root/scripts/rollback" install >/dev/null
[[ -L "$home_root/.local/bin/oc" ]] ||
  { printf 'rollback preview mutated launcher\n' >&2; exit 1; }
env "${install_env[@]}" "$fleet_root/scripts/rollback" install --apply >/dev/null
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc"
[[ -f "$home_root/.local/bin/oc" && ! -L "$home_root/.local/bin/oc" ]] ||
  { printf 'launcher backup was not restored\n' >&2; exit 1; }
grep -q 'previous-launcher' "$home_root/.local/bin/oc"

archive_dir="$temp_root/archive"
archive="$temp_root/opencode-test.tar.gz"
mkdir -p "$archive_dir" "$home_root/.opencode/bin"
cat >"$archive_dir/opencode" <<'CLI'
#!/usr/bin/env bash
printf '9.9.9\n'
CLI
chmod 700 "$archive_dir/opencode"
tar -C "$archive_dir" -czf "$archive" opencode
archive_sha="$(sha256sum "$archive" | cut -d' ' -f1)"
versions="$temp_root/versions.json"
jq -n --arg sha "$archive_sha" '{
  opencode: {
    version: "9.9.9",
    linuxX64Archive: "opencode-test.tar.gz",
    linuxX64Sha256: $sha
  }
}' >"$versions"
printf '#!/usr/bin/env bash\nprintf old-cli\n' >"$home_root/.opencode/bin/opencode"
chmod 700 "$home_root/.opencode/bin/opencode"

cli_env=(
  OPENCODE_FLEET_TESTING=1
  OPENCODE_FLEET_HOME="$home_root"
  OPENCODE_FLEET_STATE_ROOT="$state_root"
  OPENCODE_FLEET_VERSIONS="$versions"
)
env "${cli_env[@]}" "$fleet_root/scripts/install-opencode-cli" \
  --archive "$archive" >/dev/null
grep -q 'old-cli' "$home_root/.opencode/bin/opencode"
jq -n '{schemaVersion: 1, sentinel: "previous-cli-record"}' \
  >"$state_root/cli-install.json"
flock -n 7
if env "${cli_env[@]}" "$fleet_root/scripts/install-opencode-cli" \
  --archive "$archive" --apply >/dev/null 2>&1 7>&-; then
  printf 'CLI installer bypassed the shared session lock\n' >&2
  exit 1
fi
grep -q 'old-cli' "$home_root/.opencode/bin/opencode"
jq -e '.sentinel == "previous-cli-record"' "$state_root/cli-install.json" >/dev/null
flock -u 7
set +e
env "${cli_env[@]}" \
  OPENCODE_FLEET_TEST_FAIL_AFTER_FIRST_TARGET=1 \
  "$fleet_root/scripts/install-opencode-cli" \
  --archive "$archive" --apply >/dev/null 2>"$temp_root/cli-fault.err"
cli_fault_status=$?
set -e
[[ "$cli_fault_status" -ne 0 ]] ||
  { printf 'injected CLI install failure unexpectedly succeeded\n' >&2; exit 1; }
grep -q 'old-cli' "$home_root/.opencode/bin/opencode"
jq -e '.sentinel == "previous-cli-record"' "$state_root/cli-install.json" >/dev/null
failed_cli_record="$(find "$state_root/cli-backups" \
  -name cli-install.json.failed-transaction -print -quit)"
[[ -n "$failed_cli_record" ]] ||
  { printf 'failed CLI install transaction was not preserved\n' >&2; exit 1; }
jq -e '.status == "prepared" and .transactionId != ""' \
  "$failed_cli_record" >/dev/null
env "${cli_env[@]}" "$fleet_root/scripts/install-opencode-cli" \
  --archive "$archive" --apply >/dev/null
[[ "$("$home_root/.opencode/bin/opencode" --version)" == 9.9.9 &&
   "$(stat -c %a "$home_root/.opencode/bin/opencode")" == 700 ]] ||
  { printf 'pinned CLI was not installed correctly\n' >&2; exit 1; }
jq -e '.status == "installed" and .completedAt != ""' \
  "$state_root/cli-install.json" >/dev/null
env "${cli_env[@]}" "$fleet_root/scripts/rollback" cli --apply >/dev/null
grep -q 'old-cli' "$home_root/.opencode/bin/opencode"

bad_home="$temp_root/bad-home"
bad_outside="$temp_root/bad-outside"
mkdir -p "$bad_home" "$bad_outside"
ln -s "$bad_outside" "$bad_home/.config"
if env OPENCODE_FLEET_HOME="$bad_home" \
  OPENCODE_FLEET_STATE_ROOT="$bad_home/.local/state/opencode-fleet" \
  "$fleet_root/scripts/install-local" --apply >/dev/null 2>&1; then
  printf 'symlinked config parent was accepted\n' >&2
  exit 1
fi
[[ ! -e "$bad_outside/opencode" ]] ||
  { printf 'symlink preflight wrote outside the selected home\n' >&2; exit 1; }

bad_cache_home="$temp_root/bad-cache-home"
bad_cache_outside="$temp_root/bad-cache-outside"
mkdir -p "$bad_cache_home" "$bad_cache_outside/opencode"
ln -s "$bad_cache_outside" "$bad_cache_home/.cache"
if env OPENCODE_FLEET_HOME="$bad_cache_home" \
  OPENCODE_FLEET_STATE_ROOT="$bad_cache_home/.local/state/opencode-fleet" \
  "$fleet_root/scripts/install-local" --apply >/dev/null 2>&1; then
  printf 'symlinked hardening parent was accepted\n' >&2
  exit 1
fi
[[ ! -e "$bad_cache_home/.config/opencode/opencode.jsonc" ]] ||
  { printf 'private-root preflight happened after installation writes\n' >&2; exit 1; }

bad_cli_home="$temp_root/bad-cli-home"
bad_cli_outside="$temp_root/bad-cli-outside"
mkdir -p "$bad_cli_home" "$bad_cli_outside"
ln -s "$bad_cli_outside" "$bad_cli_home/.opencode"
if env OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_HOME="$bad_cli_home" \
  OPENCODE_FLEET_STATE_ROOT="$bad_cli_home/.local/state/opencode-fleet" \
  OPENCODE_FLEET_VERSIONS="$versions" \
  "$fleet_root/scripts/install-opencode-cli" --archive "$archive" --apply \
  >/dev/null 2>&1; then
  printf 'symlinked CLI parent was accepted\n' >&2
  exit 1
fi
[[ ! -e "$bad_cli_outside/bin/opencode" ]] ||
  { printf 'CLI symlink preflight wrote outside the selected home\n' >&2; exit 1; }

fake_bin="$temp_root/fake-opencode"
cat >"$fake_bin" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '1.18.4\n'
  exit 0
fi
printf 'changed\n' >>"$2/tracked.txt"
printf 'ignored/\n' >"$2/.gitignore"
printf 'untracked\n' >"$2/untracked.txt"
mkdir -p "$2/ignored"
printf 'ignored\n' >"$2/ignored/cache.bin"
ln -s "$2/untracked.txt" "$2/untracked-link"
FAKE
chmod 700 "$fake_bin"
fake_sha="$(sha256sum "$fake_bin" | cut -d' ' -f1)"
archive_pin="$(jq -r '.opencode.linuxX64Sha256' "$fleet_root/config/versions.json")"
jq -n \
  --arg target "$fake_bin" \
  --arg archiveSha256 "$archive_pin" \
  --arg binarySha256 "$fake_sha" \
  '{schemaVersion: 1, version: "1.18.4", archiveSha256: $archiveSha256,
    binarySha256: $binarySha256, target: $target,
    installedType: "regular", mode: "700"}' >"$state_root/cli-install.json"
launcher_env=(
  OPENCODE_FLEET_TESTING=1
  OPENCODE_FLEET_MANIFEST="$manifest"
  OPENCODE_FLEET_GUARD="$fleet_root/config/runtime-guard.json"
  OPENCODE_FLEET_ROUTES="$fleet_root/config/model-routes.json"
  OPENCODE_FLEET_WORKSPACE_ROOT="$workspace"
  OPENCODE_FLEET_STATE_ROOT="$state_root"
  OPENCODE_FLEET_BIN="$fake_bin"
  OPENCODE_FLEET_RUN_ID=rollback-run
)
env "${launcher_env[@]}" "$fleet_root/scripts/oc" Example build >/dev/null
run_record="$state_root/runs/rollback-run/record.json"
run_worktree="$(jq -r '.worktreePath' "$run_record")"
[[ -n "$(git -C "$run_worktree" status --porcelain)" ]] ||
  { printf 'fixture did not dirty the run worktree\n' >&2; exit 1; }

env "${provision_env[@]}" "$fleet_root/scripts/rollback" run rollback-run >/dev/null
[[ -f "$run_worktree/untracked.txt" ]] ||
  { printf 'run rollback preview mutated worktree\n' >&2; exit 1; }
env "${provision_env[@]}" "$fleet_root/scripts/rollback" \
  run rollback-run --apply >/dev/null
[[ -z "$(git -C "$run_worktree" status --porcelain)" ]] ||
  { printf 'run rollback did not restore a clean worktree\n' >&2; exit 1; }
jq -e '.status == "rolled-back" and .rollbackRecovery != ""' \
  "$run_record" >/dev/null
recovery="$(jq -r '.rollbackRecovery' "$run_record")"
[[ -f "$recovery/unstaged.patch" &&
   -f "$recovery/untracked/untracked.txt" &&
   -f "$recovery/untracked/ignored/cache.bin" &&
   -L "$recovery/untracked/untracked-link" &&
   -s "$recovery/untracked-paths.z" ]] ||
  { printf 'rollback recovery artifacts are incomplete\n' >&2; exit 1; }
[[ -z "$(git -C "$dedicated_clone" status --porcelain)" ]] ||
  { printf 'run rollback changed the dedicated source clone\n' >&2; exit 1; }

write_fake_cli_record() {
  local binary="$1"

  jq -n \
    --arg target "$binary" \
    --arg archiveSha256 "$archive_pin" \
    --arg binarySha256 "$(sha256sum "$binary" | cut -d' ' -f1)" \
    '{schemaVersion: 1, version: "1.18.4", archiveSha256: $archiveSha256,
      binarySha256: $binarySha256, target: $target,
      installedType: "regular", mode: "700"}' >"$state_root/cli-install.json"
}

# D9 promises installers and sessions "cannot race a session, sync, rollback,
# or one another". Rollback and clone provisioning are the two lock holders
# that had no contention coverage.
env "${launcher_env[@]}" OPENCODE_FLEET_RUN_ID=contention-run \
  "$fleet_root/scripts/oc" Example build >/dev/null
contention_worktree="$(jq -r '.worktreePath' \
  "$state_root/runs/contention-run/record.json")"
exec 7>"$state_root/session.lock"
flock -n 7
capture_failure "$temp_root/rollback-contention.err" \
  'another OpenCode fleet operation owns the local lane' \
  'run rollback against a held session lock' \
  env "${provision_env[@]}" "$fleet_root/scripts/rollback" \
    run contention-run --apply
[[ -n "$(git -C "$contention_worktree" status --porcelain)" ]] ||
  fail 'contended run rollback mutated the private worktree'
capture_failure "$temp_root/sync-contention.err" \
  'another OpenCode fleet operation owns the local lane' \
  'clone provisioning against a held session lock' \
  env "${provision_env[@]}" "$fleet_root/scripts/sync-clones" \
    Contended --source "$contended_source" --apply
[[ ! -e "$workspace/Contended" ]] ||
  fail 'contended sync-clones provisioned a clone while the lane was locked'
flock -u 7
env "${provision_env[@]}" "$fleet_root/scripts/sync-clones" \
  Contended --source "$contended_source" --apply >/dev/null
[[ -d "$workspace/Contended/.git" && ! -L "$workspace/Contended/.git" ]] ||
  fail 'sync-clones did not provision once the session lock was released'
env "${provision_env[@]}" "$fleet_root/scripts/rollback" \
  run contention-run --apply >/dev/null
[[ -z "$(git -C "$contention_worktree" status --porcelain)" ]] ||
  fail 'run rollback did not restore once the session lock was released'

# Staged changes: the index patch is a separate recovery artifact from the
# worktree patch, and a staged-only change produces an empty unstaged patch.
stage_fake_bin="$temp_root/fake-opencode-stage"
cat >"$stage_fake_bin" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '1.18.4\n'
  exit 0
fi
printf 'staged\n' >>"$2/tracked.txt"
printf 'new staged file\n' >"$2/staged-new.txt"
git -C "$2" add tracked.txt staged-new.txt
FAKE
chmod 700 "$stage_fake_bin"
write_fake_cli_record "$stage_fake_bin"
env "${launcher_env[@]}" OPENCODE_FLEET_BIN="$stage_fake_bin" \
  OPENCODE_FLEET_RUN_ID=staged-run "$fleet_root/scripts/oc" Example build \
  >/dev/null
staged_record="$state_root/runs/staged-run/record.json"
staged_worktree="$(jq -r '.worktreePath' "$staged_record")"
[[ -n "$(git -C "$staged_worktree" diff --cached --name-only)" ]] ||
  fail 'staged-change fixture did not stage anything'
# Run records now carry interruption metadata; those additive schemaVersion 1
# fields must not make an otherwise valid record unrollbackable.
jq '.status = "interrupted" | .interruptedBy = "INT"' "$staged_record" \
  >"$temp_root/staged-record.json"
cp "$temp_root/staged-record.json" "$staged_record"
env "${provision_env[@]}" "$fleet_root/scripts/rollback" \
  run staged-run --apply >/dev/null
staged_recovery="$(jq -r '.rollbackRecovery' "$staged_record")"
[[ -s "$staged_recovery/staged.patch" ]] ||
  fail 'rollback captured an empty staged.patch for a staged change'
grep -q 'staged-new.txt' "$staged_recovery/staged.patch" ||
  fail 'staged.patch does not contain the staged file'
[[ -z "$(git -C "$staged_worktree" status --porcelain --untracked-files=all)" ]] ||
  fail 'rollback did not restore a clean worktree after staged changes'
jq -e '.status == "rolled-back" and .interruptedBy == "INT"' "$staged_record" \
  >/dev/null ||
  fail 'rollback did not tolerate additive run-record fields'

# A renamed branch and a committed run branch are both refusals, and a refusal
# must leave the worktree exactly as it found it.
git -C "$dedicated_clone" config user.name "Fleet Test"
git -C "$dedicated_clone" config user.email "fleet@example.invalid"
write_fake_cli_record "$fake_bin"
env "${launcher_env[@]}" OPENCODE_FLEET_RUN_ID=committed-run \
  "$fleet_root/scripts/oc" Example build >/dev/null
committed_record="$state_root/runs/committed-run/record.json"
committed_worktree="$(jq -r '.worktreePath' "$committed_record")"
committed_base="$(jq -r '.baseCommit' "$committed_record")"
git -C "$committed_worktree" branch -m opencode/build/committed-renamed
capture_failure "$temp_root/rollback-branch.err" \
  'private worktree branch does not match the run record' \
  'rollback of a renamed run branch' \
  env "${provision_env[@]}" "$fleet_root/scripts/rollback" \
    run committed-run --apply
[[ -f "$committed_worktree/untracked.txt" ]] ||
  fail 'refused branch-mismatch rollback still mutated the worktree'
git -C "$committed_worktree" branch -m opencode/build/committed-run
git -C "$committed_worktree" add -A
git -C "$committed_worktree" commit -qm "committed run work"
capture_failure "$temp_root/rollback-committed.err" \
  'refuses committed changes; preserve or review the run branch manually' \
  'rollback of a committed run branch' \
  env "${provision_env[@]}" "$fleet_root/scripts/rollback" \
    run committed-run --apply
[[ "$(git -C "$committed_worktree" rev-parse HEAD)" != "$committed_base" ]] ||
  fail 'refused rollback rewound the committed run branch'
grep -q '^changed$' "$committed_worktree/tracked.txt" ||
  fail 'refused rollback discarded committed worktree content'
jq -e '.status != "rolled-back"' "$committed_record" >/dev/null ||
  fail 'refused rollback still marked the run rolled-back'

# Verify-then-use: the Git preconditions are checked before the lock, so they
# must be re-proved with the lock held before the destructive restore.
env "${launcher_env[@]}" OPENCODE_FLEET_RUN_ID=preflight-run \
  "$fleet_root/scripts/oc" Example build >/dev/null
preflight_record="$state_root/runs/preflight-run/record.json"
preflight_worktree="$(jq -r '.worktreePath' "$preflight_record")"
env "${provision_env[@]}" OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_TEST_PAUSE_AFTER_LOCK=5 \
  "$fleet_root/scripts/rollback" run preflight-run --apply \
  >/dev/null 2>"$temp_root/rollback-preflight.err" &
preflight_pid=$!
wait_for_lock_held || fail 'paused run rollback never took the session lock'
git -C "$preflight_worktree" add -A
git -C "$preflight_worktree" commit -qm "committed while rollback held the lock"
preflight_status=0
wait "$preflight_pid" || preflight_status=$?
[[ "$preflight_status" -ne 0 ]] ||
  fail 'rollback restored a worktree whose HEAD moved after its preflight'
grep -q 'the worktree HEAD changed during preflight' \
  "$temp_root/rollback-preflight.err" ||
  fail "post-lock HEAD recheck did not refuse; got: $(cat "$temp_root/rollback-preflight.err")"
grep -q '^changed$' "$preflight_worktree/tracked.txt" ||
  fail 'refused post-lock rollback still restored the worktree'
[[ ! -e "$state_root/recovery/preflight-run" ]] ||
  fail 'refused post-lock rollback created recovery state'

# Verify-then-use: install-local validates the source config before the lock
# and copies it afterwards, so the staged copy must be anchored to the exact
# bytes policy accepted rather than to whatever the source path holds later.
anchor_config="$temp_root/anchor-config.jsonc"
cp "$fleet_root/config/opencode.jsonc" "$anchor_config"
tampered_config="$temp_root/tampered-config.jsonc"
sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" |
  jq '.provider.ollama.options.baseURL = "https://example.invalid/v1"' \
  >"$tampered_config"
env "${install_env[@]}" OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_CONFIG="$anchor_config" \
  OPENCODE_FLEET_TEST_PAUSE_AFTER_LOCK=5 \
  "$fleet_root/scripts/install-local" --apply \
  >/dev/null 2>"$temp_root/install-anchor.err" &
anchor_pid=$!
wait_for_lock_held || fail 'paused local installer never took the session lock'
cp "$tampered_config" "$anchor_config"
anchor_status=0
wait "$anchor_pid" || anchor_status=$?
[[ "$anchor_status" -ne 0 ]] ||
  fail 'installer installed configuration bytes it never validated'
grep -q 'staged config copy does not match the validated source bytes' \
  "$temp_root/install-anchor.err" ||
  fail "config anchoring did not refuse; got: $(cat "$temp_root/install-anchor.err")"
! grep -q 'example.invalid' "$home_root/.config/opencode/opencode.jsonc" ||
  fail 'unvalidated configuration reached the live config target'
[[ -z "$(find "$home_root/.config/opencode" -maxdepth 1 \
   -name '.opencode.jsonc.*' -print -quit)" ]] ||
  fail 'a pre-transaction install failure left a staged config in the live directory'
[[ -n "$(find "$state_root/install-backups" -name opencode.jsonc.failed-staged \
   -print -quit)" ]] ||
  fail 'failed staged config was not consolidated under the transaction backup root'

# A reconciled failure preserves state; it must not leave that state scattered
# through the operator's live config and bin directories.
set +e
env "${install_env[@]}" OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_TEST_FAIL_AFTER_RECORD=1 \
  "$fleet_root/scripts/install-local" --apply \
  >/dev/null 2>"$temp_root/install-litter.err"
litter_status=$?
set -e
[[ "$litter_status" -ne 0 ]] ||
  fail 'injected post-record install failure unexpectedly succeeded'
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc" ||
  fail 'reconciled install failure did not restore the previous config'
[[ -z "$(find "$home_root/.config/opencode" -maxdepth 1 \
   -name '.opencode.jsonc.*' -print -quit)" ]] ||
  fail 'reconciled install failure left a staged config in the live config directory'
[[ -z "$(find "$home_root/.local/bin" -maxdepth 1 -name '.oc.*' -print -quit)" ]] ||
  fail 'reconciled install failure left a staged launcher in the live bin directory'
[[ -n "$(find "$state_root/install-backups" -name oc.failed-staged -print -quit)" ]] ||
  fail 'failed staged launcher was not consolidated under the transaction backup root'

# The untrappable half of D9: killed uncatchably between the durable prepared
# record and the first target replacement, the record must survive, a blind
# rerun must refuse, and rollback must recover.
env "${install_env[@]}" OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_TEST_STOP_AFTER_RECORD=1 \
  "$fleet_root/scripts/install-local" --apply >/dev/null 2>&1 &
install_stop_pid=$!
wait_for_stopped "$install_stop_pid" ||
  fail 'local installer never reached the durable-record stop hook'
kill -9 "$install_stop_pid"
wait "$install_stop_pid" 2>/dev/null || true
jq -e '.status == "prepared" and .transactionId != ""' \
  "$state_root/install.json" >/dev/null ||
  fail 'the durable prepared install record did not survive an uncatchable kill'
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc" ||
  fail 'a target was replaced before the prepared record became durable'
capture_failure "$temp_root/install-prepared.err" \
  "prepared transaction; recover it with 'scripts/rollback install'" \
  'blind install rerun over a prepared transaction' \
  env "${install_env[@]}" "$fleet_root/scripts/install-local" --apply
jq -e '.status == "prepared"' "$state_root/install.json" >/dev/null ||
  fail 'the refused rerun disturbed the prepared install record'
env "${install_env[@]}" "$fleet_root/scripts/rollback" install --apply >/dev/null
grep -q '^previous-config$' "$home_root/.config/opencode/opencode.jsonc" ||
  fail 'rollback did not restore the config after an interrupted transaction'
jq -e '.sentinel == "previous-install-record"' "$state_root/install.json" \
  >/dev/null ||
  fail 'rollback did not restore the pre-transaction install record'
env "${install_env[@]}" "$fleet_root/scripts/install-local" --apply >/dev/null
jq -e '.status == "installed"' "$state_root/install.json" >/dev/null ||
  fail 'the installer refused to run after the prepared transaction was recovered'

# Verify-then-use: every restore parameter is parsed from the record before the
# lock, so the record bytes must be re-proved unchanged before restoration.
env "${install_env[@]}" OPENCODE_FLEET_TESTING=1 \
  OPENCODE_FLEET_TEST_PAUSE_AFTER_LOCK=5 \
  "$fleet_root/scripts/rollback" install --apply \
  >/dev/null 2>"$temp_root/rollback-record.err" &
record_swap_pid=$!
wait_for_lock_held || fail 'paused install rollback never took the session lock'
jq '.config.backup = "" | .launcher.backup = ""' "$state_root/install.json" \
  >"$temp_root/swapped-install.json"
cp "$temp_root/swapped-install.json" "$state_root/install.json"
record_swap_status=0
wait "$record_swap_pid" || record_swap_status=$?
[[ "$record_swap_status" -ne 0 ]] ||
  fail 'install rollback used restore parameters it read before the lock'
grep -q 'install record changed during preflight' \
  "$temp_root/rollback-record.err" ||
  fail "post-lock record recheck did not refuse; got: $(cat "$temp_root/rollback-record.err")"
[[ -L "$home_root/.local/bin/oc" ]] ||
  fail 'refused install rollback still moved a target'

# Verify-then-use: the CLI archive is verified against the pin during argument
# validation, outside the lock, and every later read must be anchored to the
# verified private copy rather than to the caller's path.
swap_dir="$temp_root/swap"
mkdir -p "$swap_dir"
swap_archive="$swap_dir/opencode-test.tar.gz"
cp "$archive" "$swap_archive"
tampered_archive_dir="$temp_root/tampered-archive"
mkdir -p "$tampered_archive_dir"
cat >"$tampered_archive_dir/opencode" <<'CLI'
#!/usr/bin/env bash
# Reports the pinned version while carrying different bytes.
printf '9.9.9\n'
CLI
chmod 700 "$tampered_archive_dir/opencode"
tampered_archive="$temp_root/opencode-tampered.tar.gz"
tar -C "$tampered_archive_dir" -czf "$tampered_archive" opencode
env "${cli_env[@]}" OPENCODE_FLEET_TEST_PAUSE_AFTER_LOCK=5 \
  "$fleet_root/scripts/install-opencode-cli" --archive "$swap_archive" --apply \
  >/dev/null 2>"$temp_root/cli-anchor.err" &
cli_anchor_pid=$!
wait_for_lock_held || fail 'paused CLI installer never took the session lock'
cp "$tampered_archive" "$swap_archive"
cli_anchor_status=0
wait "$cli_anchor_pid" || cli_anchor_status=$?
[[ "$cli_anchor_status" -ne 0 ]] ||
  fail 'CLI installer installed an archive it verified only before the lock'
grep -q 'staged archive SHA-256 does not match the pin' \
  "$temp_root/cli-anchor.err" ||
  fail "archive anchoring did not refuse; got: $(cat "$temp_root/cli-anchor.err")"
grep -q 'old-cli' "$home_root/.opencode/bin/opencode" ||
  fail 'unverified archive contents reached the CLI target'
[[ -z "$(find "$home_root/.opencode/bin" -maxdepth 1 -name '.stage.*' \
   -print -quit)" ]] ||
  fail 'failed CLI install left its private staging directory in the live bin directory'
[[ -n "$(find "$state_root/cli-backups" -name staging.failed -print -quit)" ]] ||
  fail 'failed CLI staging was not consolidated under the transaction backup root'

env "${cli_env[@]}" OPENCODE_FLEET_TEST_STOP_AFTER_RECORD=1 \
  "$fleet_root/scripts/install-opencode-cli" --archive "$archive" --apply \
  >/dev/null 2>&1 &
cli_stop_pid=$!
wait_for_stopped "$cli_stop_pid" ||
  fail 'CLI installer never reached the durable-record stop hook'
kill -9 "$cli_stop_pid"
wait "$cli_stop_pid" 2>/dev/null || true
jq -e '.status == "prepared" and .transactionId != ""' \
  "$state_root/cli-install.json" >/dev/null ||
  fail 'the durable prepared CLI record did not survive an uncatchable kill'
grep -q 'old-cli' "$home_root/.opencode/bin/opencode" ||
  fail 'the CLI target was replaced before its prepared record became durable'
capture_failure "$temp_root/cli-prepared.err" \
  "prepared transaction; recover it with 'scripts/rollback cli'" \
  'blind CLI rerun over a prepared transaction' \
  env "${cli_env[@]}" "$fleet_root/scripts/install-opencode-cli" \
    --archive "$archive" --apply
jq -e '.status == "prepared"' "$state_root/cli-install.json" >/dev/null ||
  fail 'the refused CLI rerun disturbed the prepared record'
env "${cli_env[@]}" "$fleet_root/scripts/rollback" cli --apply >/dev/null
grep -q 'old-cli' "$home_root/.opencode/bin/opencode" ||
  fail 'rollback did not restore the CLI after an interrupted transaction'
jq -e --arg target "$fake_bin" '.target == $target' \
  "$state_root/cli-install.json" >/dev/null ||
  fail 'rollback did not restore the pre-transaction CLI record'

printf 'local lane integration tests passed\n'
