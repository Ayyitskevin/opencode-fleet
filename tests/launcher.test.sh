#!/usr/bin/env bash

set -euo pipefail

test_path="$(readlink -f "${BASH_SOURCE[0]}")"
fleet_root="$(cd "$(dirname "$test_path")/.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT
umask 077

workspace="$temp_root/workspace"
repository="$workspace/Example"
state_root="$temp_root/state"
fake_log="$temp_root/fake.log"
fake_env_log="$temp_root/fake-env.log"
fake_bin="$temp_root/opencode"
mkdir -p "$workspace"
git init -q -b main "$repository"
git -C "$repository" config user.name "Fleet Test"
git -C "$repository" config user.email "fleet@example.invalid"
printf 'base\n' >"$repository/tracked.txt"
printf '# Test repository contract\n' >"$repository/AGENTS.md"
git -C "$repository" add tracked.txt AGENTS.md
git -C "$repository" commit -qm "initial"
git -C "$repository" remote add origin git@github.com:Ayyitskevin/Example.git

cat >"$fake_bin" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${FAKE_VERSION:-1.18.4}"
  exit 0
fi
printf '%s\n' "$*" >>"$FAKE_LOG"
jq -n \
  --arg home "$HOME" \
  --arg xdgConfig "$XDG_CONFIG_HOME" \
  --arg config "$OPENCODE_CONFIG" \
  --arg configDir "$OPENCODE_CONFIG_DIR" \
  --arg configContent "$OPENCODE_CONFIG_CONTENT" \
  --arg pure "${OPENCODE_PURE:-}" \
  --arg disableProject "$OPENCODE_DISABLE_PROJECT_CONFIG" \
  --arg disableSkills "$OPENCODE_DISABLE_EXTERNAL_SKILLS" \
  --arg disableClaude "$OPENCODE_DISABLE_CLAUDE_CODE" \
  --arg disablePlugins "$OPENCODE_DISABLE_DEFAULT_PLUGINS" \
  --arg githubToken "${GITHUB_TOKEN:-}" \
  --arg anthropicKey "${ANTHROPIC_API_KEY:-}" \
  --arg awsAccessKey "${AWS_ACCESS_KEY_ID:-}" \
  --arg googleCredentials "${GOOGLE_APPLICATION_CREDENTIALS:-}" \
  --arg openaiKey "${OPENAI_API_KEY:-}" \
  --arg opencodeKey "${OPENCODE_API_KEY:-}" \
  --arg sshAgent "${SSH_AUTH_SOCK:-}" \
  --arg gitCount "$GIT_CONFIG_COUNT" \
  --arg pushUrl "$GIT_CONFIG_VALUE_3" \
  --arg gitSsh "$GIT_SSH_COMMAND" \
  --arg noSystem "$GIT_CONFIG_NOSYSTEM" \
  '{home: $home, xdgConfig: $xdgConfig, config: $config,
    configDir: $configDir, configContent: $configContent,
    pureEnvironment: $pure,
    disableProject: $disableProject, disableSkills: $disableSkills,
    disableClaude: $disableClaude, disablePlugins: $disablePlugins,
    githubToken: $githubToken, anthropicKey: $anthropicKey,
    awsAccessKey: $awsAccessKey, googleCredentials: $googleCredentials,
    openaiKey: $openaiKey, opencodeKey: $opencodeKey,
    sshAgent: $sshAgent,
    gitCount: $gitCount, pushUrl: $pushUrl, gitSsh: $gitSsh,
    noSystem: $noSystem}' >>"$FAKE_ENV_LOG"
if [[ "$FAKE_MUTATE" == "1" ]]; then
  printf 'changed\n' >>"$2/tracked.txt"
  printf 'untracked\n' >"$2/untracked.txt"
fi
exit "$FAKE_EXIT_CODE"
FAKE
chmod 700 "$fake_bin"

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

common_env=(
  OPENCODE_FLEET_TESTING=1
  OPENCODE_FLEET_MANIFEST="$manifest"
  OPENCODE_FLEET_CONFIG="$fleet_root/config/opencode.jsonc"
  OPENCODE_FLEET_GUARD="$fleet_root/config/runtime-guard.json"
  OPENCODE_FLEET_ROUTES="$fleet_root/config/model-routes.json"
  OPENCODE_FLEET_WORKSPACE_ROOT="$workspace"
  OPENCODE_FLEET_STATE_ROOT="$state_root"
  OPENCODE_FLEET_BIN="$fake_bin"
  FAKE_LOG="$fake_log"
  FAKE_ENV_LOG="$fake_env_log"
  FAKE_VERSION=1.18.4
  FAKE_MUTATE=0
  FAKE_EXIT_CODE=0
  GITHUB_TOKEN=must-not-reach-model-shell
  ANTHROPIC_API_KEY=must-not-reach-local-model
  AWS_ACCESS_KEY_ID=must-not-reach-local-model
  GOOGLE_APPLICATION_CREDENTIALS="$temp_root/cloud-credentials.json"
  OPENAI_API_KEY=must-not-reach-local-model
  OPENCODE_API_KEY=cloud-explicit-key
  SSH_AUTH_SOCK="$temp_root/agent.sock"
)

