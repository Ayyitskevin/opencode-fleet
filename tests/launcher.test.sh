#!/usr/bin/env bash

set -euo pipefail

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
  --arg futureProviderKey "${SOME_FUTURE_PROVIDER_API_KEY:-}" \
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
    futureProviderKey: $futureProviderKey,
    sshAgent: $sshAgent,
    gitCount: $gitCount, pushUrl: $pushUrl, gitSsh: $gitSsh,
    noSystem: $noSystem}' >>"$FAKE_ENV_LOG"
if [[ "$FAKE_MUTATE" == "1" ]]; then
  printf 'changed\n' >>"$2/tracked.txt"
  printf 'untracked\n' >"$2/untracked.txt"
fi
if [[ -n "${FAKE_SLEEP:-}" ]]; then
  printf 'started\n' >"$FAKE_STARTED"
  sleep "$FAKE_SLEEP"
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
  SOME_FUTURE_PROVIDER_API_KEY=must-not-reach-any-model
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

# Practising with another local model is an allowlisted escalation, not an
# environment override: an empty allowlist is the shipped default and must
# refuse, and an allowlisted model still has to exist in the staged catalog.
experiment_routes="$temp_root/experiment-routes.json"
assert_refusal_early() {
  local label="$1"
  local expected="$2"
  shift 2
  local output
  if output="$("$@" 2>&1 >/dev/null)"; then
    printf 'expected refusal for %s\n' "$label" >&2
    exit 1
  fi
  grep -Fq -- "$expected" <<<"$output" ||
    { printf 'refusal for %s gave the wrong reason: %s\n' "$label" "$output" >&2
      exit 1; }
}
jq '.localExperiments = []' "$fleet_root/config/model-routes.json" \
  >"$experiment_routes"
assert_refusal_early "experiment against an empty allowlist" \
  "not in the local experiment allowlist" \
  env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$experiment_routes" \
  "$fleet_root/scripts/oc" Example --experiment ollama/qwen3.6:35b --dry-run
# The shipped allowlist is not a blanket permit: a model outside it is refused
# even though other models are allowed.
assert_refusal_early "experiment outside the shipped allowlist" \
  "not in the local experiment allowlist" \
  env "${common_env[@]}" "$fleet_root/scripts/oc" Example \
  --experiment ollama/not-allowlisted:1b --dry-run

jq '.localExperiments = ["ollama/qwen3.6:35b"]' \
  "$fleet_root/config/model-routes.json" >"$experiment_routes"
experiment_output="$(
  env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$experiment_routes" \
    "$fleet_root/scripts/oc" Example plan --experiment ollama/qwen3.6:35b --dry-run
)"
jq -e '
  .mode == "plan" and
  .agent == "fleet-plan" and
  .model == "ollama/qwen3.6:35b" and
  .costClass == "local-experiment"
' <<<"$experiment_output" >/dev/null ||
  { printf 'allowlisted experiment model was not selected\n' >&2; exit 1; }

# An allowlist entry is not enough on its own: the model must be staged.
jq '.localExperiments = ["ollama/not-installed:7b"]' \
  "$fleet_root/config/model-routes.json" >"$experiment_routes"
assert_refusal_early "experiment model absent from the catalog" \
  "absent from the staged provider catalog" \
  env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$experiment_routes" \
  "$fleet_root/scripts/oc" Example --experiment ollama/not-installed:7b --dry-run

# The daily routes stay deterministic: an experiment cannot be requested by
# environment variable, cannot shadow a pinned route, and cannot combine with
# another escalation.
jq '.localExperiments = ["ollama/qwen3-coder:30b"]' \
  "$fleet_root/config/model-routes.json" >"$experiment_routes"
assert_refusal_early "experiment allowlist shadowing a pinned route" \
  "model routes failed strict validation" \
  env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$experiment_routes" \
  "$fleet_root/scripts/oc" Example --dry-run

jq '.localExperiments = ["ollama/qwen3.6:35b"]' \
  "$fleet_root/config/model-routes.json" >"$experiment_routes"
for exclusive_flag in --ceiling --cloud; do
  assert_refusal_early "experiment combined with $exclusive_flag" \
    "mutually exclusive" \
    env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$experiment_routes" \
    "$fleet_root/scripts/oc" Example --experiment ollama/qwen3.6:35b \
    "$exclusive_flag" --dry-run
