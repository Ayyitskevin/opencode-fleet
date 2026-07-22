#!/usr/bin/env bash

set -euo pipefail

test_path="$(readlink -f "${BASH_SOURCE[0]}")"
fleet_root="$(cd "$(dirname "$test_path")/.." && pwd)"
manifest="$fleet_root/config/repos.json"
guard="$fleet_root/config/runtime-guard.json"
config="$fleet_root/config/opencode.jsonc"
routes="$fleet_root/config/model-routes.json"
versions="$fleet_root/config/versions.json"

jq -e '
  .schemaVersion == 1 and
  .owner == "Ayyitskevin" and
  (.workspaceRoot | startswith("/")) and
  ([.repositories[] | select(.state == "active")] | length == 22) and
  ([.repositories[] | select(.state == "placeholder")] | length == 4) and
  ([.repositories[] | select(.state == "active") | .name] | sort) == [
    "Chronos", "Focal", "Hermes", "Hippocrates", "Icarus", "Iris",
    "Midas", "Minerva", "Tyche", "Vulcan", "aphrodite", "argus", "athena",
    "atlas", "curriculum", "dionysus", "eos", "hestia",
    "kleephotography", "mnemosyne", "opencode-fleet", "plutus"
  ] and
  ([.repositories[] | select(.state == "placeholder") | .name] | sort) == [
    "Apollo", "Harmonia", "Prometheus", "Themis"
  ] and
  ([.repositories[].name | ascii_downcase] | length == (unique | length)) and
  ([.repositories[].fullName | ascii_downcase] |
    length == (unique | length)) and
  (.owner as $owner |
    all(.repositories[];
      .fullName == ($owner + "/" + .name) and
      (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.defaultBranch | length > 0) and
      (.risk == "upstream" or .risk == "restricted" or
       .risk == "standard" or .risk == "placeholder") and
      (.githubMode == "manual" or .githubMode == "review" or
       .githubMode == "manual-build" or .githubMode == "disabled") and
      (if .state == "placeholder"
       then .risk == "placeholder" and .githubMode == "disabled"
       else .risk != "placeholder" and .githubMode != "disabled"
       end)
    )
  ) and
  (.repositories[] | select(.name == "Chronos") |
    .defaultBranch == "feat/wheel-dashboard-mvp") and
  (.repositories[] | select(.name == "Hippocrates") |
    .githubMode == "review") and
  (.repositories[] | select(.name == "Minerva") |
    .state == "active" and .risk == "restricted" and
    .githubMode == "manual")
' "$manifest" >/dev/null

jq -e '
  .schemaVersion == 1 and
  .routes.plan == {
    agent: "fleet-plan",
    model: "ollama/qwen3-coder:30b",
    costClass: "local-mid"
  } and
  .routes.build == {
    agent: "fleet-build",
    model: "ollama/qwen3-coder:30b",
    costClass: "local-mid"
  } and
  .routes.review == {
    agent: "fleet-review",
    model: "ollama/qwen3-coder:30b",
    costClass: "local-mid"
  } and
  .ceiling == {
    model: "ollama/qwen3-coder-next:q8_0",
    costClass: "local-ceiling"
  } and
  .cloud == {enabled: false, allowlist: []}
' "$routes" >/dev/null

jq -e '
  .share == "disabled" and
  .autoupdate == false and
  .enabled_providers == ["ollama"] and
  .permission.external_directory == "deny" and
  .permission.webfetch == "deny" and
  .permission.websearch == "deny" and
  .permission.task == "deny" and
  .permission.grep == "deny" and
  .permission.lsp == "deny" and
  .permission.bash["git push*"] == "deny" and
  ([.. | objects | .bash? | select(type == "object") | .[]] |
    all(. != "allow")) and
  .agent["fleet-plan"].permission.edit == "deny" and
  .agent["fleet-plan"].permission.bash == "deny" and
  .agent["fleet-review"].permission.edit == "deny" and
  .agent["fleet-build"].permission.edit == "allow"
' "$guard" >/dev/null

config_json="$(sed '/^[[:space:]]*\/\//d' "$config")"
jq -e '
  .model == "ollama/qwen3-coder:30b" and
  .small_model == "ollama/gpt-oss:20b" and
  .enabled_providers == ["ollama"] and
  .share == "disabled" and
  .autoupdate == false and
  .default_agent == "fleet-plan" and
  .snapshot == true and
  .provider.ollama.options.baseURL == "http://127.0.0.1:11434/v1" and
  .permission.external_directory == "deny" and
  .permission.webfetch == "deny" and
  .permission.websearch == "deny" and
  .permission.task == "deny" and
  .permission.grep == "deny" and
  .permission.lsp == "deny" and
  ([.. | objects | .bash? | select(type == "object") | .[]] |
    all(. != "allow"))
' <<<"$config_json" >/dev/null

while IFS= read -r model; do
  model_id="${model#ollama/}"
  jq -e --arg model "$model_id" \
    '.provider.ollama.models[$model] != null' <<<"$config_json" >/dev/null
done < <(jq -r '.routes[].model' "$routes")

retired_pattern='devstral|deepseek-r1|llama3\.3|llama4|phi4|olmo-3|magistral|nemotron-3-super|translategemma'
if grep -Eq "$retired_pattern" "$config"; then
  printf 'retired model remains in config\n' >&2
  exit 1
fi

jq -e '
  (.opencode.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.opencode.linuxX64Sha256 | test("^[0-9a-f]{64}$"))
' "$versions" >/dev/null

for script in oc doctor sync-clones install-local install-opencode-cli rollback; do
  [[ -x "$fleet_root/scripts/$script" ]] || {
    printf 'script is not executable: %s\n' "$script" >&2
    exit 1
  }
done

printf 'manifest tests passed\n'