root_bin="$temp_root/root-bin"
mkdir -p "$root_bin"
cat >"$root_bin/id" <<'ROOT_ID'
#!/usr/bin/env bash
printf '0\n'
ROOT_ID
chmod 700 "$root_bin/id"
if env "${common_env[@]}" PATH="$root_bin:$PATH" \
  "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
  printf 'root execution was accepted\n' >&2
  exit 1
fi

plan_output="$(env "${common_env[@]}" "$fleet_root/scripts/oc" example --dry-run)"
jq -e '
  .mode == "plan" and
  .agent == "fleet-plan" and
  .model == "ollama/qwen3-coder:30b" and
  .costClass == "local-mid" and
  .executionPath == .sourcePath
' <<<"$plan_output" >/dev/null
[[ ! -e "$state_root" ]] || {
  printf 'dry run created state\n' >&2
  exit 1
}

build_output="$(env "${common_env[@]}" "$fleet_root/scripts/oc" Example build --dry-run)"
jq -e '
  .mode == "build" and
  .agent == "fleet-build" and
  .model == "ollama/qwen3-coder:30b" and
  .costClass == "local-mid" and
  .executionPath == "private-run-worktree" and
  .dirty == false
' <<<"$build_output" >/dev/null

review_output="$(env "${common_env[@]}" "$fleet_root/scripts/oc" Example review --dry-run)"
jq -e '
  .mode == "review" and
  .agent == "fleet-review" and
  .model == "ollama/qwen3-coder:30b" and
  .costClass == "local-mid"
' <<<"$review_output" >/dev/null

ceiling_output="$(
  env "${common_env[@]}" "$fleet_root/scripts/oc" Example review --ceiling --dry-run
)"
jq -e '
  .mode == "review" and
  .model == "ollama/qwen3-coder-next:q8_0" and
  .costClass == "local-ceiling"
' <<<"$ceiling_output" >/dev/null

if env "${common_env[@]}" \
  OPENCODE_FLEET_CLOUD_MODEL="opencode/test-cloud" \
  "$fleet_root/scripts/oc" Example review --cloud --dry-run >/dev/null 2>&1; then
  printf 'disabled cloud policy was bypassed\n' >&2
  exit 1
fi

cloud_routes="$temp_root/cloud-routes.json"
jq '.cloud.enabled = true | .cloud.allowlist = ["opencode/test-cloud"]' \
  "$fleet_root/config/model-routes.json" >"$cloud_routes"
cloud_output="$(
  env "${common_env[@]}" \
    OPENCODE_FLEET_ROUTES="$cloud_routes" \
    OPENCODE_FLEET_CLOUD_MODEL="opencode/test-cloud" \
    "$fleet_root/scripts/oc" Example review --cloud --dry-run
)"
jq -e '
  .mode == "review" and
  .model == "opencode/test-cloud" and
  .costClass == "paid-cloud"
' <<<"$cloud_output" >/dev/null

bad_guard="$temp_root/bad-guard.json"
jq '.permission.read["**/.env.example"] = "allow"' \
  "$fleet_root/config/runtime-guard.json" >"$bad_guard"
if env "${common_env[@]}" OPENCODE_FLEET_GUARD="$bad_guard" \
  "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
  printf 'late secret allow rule bypassed strict guard validation\n' >&2
  exit 1
fi
jq '.permission.bash["*git*push*"] = "ask"' \
  "$fleet_root/config/runtime-guard.json" >"$bad_guard"
if env "${common_env[@]}" OPENCODE_FLEET_GUARD="$bad_guard" \
  "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
  printf 'non-deny final push rule bypassed strict guard validation\n' >&2
  exit 1
fi
jq '.agent["fleet-build"].permission.webfetch = "allow"' \
  "$fleet_root/config/runtime-guard.json" >"$bad_guard"
if env "${common_env[@]}" OPENCODE_FLEET_GUARD="$bad_guard" \
  "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
  printf 'agent-level network override bypassed strict guard validation\n' >&2
  exit 1
