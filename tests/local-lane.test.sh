#!/usr/bin/env bash

set -euo pipefail
umask 077

test_path="$(readlink -f "${BASH_SOURCE[0]}")"
fleet_root="$(cd "$(dirname "$test_path")/.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

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
    }
  ]
}' >"$manifest"

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
dedicated_origin="$(git -C "$dedicated_clone" remote get-url origin)"
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

printf 'local lane integration tests passed\n'