done
default_route_output="$(
  env "${common_env[@]}" OPENCODE_FLEET_ROUTES="$experiment_routes" \
    OPENCODE_FLEET_EXPERIMENT=ollama/qwen3.6:35b \
    "$fleet_root/scripts/oc" Example --dry-run
)"
jq -e '.model == "ollama/qwen3-coder:30b" and .costClass == "local-mid"' \
  <<<"$default_route_output" >/dev/null ||
  { printf 'an environment variable changed the daily model route\n' >&2
    exit 1; }

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
# The credential and shell deny tables are pinned by exact content and order,
# not merely by shape: a table reduced to its allow-everything head, a single
# missing deny, or a reordering must each be refused, and refused for that
# stated reason rather than incidentally.
assert_refusal() {
  local label="$1"
  local expected="$2"
  shift 2
  local output
  if output="$("$@" 2>&1 >/dev/null)"; then
    printf 'expected refusal for %s\n' "$label" >&2
    exit 1
  fi
  grep -Fq -- "$expected" <<<"$output" ||
    { printf 'refusal for %s gave the wrong reason: %s\n' "$label" "$output" >&2
      exit 1; }
}

contract_message="failed the canonical credential and shell contract"
# Every case below still passes the older structural validator: the deny table
# begins with an allow, ends with the push catch-all, and every remaining entry
# denies. Only the canonical contract notices that one specific credential or
# shell rule went missing, so these are what prove the content pinning does
# work the shape check never did.
guard_contract_cases=(
  'missing-netrc|del(.permission.read[".netrc"])'
  'missing-nested-npmrc|del(.permission.read["**/.npmrc"])'
  'missing-credentials-glob|del(.permission.read["*credentials*"])'
  'missing-ssh-identity|del(.permission.read["id_ed25519"])'
  'missing-review-push-deny|del(.agent["fleet-review"].permission.bash["git push*"])'
  'missing-build-sudo-deny|del(.agent["fleet-build"].permission.bash["sudo *"])'
)
for guard_contract_case in "${guard_contract_cases[@]}"; do
  IFS='|' read -r contract_name contract_filter <<<"$guard_contract_case"
  jq "$contract_filter" "$fleet_root/config/runtime-guard.json" >"$bad_guard"
  jq -e '
    (.permission.read | to_entries | .[0] == {key: "*", value: "allow"}) and
    all(.permission.read | to_entries[1:][]; .value == "deny") and
    (.permission.bash | to_entries | .[-1] ==
      {key: "*git*push*", value: "deny"})
  ' "$bad_guard" >/dev/null ||
    { printf 'case %s no longer isolates the content contract\n' \
        "$contract_name" >&2; exit 1; }
  assert_refusal "guard $contract_name" "$contract_message" \
    env "${common_env[@]}" OPENCODE_FLEET_GUARD="$bad_guard" \
    "$fleet_root/scripts/oc" Example --dry-run
done

bad_config="$temp_root/bad-config.json"
staged_contract_cases=(
  'missing-pypirc|del(.permission.read[".pypirc"])'
  'missing-secrets-yaml|del(.permission.read["**/secrets.yaml"])'
)
for staged_contract_case in "${staged_contract_cases[@]}"; do
  IFS='|' read -r contract_name contract_filter <<<"$staged_contract_case"
  sed '/^[[:space:]]*\/\//d' "$fleet_root/config/opencode.jsonc" |
    jq "$contract_filter" >"$bad_config"
  assert_refusal "staged $contract_name" "$contract_message" \
    env "${common_env[@]}" OPENCODE_FLEET_CONFIG="$bad_config" \
    "$fleet_root/scripts/oc" Example --dry-run
done

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
    .futureProviderKey == "" and
    ((.configContent | fromjson).enabled_providers == ["ollama"]) and
    ((.configContent | fromjson).permission.grep == "deny") and
    ((.configContent | fromjson).permission.lsp == "deny") and
    .gitCount == "4" and .pushUrl == "disabled://opencode-fleet-local" and
    .gitSsh == "/bin/false" and .noSystem == "1"
  ' "$fake_env_log" >/dev/null ||
  { printf 'local run environment did not match the sanitized contract\n' >&2
    jq -s '.[-1]' "$fake_env_log" >&2; exit 1; }

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
# The cloud lane enables exactly one provider, so exactly that provider's
# credential may survive. Every other provider's key, the GitHub token, and the
# SSH agent must be absent from a paid run too, not only from local runs.
jq -e -s '.[-1] |
  .opencodeKey == "cloud-explicit-key" and
  .githubToken == "" and .sshAgent == "" and
  .anthropicKey == "" and .awsAccessKey == "" and
  .googleCredentials == "" and .openaiKey == "" and
  .futureProviderKey == "" and
  ((.configContent | fromjson).enabled_providers == ["opencode"])