fi
for guard_filter in \
  '.enabled_providers = ["ollama", "openai"]' \
  '.permission.grep = "allow"' \
  '.permission.lsp = "allow"' \
  '.permission.search = "allow"'; do
  jq "$guard_filter" "$fleet_root/config/runtime-guard.json" >"$bad_guard"
  if env "${common_env[@]}" OPENCODE_FLEET_GUARD="$bad_guard" \
    "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
    printf 'provider/content-tool guard mutation bypassed strict validation\n' >&2
    exit 1
  fi
done
bad_config="$temp_root/bad-config.json"
sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" | \
  jq '.agent["fleet-build"].permission.bash["curl *"] = "allow"' \
  >"$bad_config"
if env "${common_env[@]}" OPENCODE_FLEET_CONFIG="$bad_config" \
  "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
  printf 'staged agent shell allow bypassed config validation\n' >&2
  exit 1
fi

for provider_mutation in remote-base wrong-adapter extra-provider; do
  case "$provider_mutation" in
    remote-base)
      provider_filter='.provider.ollama.options.baseURL = "https://example.invalid/v1"'
      ;;
    wrong-adapter)
      provider_filter='.provider.ollama.npm = "@ai-sdk/openai"'
      ;;
    extra-provider)
      provider_filter='.provider.remote = .provider.ollama'
      ;;
  esac
  sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" |
    jq "$provider_filter" >"$bad_config"
  if env "${common_env[@]}" OPENCODE_FLEET_CONFIG="$bad_config" \
    "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
    printf 'non-local provider mutation was accepted: %s\n' "$provider_mutation" >&2
    exit 1
  fi
done

for config_mutation in extra-enabled-provider grep-allow lsp-allow unknown-content-tool; do
  case "$config_mutation" in
    extra-enabled-provider)
      config_filter='.enabled_providers = ["ollama", "openai"]'
      ;;
    grep-allow)
      config_filter='.permission.grep = "allow"'
      ;;
    lsp-allow)
      config_filter='.permission.lsp = "allow"'
      ;;
    unknown-content-tool)
      config_filter='.permission.search = "allow"'
      ;;
  esac
  sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" |
    jq "$config_filter" >"$bad_config"
  if env "${common_env[@]}" OPENCODE_FLEET_CONFIG="$bad_config" \
    "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
    printf 'provider/content-tool config mutation was accepted: %s\n' \
      "$config_mutation" >&2
    exit 1
  fi
done

bad_routes="$temp_root/bad-routes.json"
jq '.routes.plan.model = "ollama/qwen3.6:35b"' \
  "$fleet_root/config/model-routes.json" >"$bad_routes"
if env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$bad_routes" \
  "$fleet_root/scripts/oc" Example --dry-run >/dev/null 2>&1; then
  printf 'non-canonical local route was accepted\n' >&2
  exit 1
fi

if env "${common_env[@]}" \
  OPENCODE_FLEET_ROUTES="$cloud_routes" \
  OPENCODE_FLEET_CLOUD_MODEL="opencode/not-allowed" \
  "$fleet_root/scripts/oc" Example --cloud --dry-run >/dev/null 2>&1; then
  printf 'non-allowlisted cloud model was accepted\n' >&2
  exit 1
fi

for invalid_repository in Empty Unknown; do
  if env "${common_env[@]}" \
    "$fleet_root/scripts/oc" "$invalid_repository" --dry-run >/dev/null 2>&1; then
    printf 'invalid repository was accepted: %s\n' "$invalid_repository" >&2
    exit 1
  fi
done

printf 'dirty\n' >>"$repository/tracked.txt"
if env "${common_env[@]}" \
  "$fleet_root/scripts/oc" Example build --dry-run >/dev/null 2>&1; then
  printf 'dirty build source was accepted\n' >&2
  exit 1
fi
git -C "$repository" restore tracked.txt

git -C "$repository" switch -qc other
if env "${common_env[@]}" \
  "$fleet_root/scripts/oc" Example build --dry-run >/dev/null 2>&1; then
  printf 'non-default build branch was accepted\n' >&2
  exit 1
fi
git -C "$repository" switch -q main

git -C "$repository" remote set-url origin \
  https://secret-token@github.com/Ayyitskevin/Example.git
leak_output="$temp_root/leak-output"
if env "${common_env[@]}" \
  "$fleet_root/scripts/oc" Example --dry-run >"$leak_output" 2>&1; then
  printf 'credential-bearing origin was accepted\n' >&2
  exit 1
fi
if grep -q 'secret-token' "$leak_output"; then
  printf 'origin credential leaked in diagnostics\n' >&2
  exit 1
fi
git -C "$repository" remote set-url origin git@github.com:Ayyitskevin/Example.git

linked_source="$temp_root/linked-source"
git clone -q "$repository" "$linked_source"
git -C "$linked_source" remote set-url origin git@github.com:Ayyitskevin/Linked.git
git -C "$linked_source" worktree add -q "$workspace/Linked" -b linked
linked_manifest="$temp_root/linked.json"
jq -n --arg workspace "$workspace" '{
  schemaVersion: 1,
  owner: "Ayyitskevin",
  workspaceRoot: $workspace,
  repositories: [{
    name: "Linked",
    fullName: "Ayyitskevin/Linked",
    state: "active",
    defaultBranch: "linked",
    risk: "standard",
    githubMode: "manual-build"
  }]
}' >"$linked_manifest"
if env "${common_env[@]}" OPENCODE_FLEET_MANIFEST="$linked_manifest" \
  "$fleet_root/scripts/oc" Linked --dry-run >/dev/null 2>&1; then
  printf 'linked worktree was accepted as an independent clone\n' >&2
  exit 1
fi

: >"$fake_log"
: >"$fake_env_log"
mkdir -p "$state_root"
fake_sha="$(sha256sum "$fake_bin" | cut -d' ' -f1)"
archive_sha="$(jq -r '.opencode.linuxX64Sha256' "$fleet_root/config/versions.json")"
jq -n \
  --arg target "$fake_bin" \
  --arg archiveSha256 "$archive_sha" \
  --arg binarySha256 "$fake_sha" \
  '{schemaVersion: 1, version: "1.18.4", archiveSha256: $archiveSha256,
    binarySha256: $binarySha256, target: $target,
    installedType: "regular", mode: "700"}' >"$state_root/cli-install.json"
state_link="$temp_root/state-link"
ln -s "$state_root" "$state_link"
if env "${common_env[@]}" OPENCODE_FLEET_STATE_ROOT="$state_link" \
  OPENCODE_FLEET_RUN_ID=state-symlink \
  "$fleet_root/scripts/oc" Example plan >/dev/null 2>&1; then
  printf 'symlinked launcher state root was accepted\n' >&2
  exit 1
fi
env "${common_env[@]}" OPENCODE_FLEET_RUN_ID=build-success \
  "$fleet_root/scripts/oc" Example build >/dev/null
record="$state_root/runs/build-success/record.json"
jq -e '
  .status == "completed" and
  .mode == "build" and
  .exitCode == 0 and
  .worktreePath == .executionPath and
  .runBranch == "opencode/build/build-success"
' "$record" >/dev/null
execution_path="$(jq -r '.executionPath' "$record")"
[[ -d "$execution_path" && -f "$execution_path/.git" ]] ||
  { printf 'private build worktree was not created\n' >&2; exit 1; }
[[ "$(git -C "$repository" branch --show-current)" == main &&
   -z "$(git -C "$repository" status --porcelain)" ]] ||
  { printf 'build mutated its dedicated source clone\n' >&2; exit 1; }
[[ "$(wc -l <"$fake_log")" -eq 1 ]] ||
  { printf 'launcher invoked the model more than once\n' >&2; exit 1; }
grep -q -- '--pure .* --agent fleet-build --model ollama/qwen3-coder:30b' "$fake_log"
jq -e \
  --arg home "$state_root/runs/build-success/runtime-home" \
  --arg config "$fleet_root/config/opencode.jsonc" '
    .home == $home and .xdgConfig == ($home + "/.config") and
    .config == $config and .configDir == ($home + "/.config/opencode") and
    .pureEnvironment == "1" and
    .disableProject == "1" and .disableSkills == "1" and
    .disableClaude == "1" and .disablePlugins == "1" and
    .githubToken == "" and .sshAgent == "" and
    .anthropicKey == "" and .awsAccessKey == "" and
    .googleCredentials == "" and .openaiKey == "" and .opencodeKey == "" and
    ((.configContent | fromjson).enabled_providers == ["ollama"]) and
    ((.configContent | fromjson).permission.grep == "deny") and
    ((.configContent | fromjson).permission.lsp == "deny") and
    .gitCount == "4" and .pushUrl == "disabled://opencode-fleet-local" and
    .gitSsh == "/bin/false" and .noSystem == "1"
  ' "$fake_env_log" >/dev/null

cp "$state_root/cli-install.json" "$temp_root/cli-install.good.json"
jq '.binarySha256 = ("0" * 64)' "$state_root/cli-install.json" \
  >"$temp_root/cli-install.bad.json"