' "$fake_env_log" >/dev/null ||
  { printf 'cloud run received credentials beyond its one provider\n' >&2
    jq -s '.[-1]' "$fake_env_log" >&2; exit 1; }
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

# Cleanliness that Git could not report is not cleanliness: a failing status
# must refuse the build rather than read as a clean tree.
cp "$repository/.git/index" "$temp_root/index.good"
printf 'corrupt' >"$repository/.git/index"
status_refusal="$(env "${common_env[@]}" OPENCODE_FLEET_RUN_ID=status-failure \
  "$fleet_root/scripts/oc" Example build 2>&1 >/dev/null || true)"
cp "$temp_root/index.good" "$repository/.git/index"
grep -Fq 'cannot determine clone cleanliness' <<<"$status_refusal" ||
  { printf 'launcher accepted a clone whose status it could not read: %s\n' \
      "$status_refusal" >&2; exit 1; }

# Ctrl-C is the ordinary way to leave a session, so an interrupted run must
# still finalize its own evidence instead of claiming to be active forever.
started_marker="$temp_root/model-started"
# Job control matters here: with the monitor disabled bash sets SIGINT to
# SIG_IGN for asynchronous commands, so an untrappable INT would make the
# Ctrl-C case silently vacuous. Monitor mode also gives the job its own
# process group, which is what a terminal signals.
set -m
run_until_started() {
  local run_id="$1"
  shift
  rm -f "$started_marker"
  env "${common_env[@]}" \
    FAKE_SLEEP=60 FAKE_STARTED="$started_marker" \
    OPENCODE_FLEET_RUN_ID="$run_id" \
    "$fleet_root/scripts/oc" Example "$@" >/dev/null 2>&1 &
  interrupted_pid=$!
  local waited=0
  while [[ ! -f "$started_marker" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    if ((waited > 400)); then
      printf 'fake model never started for %s\n' "$run_id" >&2
      kill -KILL -"$interrupted_pid" 2>/dev/null || true
      exit 1
    fi
  done
}

signal_cases=(
  "interrupt-term|TERM|15"
  "interrupt-int|INT|2"
  "interrupt-hup|HUP|1"
)
for signal_case in "${signal_cases[@]}"; do
  IFS='|' read -r signal_run_id signal_name signal_number <<<"$signal_case"
  run_until_started "$signal_run_id" plan
  kill -"$signal_name" -"$interrupted_pid" 2>/dev/null ||
    kill -"$signal_name" "$interrupted_pid"
  signal_status=0
  { wait "$interrupted_pid" || signal_status=$?; } 2>/dev/null
  [[ "$signal_status" -eq $((128 + signal_number)) ]] ||
    { printf 'interrupted launcher exit status was %s for %s\n' \
        "$signal_status" "$signal_name" >&2; exit 1; }
  jq -e \
    --arg signal "$signal_name" \
    --argjson exitCode $((128 + signal_number)) '
      .status == "interrupted" and
      .interruptedBy == $signal and
      .exitCode == $exitCode and
      (.endedAt | type == "string" and length > 0)
    ' "$state_root/runs/$signal_run_id/record.json" >/dev/null ||
    { printf 'interrupted run record was not finalized for %s\n' \
        "$signal_name" >&2
      cat "$state_root/runs/$signal_run_id/record.json" >&2
      exit 1; }
done
set +m

# The lane must be usable again immediately: the lock is released and a new
# run with a fresh identity succeeds.
exec 7>"$state_root/session.lock"
flock -n 7 ||
  { printf 'session lock was not released by an interrupted run\n' >&2; exit 1; }
flock -u 7
exec 7>&-
env "${common_env[@]}" OPENCODE_FLEET_RUN_ID=after-interrupt \
  "$fleet_root/scripts/oc" Example plan >/dev/null
jq -e '.status == "completed" and .exitCode == 0' \
  "$state_root/runs/after-interrupt/record.json" >/dev/null

# A die between provisioning and execution must leave a reconciled record, not
# a run directory that claims to still be provisioning.
install -d -m 700 "$state_root/worktrees/example/collide-build"
if env "${common_env[@]}" OPENCODE_FLEET_RUN_ID=collide-build \
  "$fleet_root/scripts/oc" Example build >/dev/null 2>&1; then
  printf 'colliding private worktree was accepted\n' >&2
  exit 1
fi
jq -e '
  .status == "aborted" and
  (.endedAt | type == "string" and length > 0) and
  (.durationSeconds | type == "number")
' "$state_root/runs/collide-build/record.json" >/dev/null ||
  { printf 'aborted run left an unreconciled record\n' >&2; exit 1; }

# Run records and preserved worktrees are only useful if they can be read back.
# These subcommands are read-only over lane-owned state, so a run must survive
# being inspected byte-for-byte unchanged.
env "${common_env[@]}" FAKE_MUTATE=1 OPENCODE_FLEET_RUN_ID=history-build \
  "$fleet_root/scripts/oc" Example build >/dev/null
history_record="$state_root/runs/history-build/record.json"
jq -e '
  .status == "completed" and
  (.durationSeconds | type == "number") and
  .diffstat.files == 1 and .diffstat.insertions == 1 and
  .diffstat.untrackedFiles == 1
' "$history_record" >/dev/null ||
  { printf 'build run did not record duration and diffstat\n' >&2
    jq . "$history_record" >&2; exit 1; }

runs_before="$(sha256sum "$history_record" | cut -d' ' -f1)"
runs_table="$(env "${common_env[@]}" "$fleet_root/scripts/oc" runs)"
grep -q 'history-build' <<<"$runs_table" ||
  { printf 'oc runs did not list a recorded run\n' >&2; exit 1; }
grep -q 'history-build' \
  <<<"$(env "${common_env[@]}" "$fleet_root/scripts/oc" runs Example)" ||
  { printf 'oc runs ignored its repository filter\n' >&2; exit 1; }
[[ -z "$(env "${common_env[@]}" "$fleet_root/scripts/oc" runs Nonexistent)" ]] ||
  { printf 'oc runs matched an unrelated repository\n' >&2; exit 1; }
env "${common_env[@]}" "$fleet_root/scripts/oc" show history-build |
  jq -e '.runId == "history-build"' >/dev/null ||
  { printf 'oc show did not return the run record\n' >&2; exit 1; }
env "${common_env[@]}" "$fleet_root/scripts/oc" diff history-build |
  grep -q '^+changed$' ||
  { printf 'oc diff did not show the run worktree changes\n' >&2; exit 1; }
[[ "$(sha256sum "$history_record" | cut -d' ' -f1)" == "$runs_before" ]] ||
  { printf 'a read-only subcommand mutated a run record\n' >&2; exit 1; }

env "${common_env[@]}" "$fleet_root/scripts/oc" note history-build \
  'qwen3-coder planned well but missed the test layout' >/dev/null
jq -e '
  (.notes | length) == 1 and
  (.notes[0].note | test("missed the test layout")) and
  (.notes[0].at | type == "string" and length > 0)
' "$history_record" >/dev/null ||
  { printf 'oc note did not append an operator note\n' >&2; exit 1; }
stats_table="$(env "${common_env[@]}" "$fleet_root/scripts/oc" stats)"
grep -q 'ollama/qwen3-coder:30b' <<<"$stats_table" ||
  { printf 'oc stats did not aggregate by model\n' >&2; exit 1; }
grep -q 'Example' \
  <<<"$(env "${common_env[@]}" "$fleet_root/scripts/oc" stats --repo)" ||
  { printf 'oc stats --repo did not aggregate by repository\n' >&2; exit 1; }
for unsafe_run in '../escape' 'no-such-run'; do
  if env "${common_env[@]}" "$fleet_root/scripts/oc" show "$unsafe_run" \
    >/dev/null 2>&1; then
    printf 'oc show accepted an invalid run ID: %s\n' "$unsafe_run" >&2
    exit 1
  fi
done

# The sandbox lane exists so practice does not require a catalogued GitHub
# repository. It must carry strictly less authority than a catalogued clone:
# no remote at all, therefore nothing to publish to.
sandbox_env=("${common_env[@]}")
env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox new scratch >/dev/null
sandbox_path="$state_root/sandboxes/scratch"
[[ -d "$sandbox_path/.git" && ! -L "$sandbox_path/.git" ]] ||
  { printf 'sandbox was not initialized as a repository\n' >&2; exit 1; }
[[ "$(stat -c %a "$sandbox_path")" == "700" ]] ||
  { printf 'sandbox is not private\n' >&2; exit 1; }
[[ -z "$(git -C "$sandbox_path" remote)" ]] ||
  { printf 'a new sandbox has a remote\n' >&2; exit 1; }
grep -qx 'scratch' <<<"$(env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox list)" ||
  { printf 'oc sandbox list did not report the sandbox\n' >&2; exit 1; }
if env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox new scratch \
  >/dev/null 2>&1; then
  printf 'sandbox creation overwrote an existing sandbox\n' >&2
  exit 1
fi
for unsafe_sandbox in '../escape' 'has space' '.hidden'; do
  if env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox new "$unsafe_sandbox" \
    >/dev/null 2>&1; then
    printf 'sandbox accepted an unsafe name: %s\n' "$unsafe_sandbox" >&2
    exit 1
  fi
done

git -C "$sandbox_path" config user.name "Fleet Test"
git -C "$sandbox_path" config user.email "fleet@example.invalid"
printf 'scratch\n' >"$sandbox_path/tracked.txt"
git -C "$sandbox_path" add tracked.txt
git -C "$sandbox_path" commit -qm "sandbox base"

sandbox_plan="$(env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox scratch --dry-run)"
jq -e '
  .repository == "scratch" and .fullName == "sandbox/scratch" and
  .sandbox == true and .risk == "sandbox" and
  .model == "ollama/qwen3-coder:30b"
' <<<"$sandbox_plan" >/dev/null ||
  { printf 'sandbox plan did not resolve to lane-owned state\n' >&2; exit 1; }

# A sandbox that acquires a remote stops being a sandbox.
git -C "$sandbox_path" remote add origin git@github.com:Ayyitskevin/Example.git
assert_refusal_early "sandbox with a remote" "must have no remote" \
  env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox scratch --dry-run
git -C "$sandbox_path" remote remove origin
assert_refusal_early "missing sandbox" "no such sandbox" \
  env "${sandbox_env[@]}" "$fleet_root/scripts/oc" sandbox absent --dry-run

# A sandbox build is a real run: private worktree, run record, rollback.
env "${sandbox_env[@]}" FAKE_MUTATE=1 OPENCODE_FLEET_RUN_ID=sandbox-build \
  "$fleet_root/scripts/oc" sandbox scratch build >/dev/null
sandbox_record="$state_root/runs/sandbox-build/record.json"
jq -e '
  .status == "completed" and .sandbox == true and
  .fullName == "sandbox/scratch" and
  (.worktreePath | startswith("'"$state_root"'/sandbox-worktrees/scratch/")) and
  .diffstat.files == 1
' "$sandbox_record" >/dev/null ||
  { printf 'sandbox build did not record a lane-owned run\n' >&2
    jq . "$sandbox_record" >&2; exit 1; }
[[ -z "$(git -C "$sandbox_path" status --porcelain)" ]] ||
  { printf 'sandbox build mutated the sandbox instead of its worktree\n' >&2
    exit 1; }
env "${sandbox_env[@]}" "$fleet_root/scripts/oc" diff sandbox-build |
  grep -q '^+changed$' ||
  { printf 'oc diff did not work for a sandbox run\n' >&2; exit 1; }
env "${sandbox_env[@]}" "$fleet_root/scripts/rollback" run sandbox-build --apply \
  >/dev/null ||
  { printf 'rollback refused a sandbox run\n' >&2; exit 1; }
jq -e '.status == "rolled-back"' "$sandbox_record" >/dev/null ||
  { printf 'sandbox run was not marked rolled back\n' >&2; exit 1; }

# A record claiming to be a sandbox cannot point rollback at some other path:
# the sandbox lane is trusted only inside its own root.
env "${sandbox_env[@]}" FAKE_MUTATE=1 OPENCODE_FLEET_RUN_ID=sandbox-forged \
  "$fleet_root/scripts/oc" sandbox scratch build >/dev/null
forged_record="$state_root/runs/sandbox-forged/record.json"
cp "$forged_record" "$temp_root/sandbox-forged.good.json"
for forged_filter in \
  '.sourcePath = "'"$workspace"'/Example"' \
  '.worktreePath = .worktreePath + "-elsewhere"' \
  '.fullName = "Ayyitskevin/Example"'; do
  jq "$forged_filter" "$temp_root/sandbox-forged.good.json" >"$forged_record"
  if env "${sandbox_env[@]}" "$fleet_root/scripts/rollback" run sandbox-forged \
    --apply >/dev/null 2>&1; then
    printf 'rollback accepted a forged sandbox record: %s\n' "$forged_filter" >&2
    exit 1
  fi
done
cp "$temp_root/sandbox-forged.good.json" "$forged_record"

# A dirty sandbox refuses a build for the same reason a dirty clone does.
printf 'uncommitted\n' >>"$sandbox_path/tracked.txt"
assert_refusal_early "dirty sandbox build" "requires a clean sandbox" \
  env "${sandbox_env[@]}" OPENCODE_FLEET_RUN_ID=sandbox-dirty \
  "$fleet_root/scripts/oc" sandbox scratch build
git -C "$sandbox_path" checkout -- tracked.txt

printf 'launcher tests passed\n'