mv "$temp_root/cli-install.bad.json" "$state_root/cli-install.json"
if env "${common_env[@]}" OPENCODE_FLEET_RUN_ID=digest-bypass \
  "$fleet_root/scripts/oc" Example plan >/dev/null 2>&1; then
  printf 'tampered CLI digest was accepted\n' >&2
  exit 1
fi
mv "$temp_root/cli-install.good.json" "$state_root/cli-install.json"
if env "${common_env[@]}" FAKE_VERSION=1.18.3 \
  OPENCODE_FLEET_RUN_ID=version-bypass \
  "$fleet_root/scripts/oc" Example plan >/dev/null 2>&1; then
  printf 'mismatched CLI version was accepted\n' >&2
  exit 1
fi

: >"$fake_log"
: >"$fake_env_log"
set +e
env "${common_env[@]}" \
  OPENCODE_FLEET_ROUTES="$cloud_routes" \
  OPENCODE_FLEET_CLOUD_MODEL="opencode/test-cloud" \
  OPENCODE_FLEET_RUN_ID=cloud-failure \
  FAKE_EXIT_CODE=37 \
  "$fleet_root/scripts/oc" Example review --cloud >/dev/null
cloud_exit=$?
set -e
[[ "$cloud_exit" -eq 37 ]] ||
  { printf 'cloud failure was not returned exactly\n' >&2; exit 1; }
[[ "$(wc -l <"$fake_log")" -eq 1 ]] ||
  { printf 'cloud failure triggered a fallback invocation\n' >&2; exit 1; }
grep -q -- '--model opencode/test-cloud' "$fake_log"
jq -e '
  .opencodeKey == "cloud-explicit-key" and
  ((.configContent | fromjson).enabled_providers == ["opencode"])
' "$fake_env_log" >/dev/null
jq -e '.status == "failed" and .exitCode == 37' \
  "$state_root/runs/cloud-failure/record.json" >/dev/null

doctor_config="$temp_root/doctor-opencode.jsonc"
doctor_launcher="$temp_root/doctor-oc"
cp "$fleet_root/config/opencode.jsonc" "$doctor_config"
chmod 600 "$doctor_config"
ln -s "$fleet_root/scripts/oc" "$doctor_launcher"
doctor_env=(
  "${common_env[@]}"
  OPENCODE_FLEET_CLI_RECORD="$state_root/cli-install.json"
  OPENCODE_FLEET_INSTALLED_CONFIG="$doctor_config"
  OPENCODE_FLEET_INSTALLED_LAUNCHER="$doctor_launcher"
)
env "${doctor_env[@]}" "$fleet_root/scripts/doctor" --strict >/dev/null

cp "$state_root/cli-install.json" "$temp_root/doctor-cli-record.good.json"
doctor_record_cases=(
  'bad-digest|.binarySha256 = ("0" * 64)'
  'bad-target|.target = "/tmp/not-the-pinned-binary"'
  'bad-version|.version = "0.0.0"'
  'bad-archive|.archiveSha256 = ("0" * 64)'
  'prepared|.status = "prepared"'
)
for doctor_record_case in "${doctor_record_cases[@]}"; do
  IFS='|' read -r doctor_case_name doctor_filter <<<"$doctor_record_case"
  jq "$doctor_filter" "$temp_root/doctor-cli-record.good.json" \
    >"$state_root/cli-install.json"
  if env "${doctor_env[@]}" "$fleet_root/scripts/doctor" --strict \
    >/dev/null 2>&1; then
    printf 'doctor accepted launcher-invalid CLI record: %s\n' \
      "$doctor_case_name" >&2
    exit 1
  fi
  if env "${common_env[@]}" OPENCODE_FLEET_RUN_ID="doctor-$doctor_case_name" \
    "$fleet_root/scripts/oc" Example plan >/dev/null 2>&1; then
    printf 'launcher accepted doctor-invalid CLI record: %s\n' \
      "$doctor_case_name" >&2
    exit 1
  fi
done
cp "$temp_root/doctor-cli-record.good.json" "$state_root/cli-install.json"
env "${doctor_env[@]}" "$fleet_root/scripts/doctor" --strict >/dev/null

exec 8>"$state_root/session.lock"
flock -n 8
if env "${common_env[@]}" OPENCODE_FLEET_RUN_ID=locked \
  "$fleet_root/scripts/oc" Example plan >/dev/null 2>&1; then
  printf 'global lane lock was bypassed\n' >&2
  exit 1
fi
flock -u 8

printf 'launcher tests passed\n'
