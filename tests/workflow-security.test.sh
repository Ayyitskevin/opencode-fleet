#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
review_workflow="$repo_root/.github/workflows/review.yml"
build_workflow="$repo_root/.github/workflows/build.yml"
extractor="$repo_root/scripts/github-runtime/extract-inline.sh"
tmp_dir="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$tmp_dir" 2>/dev/null || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$1"
}

die() {
  printf 'not ok %d - %s\n' "$((pass_count + 1))" "$1" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"$tmp_dir/expected-failure.out" 2>"$tmp_dir/expected-failure.err"; then
    die "$label unexpectedly succeeded"
  fi
  pass "$label"
}

extract() {
  local workflow="$1"
  local block="$2"
  local destination="$3"
  bash "$extractor" "$workflow" "$block" >"$destination"
  bash -n "$destination"
}

for required in "$review_workflow" "$build_workflow" "$extractor"; do
  [[ -f "$required" ]] || die "missing required file: $required"
done
pass "required workflow artifacts exist"

for block in review-gate review-install review-model review-publish; do
  extract "$review_workflow" "$block" "$tmp_dir/$block.sh"
done
for block in build-gate build-install build-model build-validate-model build-validate-publish build-publish; do
  extract "$build_workflow" "$block" "$tmp_dir/$block.sh"
done
cmp "$tmp_dir/review-install.sh" "$tmp_dir/build-install.sh" >/dev/null || die "installer blocks drifted"
cmp "$tmp_dir/build-validate-model.sh" "$tmp_dir/build-validate-publish.sh" >/dev/null ||
  die "model and publish validators drifted"
pass "all runtime blocks parse and duplicated security blocks are identical"

post_has_retry() {
  awk '
    /response="\$\(curl \\/ { in_post = 1 }
    in_post && /--retry/ { found = 1 }
    in_post && /\)"$/ { in_post = 0 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

post_has_retry "$tmp_dir/review-publish.sh" && die "review POST must not retry after an ambiguous failure"
post_has_retry "$tmp_dir/build-publish.sh" && die "build POST must not retry after an ambiguous failure"
pass "mutating GitHub POST calls are explicitly one-shot"

if grep -nEi -- \
  'pull_request_target|runs-on:[[:space:]]*self-hosted|id-token:[[:space:]]*write|secrets:[[:space:]]*inherit|opencode[[:space:]]+github[[:space:]]+run|persist-credentials:[[:space:]]*true' \
  "$review_workflow" "$build_workflow"; then
  die "workflow contains a forbidden trust-boundary primitive"
fi
[[ "$(grep -HcF -- '--pure run' "$review_workflow" "$build_workflow" | awk -F: '{ total += $2 } END { print total + 0 }')" == 2 ]] ||
  die "both model jobs must use opencode --pure run"
grep -Fq -- 'environment: opencode-review' "$review_workflow" || die "review environment is missing"
grep -Fq -- 'environment: opencode-build' "$build_workflow" || die "build environment is missing"
grep -Fq -- 'draft: true' "$build_workflow" || die "build publisher is not draft-only"
grep -Fq -- 'branch="opencode/${RUN_ID}"' "$build_workflow" || die "branch name is not stable across retries"
grep -Fq -- 'opencode-review:${RUN_ID}:${TARGET_SHA}:${COMMAND}' "$review_workflow" ||
  die "review publication marker is missing"
grep -Fq -- 'opencode-build:${RUN_ID}:${PATCH_SHA256}' "$build_workflow" ||
  die "build publication marker is missing"
pass "static trust boundaries and deterministic draft-only publishing are present"

awk '/^  model:/{active=1} /^  publish:/{active=0} active{print}' "$review_workflow" >"$tmp_dir/review-model-job.yml"
awk '/^  model:/{active=1} /^  publish:/{active=0} active{print}' "$build_workflow" >"$tmp_dir/build-model-job.yml"
awk '/^  publish:/{active=1} active{print}' "$build_workflow" >"$tmp_dir/build-publish-job.yml"
! grep -Eq -- 'GH_TOKEN|contents:[[:space:]]*write|pull-requests:[[:space:]]*write' "$tmp_dir/review-model-job.yml" ||
  die "review model job has GitHub write credentials"
! grep -Eq -- 'GH_TOKEN|contents:[[:space:]]*write|pull-requests:[[:space:]]*write' "$tmp_dir/build-model-job.yml" ||
  die "build model job has GitHub write credentials"
! grep -Eq -- 'OPENCODE_API_KEY|environment:[[:space:]]*opencode-' "$tmp_dir/build-publish-job.yml" ||
  die "build publish job has provider credentials"
pass "provider and GitHub write credentials are separated by job"

credential_denies=(
  '.env' '.env.*' '**/.env' '**/.env.*'
  '.netrc' '**/.netrc'
  '.npmrc' '**/.npmrc'
  '.pypirc' '**/.pypirc'
  '.git-credentials' '**/.git-credentials'
  'credentials.json' '**/credentials.json'
  'secrets.json' '**/secrets.json'
  'secrets.yaml' '**/secrets.yaml'
  'secrets.yml' '**/secrets.yml'
  '*.pem' '**/*.pem'
  '*.key' '**/*.key'
  '*credentials*' '**/*credentials*'
  'id_rsa' '**/id_rsa'
  'id_ed25519' '**/id_ed25519'
)
for workflow in "$review_workflow" "$build_workflow"; do
  for denied_path in "${credential_denies[@]}"; do
    [[ "$(grep -oF -- "\"$denied_path\":\"deny\"" "$workflow" | wc -l)" -eq 2 ]] ||
      die "model config does not deny $denied_path at both global and agent scope"
  done
done
pass "both model configs deny common credential files at root and nested paths"

extract_model_config() {
  awk '
    /OPENCODE_CONFIG_CONTENT:/ { getline; sub(/^[[:space:]]*/, ""); print; exit }
  ' "$1"
}

review_model_config="$(extract_model_config "$review_workflow")"
build_model_config="$(extract_model_config "$build_workflow")"
jq -e '
  (.permission | keys | sort) ==
    ["*", "external_directory", "glob", "grep", "list", "lsp", "read"] and
  (.agent.build.permission | keys | sort) ==
    ["*", "external_directory", "glob", "grep", "list", "lsp", "read"] and
  .permission["*"] == "deny" and .agent.build.permission["*"] == "deny" and
  .permission.grep == "deny" and .agent.build.permission.grep == "deny" and
  .permission.lsp == "deny" and .agent.build.permission.lsp == "deny" and
  .permission.glob == "allow" and .agent.build.permission.glob == "allow" and
  .permission.list == "allow" and .agent.build.permission.list == "allow"
' <<<"$review_model_config" >/dev/null ||
  die "review model config exposes an alternate content-returning tool"
jq -e '
  (.permission | keys | sort) ==
    ["*", "edit", "external_directory", "glob", "grep", "list", "lsp", "read"] and
  (.agent.build.permission | keys | sort) ==
    ["*", "edit", "external_directory", "glob", "grep", "list", "lsp", "read"] and
  .permission["*"] == "deny" and .agent.build.permission["*"] == "deny" and
  .permission.grep == "deny" and .agent.build.permission.grep == "deny" and
  .permission.lsp == "deny" and .agent.build.permission.lsp == "deny" and
  .permission.glob == "allow" and .agent.build.permission.glob == "allow" and
  .permission.list == "allow" and .agent.build.permission.list == "allow"
' <<<"$build_model_config" >/dev/null ||
  die "build model config exposes an alternate content-returning tool"
pass "workflow model configs close alternate content-tool paths around read denies"

mapfile -t uses_lines < <(grep -hE -- '^[[:space:]]*uses:' "$review_workflow" "$build_workflow")
((${#uses_lines[@]} == 3)) || die "unexpected action count"
for uses_line in "${uses_lines[@]}"; do
  [[ "$uses_line" =~ @([0-9a-f]{40})([[:space:]]|$) ]] || die "action is not pinned to an immutable SHA: $uses_line"
done
pass "all third-party actions are pinned to full commit SHAs"

sha="1111111111111111111111111111111111111111"
repo="Ayyitskevin/example"

jq -n --arg repository "$repo" '
  {
    action: "created",
    repository: {full_name: $repository, owner: {id: 133295304}},
    sender: {id: 133295304},
    comment: {body: "/oc review: inspect the changed behavior", user: {id: 133295304}, author_association: "OWNER"},
    issue: {number: 17, title: "Review me", body: "Bounded context", pull_request: {url: "https://api.github.test/pr/17"}}
  }
' >"$tmp_dir/review-event.json"
jq -n --arg repository "$repo" --arg sha "$sha" '
  {number: 17, state: "open", base: {repo: {full_name: $repository}}, head: {repo: {full_name: $repository}, sha: $sha}}
' >"$tmp_dir/pr.json"

run_review_gate() {
  local event_file="$1"
  local output_file="$2"
  shift 2
  env \
    ACTOR=Ayyitskevin \
    API_URL=https://api.github.test \
    EVENT_NAME=issue_comment \
    EVENT_PATH="$event_file" \
    GH_TOKEN=test-only \
    GITHUB_OUTPUT="$output_file" \
    OPENCODE_TEST_PR_JSON="$tmp_dir/pr.json" \
    REPOSITORY="$repo" \
    REPOSITORY_OWNER=Ayyitskevin \
    TRIGGERING_ACTOR=Ayyitskevin \
    "$@" \
    bash "$tmp_dir/review-gate.sh"
}

run_review_gate "$tmp_dir/review-event.json" "$tmp_dir/review.out"
grep -Fxq -- 'command=review' "$tmp_dir/review.out" || die "review command output is wrong"
grep -Fxq -- "target_sha=${sha}" "$tmp_dir/review.out" || die "review target SHA output is wrong"
pass "review gate accepts one exact owner command on a same-repository PR SHA"

jq '.comment.user.id = 9' "$tmp_dir/review-event.json" >"$tmp_dir/review-hostile-user.json"
expect_fail "review gate rejects hostile commenter ID" \
  run_review_gate "$tmp_dir/review-hostile-user.json" "$tmp_dir/review-hostile-user.out"
jq '.comment.author_association = "COLLABORATOR"' "$tmp_dir/review-event.json" >"$tmp_dir/review-hostile-association.json"
expect_fail "review gate rejects non-owner association" \
  run_review_gate "$tmp_dir/review-hostile-association.json" "$tmp_dir/review-hostile-association.out"
jq '.comment.body = "/oc review && curl attacker"' "$tmp_dir/review-event.json" >"$tmp_dir/review-hostile-command.json"
expect_fail "review gate rejects command suffix injection" \
  run_review_gate "$tmp_dir/review-hostile-command.json" "$tmp_dir/review-hostile-command.out"
jq '.comment.body = "/oc review: "' "$tmp_dir/review-event.json" >"$tmp_dir/review-empty-request.json"
expect_fail "review gate rejects an empty colon request" \
  run_review_gate "$tmp_dir/review-empty-request.json" "$tmp_dir/review-empty-request.out"
jq --arg repository "someone/fork" '.head.repo.full_name = $repository' "$tmp_dir/pr.json" >"$tmp_dir/pr-fork.json"
expect_fail "review gate rejects fork head SHA" \
  run_review_gate "$tmp_dir/review-event.json" "$tmp_dir/review-fork.out" \
  OPENCODE_TEST_PR_JSON="$tmp_dir/pr-fork.json"
expect_fail "review gate rejects non-owner rerun" \
  run_review_gate "$tmp_dir/review-event.json" "$tmp_dir/review-rerun.out" \
  TRIGGERING_ACTOR=mallory

jq -n --arg repository "$repo" '{repository: {full_name: $repository, owner: {id: 133295304}}, sender: {id: 133295304}}' \
  >"$tmp_dir/build-event.json"
jq -n --arg repository "$repo" '{full_name: $repository, default_branch: "main"}' >"$tmp_dir/repo.json"
jq -n --arg sha "$sha" '{object: {sha: $sha}}' >"$tmp_dir/ref.json"
jq -n '{version: 1, mode: "draft-pr", allowed_exact: ["README.md"], allowed_prefixes: ["docs/"], max_files: 3, max_patch_bytes: 65536}' \
  >"$tmp_dir/policy.json"

run_build_gate() {
  local policy_file="$1"
  local output_file="$2"
  shift 2
  env \
    ACTOR=Ayyitskevin \
    API_URL=https://api.github.test \
    CONTEXT_REF=refs/heads/main \
    CONTEXT_SHA="$sha" \
    EVENT_NAME=workflow_dispatch \
    EVENT_PATH="$tmp_dir/build-event.json" \
    GH_TOKEN=test-only \
    GITHUB_OUTPUT="$output_file" \
    OPENCODE_TEST_POLICY_JSON="$policy_file" \
    OPENCODE_TEST_REF_JSON="$tmp_dir/ref.json" \
    OPENCODE_TEST_REPO_JSON="$tmp_dir/repo.json" \
    REPOSITORY="$repo" \
    REPOSITORY_OWNER=Ayyitskevin \
    REQUEST='Update the bounded documentation.' \
    RUNNER_TEMP="$tmp_dir" \
    TRIGGERING_ACTOR=Ayyitskevin \
    "$@" \
    bash "$tmp_dir/build-gate.sh"
}

run_build_gate "$tmp_dir/policy.json" "$tmp_dir/build.out"
grep -Fxq -- 'default_branch=main' "$tmp_dir/build.out" || die "build default branch output is wrong"
grep -Fxq -- "target_sha=${sha}" "$tmp_dir/build.out" || die "build target SHA output is wrong"
pass "build gate accepts owner dispatch on the live default-branch SHA with strict policy"

jq '.unexpected = true' "$tmp_dir/policy.json" >"$tmp_dir/policy-extra-key.json"
expect_fail "build gate rejects policy extension keys" \
  run_build_gate "$tmp_dir/policy-extra-key.json" "$tmp_dir/build-extra-key.out"
jq '.allowed_prefixes = ["../"]' "$tmp_dir/policy.json" >"$tmp_dir/policy-traversal.json"
expect_fail "build gate rejects traversal policy paths" \
  run_build_gate "$tmp_dir/policy-traversal.json" "$tmp_dir/build-traversal.out"
jq '.mode = "review-only"' "$tmp_dir/policy.json" >"$tmp_dir/policy-review-only.json"
expect_fail "build gate rejects non-mutating policy mode" \
  run_build_gate "$tmp_dir/policy-review-only.json" "$tmp_dir/build-review-only.out"
expect_fail "build gate rejects non-default dispatch ref" \
  run_build_gate "$tmp_dir/policy.json" "$tmp_dir/build-wrong-ref.out" \
  CONTEXT_REF=refs/heads/feature
expect_fail "build gate rejects stale context SHA" \
  run_build_gate "$tmp_dir/policy.json" "$tmp_dir/build-stale-sha.out" \
  CONTEXT_SHA=2222222222222222222222222222222222222222
expect_fail "build gate rejects non-owner rerun" \
  run_build_gate "$tmp_dir/policy.json" "$tmp_dir/build-rerun.out" \
  TRIGGERING_ACTOR=mallory

init_repo() {
  local destination="$1"
  mkdir -p "$destination/docs" "$destination/nested"
  git -C "$destination" init -q
  git -C "$destination" config user.name test
  git -C "$destination" config user.email test@example.invalid
  printf 'before\n' >"$destination/docs/base.txt"
  printf 'fixture only\n' >"$destination/.env.example"
  printf '{"fixture":"credential"}\n' >"$destination/credentials.json"
  printf 'fixture: secret\n' >"$destination/nested/secrets.yml"
  git -C "$destination" add docs/base.txt .env.example credentials.json nested/secrets.yml
  git -C "$destination" commit -qm base
}

pure_bin_dir="$tmp_dir/pure-bin"
mkdir -p "$pure_bin_dir"
ln -s "$repo_root/tests/fixtures/fake-opencode-pure" "$pure_bin_dir/opencode"

model_repo="$tmp_dir/model-repo"
model_runner_temp="$tmp_dir/model-runner"
init_repo "$model_repo"
mkdir -p "$model_runner_temp"
model_head="$(git -C "$model_repo" rev-parse HEAD)"
model_config_before="$(sha256sum "$model_repo/.git/config" | awk '{print $1}')"
request_base64="$(printf '%s' 'Update the bounded documentation.' | base64 -w 0)"
policy_base64="$(base64 -w 0 "$tmp_dir/policy.json")"
(
  cd "$model_repo"
  env \
    EXPECTED_SHA="$model_head" \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_VALUE_0=/dev/null \
    GIT_OPTIONAL_LOCKS=0 \
    HOME="$model_runner_temp/home" \
    MODEL=fixture/model \
    OPENCODE_AUTO_SHARE=false \
    OPENCODE_CONFIG_CONTENT="$build_model_config" \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_DISABLE_CLAUDE_CODE=true \
    OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
    OPENCODE_DISABLE_EXTERNAL_SKILLS=true \
    OPENCODE_DISABLE_LSP_DOWNLOAD=true \
    OPENCODE_DISABLE_PROJECT_CONFIG=true \
    OPENCODE_TEST_PURE_MODE=build \
    PATH="$pure_bin_dir:$PATH" \
    POLICY_BASE64="$policy_base64" \
    REQUEST_BASE64="$request_base64" \
    RUNNER_TEMP="$model_runner_temp" \
    XDG_CACHE_HOME="$model_runner_temp/xdg/cache" \
    XDG_CONFIG_HOME="$model_runner_temp/xdg/config" \
    XDG_DATA_HOME="$model_runner_temp/xdg/data" \
    XDG_STATE_HOME="$model_runner_temp/xdg/state" \
      bash "$tmp_dir/build-model.sh"
)
[[ "$(git -C "$model_repo" rev-parse HEAD)" == "$model_head" ]] || die "model runner changed HEAD"
[[ "$(sha256sum "$model_repo/.git/config" | awk '{print $1}')" == "$model_config_before" ]] ||
  die "model runner changed protected Git config"
[[ ! -w "$model_repo/.git/config" ]] || die "model runner reopened protected Git config"
git -C "$model_repo" diff --quiet || die "model runner left unstaged changes"
git -C "$model_repo" diff --cached --quiet && die "model runner failed to stage the model edit"
[[ "$(git -C "$model_repo" diff --cached --name-only)" == "docs/base.txt" ]] ||
  die "model runner staged an unexpected path"
pass "full model fixture protects Git metadata and reopens only deterministic staging paths"

review_model_repo="$tmp_dir/review-model-repo"
review_model_runner="$tmp_dir/review-model-runner"
review_model_output="$tmp_dir/review-model.out"
init_repo "$review_model_repo"
mkdir -p "$review_model_runner"
review_model_head="$(git -C "$review_model_repo" rev-parse HEAD)"
(
  cd "$review_model_repo"
  env \
    GITHUB_OUTPUT="$review_model_output" \
    HOME="$review_model_runner/home" \
    MODEL=fixture/model \
    OPENCODE_AUTO_SHARE=false \
    OPENCODE_CONFIG_CONTENT="$review_model_config" \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_DISABLE_CLAUDE_CODE=true \
    OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
    OPENCODE_DISABLE_EXTERNAL_SKILLS=true \
    OPENCODE_DISABLE_LSP_DOWNLOAD=true \
    OPENCODE_DISABLE_PROJECT_CONFIG=true \
    OPENCODE_TEST_PURE_MODE=review \
    PATH="$pure_bin_dir:$PATH" \
    PROMPT_BASE64="$(printf '%s' 'Review the bounded fixture.' | base64 -w 0)" \
    RUNNER_TEMP="$review_model_runner" \
    XDG_CACHE_HOME="$review_model_runner/xdg/cache" \
    XDG_CONFIG_HOME="$review_model_runner/xdg/config" \
    XDG_DATA_HOME="$review_model_runner/xdg/data" \
    XDG_STATE_HOME="$review_model_runner/xdg/state" \
      bash "$tmp_dir/review-model.sh"
)
[[ "$(git -C "$review_model_repo" rev-parse HEAD)" == "$review_model_head" &&
   -z "$(git -C "$review_model_repo" status --porcelain)" ]] ||
  die "offline review fixture mutated the repository"
grep -Eq -- '^response_base64=' "$review_model_output" ||
  die "offline review fixture did not emit bounded output"
pass "offline fixture enforces the exact pure-mode invocation and isolated runtime contract"

run_validator() {
  local destination="$1"
  local policy_file="$2"
  local patch_file="$3"
  local validator="$4"
  (
    cd "$destination"
    POLICY_PATH="$policy_file" \
    POLICY_SHA256="$(sha256sum "$policy_file" | awk '{print $1}')" \
    VALIDATED_PATCH_PATH="$patch_file" \
      bash "$validator"
  )
}

valid_repo="$tmp_dir/valid-repo"
init_repo "$valid_repo"
printf 'after\n' >"$valid_repo/docs/base.txt"
git -C "$valid_repo" add docs/base.txt
run_validator "$valid_repo" "$tmp_dir/policy.json" "$tmp_dir/valid.patch" "$tmp_dir/build-validate-model.sh"
[[ -s "$tmp_dir/valid.patch" ]] || die "validator did not emit a patch"
pass "model-side validator accepts one bounded text change"

publish_repo="$tmp_dir/publish-repo"
git clone -q "$valid_repo" "$publish_repo"
git -C "$publish_repo" apply --index --whitespace=error-all "$tmp_dir/valid.patch"
run_validator "$publish_repo" "$tmp_dir/policy.json" "$tmp_dir/revalidated.patch" "$tmp_dir/build-validate-publish.sh"
cmp "$tmp_dir/valid.patch" "$tmp_dir/revalidated.patch" >/dev/null || die "publish validator changed canonical patch bytes"
pass "publish-side validator independently reproduces the exact canonical patch"

denied_repo="$tmp_dir/denied-repo"
init_repo "$denied_repo"
mkdir -p "$denied_repo/.github/workflows"
printf 'name: hostile\n' >"$denied_repo/.github/workflows/hostile.yml"
git -C "$denied_repo" add .github/workflows/hostile.yml
jq '.allowed_prefixes += [".github/"]' "$tmp_dir/policy.json" >"$tmp_dir/policy-allows-github.json"
expect_fail "validator central deny overrides repository workflow allowance" \
  run_validator "$denied_repo" "$tmp_dir/policy-allows-github.json" "$tmp_dir/denied.patch" "$tmp_dir/build-validate-model.sh"

delete_repo="$tmp_dir/delete-repo"
init_repo "$delete_repo"
git -C "$delete_repo" rm -q docs/base.txt
expect_fail "validator rejects file deletion" \
  run_validator "$delete_repo" "$tmp_dir/policy.json" "$tmp_dir/delete.patch" "$tmp_dir/build-validate-model.sh"

binary_repo="$tmp_dir/binary-repo"
init_repo "$binary_repo"
printf '\0binary\n' >"$binary_repo/docs/binary.dat"
git -C "$binary_repo" add docs/binary.dat
expect_fail "validator rejects binary content" \
  run_validator "$binary_repo" "$tmp_dir/policy.json" "$tmp_dir/binary.patch" "$tmp_dir/build-validate-model.sh"

dependency_repo="$tmp_dir/dependency-repo"
init_repo "$dependency_repo"
printf '{}\n' >"$dependency_repo/package.json"
git -C "$dependency_repo" add package.json
jq '.allowed_exact += ["package.json"]' "$tmp_dir/policy.json" >"$tmp_dir/policy-allows-dependency.json"
expect_fail "validator central deny overrides dependency-manifest allowance" \
  run_validator "$dependency_repo" "$tmp_dir/policy-allows-dependency.json" "$tmp_dir/dependency.patch" "$tmp_dir/build-validate-model.sh"

outside_repo="$tmp_dir/outside-repo"
init_repo "$outside_repo"
mkdir -p "$outside_repo/src"
printf 'outside\n' >"$outside_repo/src/outside.txt"
git -C "$outside_repo" add src/outside.txt
expect_fail "validator rejects a path outside repository allowlists" \
  run_validator "$outside_repo" "$tmp_dir/policy.json" "$tmp_dir/outside.patch" "$tmp_dir/build-validate-model.sh"

curl() {
  local data_binary=""
  local destination=""
  local method="GET"
  local url=""
  local write_format=""
  while (($#)); do
    case "$1" in
      --request)
        shift
        method="${1:-}"
        ;;
      --output)
        shift
        destination="${1:-}"
        ;;
      --write-out)
        shift
        write_format="${1:-}"
        ;;
      --data-binary)
        shift
        data_binary="${1:-}"
        ;;
      https://*) url="$1" ;;
    esac
    shift || true
  done

  if [[ "$method" == "POST" ]]; then
    printf 'POST %s %s\n' "${OPENCODE_TEST_CURL_MODE:-unset}" "$url" >>"${OPENCODE_TEST_CURL_LOG:?}"
    case "${OPENCODE_TEST_CURL_MODE:-}" in
      build-success|build-pr-head-mismatch|build-persisted-mismatch)
        repository="${REPOSITORY:?}"
        branch_sha="$("$OPENCODE_TEST_REAL_GIT" rev-parse HEAD)"
        [[ "${OPENCODE_TEST_CURL_MODE}" != build-pr-head-mismatch ]] ||
          branch_sha=5555555555555555555555555555555555555555
        jq -cn \
          --argjson payload "$data_binary" \
          --arg repository "$repository" \
          --arg sha "$branch_sha" '
            {
              number: 42,
              state: "open",
              draft: true,
              title: $payload.title,
              body: $payload.body,
              html_url: ("https://github.com/" + $repository + "/pull/42"),
              base: {
                ref: $payload.base,
                sha: env.TARGET_SHA,
                repo: {full_name: $repository}
              },
              head: {
                ref: $payload.head,
                sha: $sha,
                repo: {full_name: $repository}
              }
            }
          '
        return 0
        ;;
      *)
        return 56
        ;;
    esac
  fi

  case "$url" in
    *'/issues/'*'/comments?'*)
      printf '[]\n'
      ;;
    *"/git/ref/heads/${DEFAULT_BRANCH:?}")
      jq -cn --arg ref "refs/heads/${DEFAULT_BRANCH}" --arg sha "${TARGET_SHA:?}" \
        '{ref: $ref, object: {type: "commit", sha: $sha}}'
      ;;
    *'/pulls?'*)
      if [[ "${OPENCODE_TEST_CURL_MODE:-}" == build-existing ||
            "${OPENCODE_TEST_CURL_MODE:-}" == build-closed ||
            "${OPENCODE_TEST_CURL_MODE:-}" == build-ready ]]; then
        pull_state=open
        pull_draft=true
        [[ "${OPENCODE_TEST_CURL_MODE}" != build-closed ]] || pull_state=closed
        [[ "${OPENCODE_TEST_CURL_MODE}" != build-ready ]] || pull_draft=false
        jq -cn \
          --arg base "${DEFAULT_BRANCH:?}" \
          --arg body "Owner-authorized OpenCode draft from [workflow run](${SERVER_URL:?}/${REPOSITORY:?}/actions/runs/${RUN_ID:?}). Exact base: \`${TARGET_SHA:?}\`. Review and merge manually; this workflow never pushes to the default branch.

<!-- opencode-build:${RUN_ID}:${PATCH_SHA256:?} -->" \
          --arg branch "opencode/${RUN_ID}" \
          --arg repository "${REPOSITORY:?}" \
          --arg state "$pull_state" \
          --argjson draft "$pull_draft" '
            [{
              number: 42,
              state: $state,
              draft: $draft,
              title: ("OpenCode draft " + env.RUN_ID),
              body: $body,
              html_url: ("https://github.com/" + $repository + "/pull/42"),
              base: {
                ref: $base,
                sha: env.TARGET_SHA,
                repo: {full_name: $repository}
              },
              head: {
                ref: $branch,
                sha: "2222222222222222222222222222222222222222",
                repo: {full_name: $repository}
              }
            }]
          '
      else
        printf '[]\n'
      fi
      ;;
    *'/pulls/42')
      repository="${REPOSITORY:?}"
      branch_sha="$("$OPENCODE_TEST_REAL_GIT" rev-parse HEAD)"
      [[ "${OPENCODE_TEST_CURL_MODE:-}" != build-persisted-mismatch ]] ||
        branch_sha=5555555555555555555555555555555555555555
      jq -cn \
        --arg repository "$repository" \
        --arg sha "$branch_sha" '
          {
            number: 42,
            state: "open",
            draft: true,
            title: ("OpenCode draft " + env.RUN_ID),
            body: ("Owner-authorized OpenCode draft from [workflow run](" +
              env.SERVER_URL + "/" + $repository + "/actions/runs/" + env.RUN_ID +
              "). Exact base: `" + env.TARGET_SHA +
              "`. Review and merge manually; this workflow never pushes to the default branch.\n\n" +
              "<!-- opencode-build:" + env.RUN_ID + ":" + env.PATCH_SHA256 + " -->"),
            html_url: ("https://github.com/" + $repository + "/pull/42"),
            base: {
              ref: env.DEFAULT_BRANCH,
              sha: env.TARGET_SHA,
              repo: {full_name: $repository}
            },
            head: {
              ref: ("opencode/" + env.RUN_ID),
              sha: $sha,
              repo: {full_name: $repository}
            }
          }
        '
      ;;
    *'/git/commits/'*)
      requested_sha="${url##*/}"
      jq -cn \
        --arg sha "$requested_sha" \
        --arg parent "${TARGET_SHA:?}" \
        --arg tree "${expected_tree:?}" \
        '{sha: $sha, tree: {sha: $tree}, parents: [{sha: $parent}]}'
      ;;
    *'/git/ref/heads/opencode/'*)
      ref_exists=false
      branch_sha=""
      case "${OPENCODE_TEST_CURL_MODE:-}" in
        build-existing|build-closed|build-ready)
          ref_exists=true
          branch_sha=2222222222222222222222222222222222222222
          ;;
        *)
          if [[ -s "${OPENCODE_TEST_GIT_LOG:-/dev/null}" ]]; then
            ref_exists=true
            branch_sha="$("$OPENCODE_TEST_REAL_GIT" rev-parse HEAD)"
          fi
          ;;
      esac
      if [[ "$ref_exists" != true ]]; then
        [[ -n "$destination" && -n "$write_format" ]] || return 22
        printf '{"message":"Not Found"}\n' >"$destination"
        printf '404'
      else
        ref_json="$(jq -cn \
          --arg ref "refs/heads/opencode/${RUN_ID:?}" \
          --arg sha "$branch_sha" \
          '{ref: $ref, object: {type: "commit", sha: $sha}}')"
        if [[ -n "$destination" && -n "$write_format" ]]; then
          printf '%s\n' "$ref_json" >"$destination"
          printf '200'
        else
          printf '%s\n' "$ref_json"
        fi
      fi
      ;;
    *)
      printf 'unexpected workflow fixture URL: %s\n' "$url" >&2
      return 64
      ;;
  esac
}
export -f curl

review_response='Bounded fixture response.'
review_response_base64="$(printf '%s' "$review_response" | base64 -w 0)"
review_response_sha256="$(printf '%s' "$review_response" | sha256sum | awk '{print $1}')"
review_curl_log="$tmp_dir/review-curl.log"
review_runner_temp="$tmp_dir/review-publish-runner"
mkdir -p "$review_runner_temp"

run_review_publish() {
  local comments_fixture="$1"
  local mode="$2"
  shift 2
  env \
    API_URL=https://api.github.test \
    COMMAND=review \
    GH_TOKEN=test-only \
    ISSUE_NUMBER=17 \
    OPENCODE_TEST_COMMENTS_JSON="$comments_fixture" \
    OPENCODE_TEST_CURL_LOG="$review_curl_log" \
    OPENCODE_TEST_CURL_MODE="$mode" \
    REPOSITORY="$repo" \
    RESPONSE_BASE64="$review_response_base64" \
    RESPONSE_SHA256="$review_response_sha256" \
    RUN_ID=7001 \
    RUNNER_TEMP="$review_runner_temp" \
    SERVER_URL=https://github.test \
    TARGET_SHA="$sha" \
    "$@" \
      bash "$tmp_dir/review-publish.sh"
}

: >"$review_curl_log"
expect_fail "review publisher reports an ambiguous one-shot POST without retrying" \
  run_review_publish "" review-fail
[[ "$(grep -cE -- '^POST ' "$review_curl_log" || true)" == "1" ]] ||
  die "review publisher attempted its POST more than once"
review_marker="<!-- opencode-review:7001:${sha}:review -->"
jq -n --arg body "$review_marker" '[{user: {id: 41898282}, body: $body}]' >"$tmp_dir/existing-comments.json"
: >"$review_curl_log"
run_review_publish "$tmp_dir/existing-comments.json" review-existing
[[ ! -s "$review_curl_log" ]] || die "review publisher wrote after finding its deterministic marker"
changed_response='A different bounded response after rerun.'
: >"$review_curl_log"
run_review_publish "$tmp_dir/existing-comments.json" review-existing \
  RESPONSE_BASE64="$(printf '%s' "$changed_response" | base64 -w 0)" \
  RESPONSE_SHA256="$(printf '%s' "$changed_response" | sha256sum | awk '{print $1}')"
[[ ! -s "$review_curl_log" ]] ||
  die "review response drift bypassed the stable execution marker"
pass "review rerun marker suppresses duplicates even when model text changes"

build_publish_repo="$tmp_dir/build-publish-repo"
build_retry_repo="$tmp_dir/build-retry-repo"
build_success_repo="$tmp_dir/build-success-repo"
build_closed_repo="$tmp_dir/build-closed-repo"
build_ready_repo="$tmp_dir/build-ready-repo"
build_head_mismatch_repo="$tmp_dir/build-head-mismatch-repo"
build_persisted_mismatch_repo="$tmp_dir/build-persisted-mismatch-repo"
for destination in \
  "$build_publish_repo" \
  "$build_retry_repo" \
  "$build_success_repo" \
  "$build_closed_repo" \
  "$build_ready_repo" \
  "$build_head_mismatch_repo" \
  "$build_persisted_mismatch_repo"; do
  init_repo "$destination"
  printf 'after publish\n' >"$destination/docs/base.txt"
  git -C "$destination" add docs/base.txt
done

build_patch_sha256="$(printf '%s' 'bounded patch fixture' | sha256sum | awk '{print $1}')"
build_curl_log="$tmp_dir/build-curl.log"
build_git_log="$tmp_dir/build-git.log"
build_runner_temp="$tmp_dir/build-publish-runner"
mkdir -p "$build_runner_temp"
OPENCODE_TEST_REAL_GIT="$(command -v git)"
export OPENCODE_TEST_REAL_GIT

git() {
  if [[ "${1:-}" == "push" ]]; then
    printf 'PUSH %s\n' "$*" >>"${OPENCODE_TEST_GIT_LOG:?}"
    return 0
  fi
  "$OPENCODE_TEST_REAL_GIT" "$@"
}
export -f git

run_build_publish() {
  local destination="$1"
  local mode="$2"
  local target
  target="$(git -C "$destination" rev-parse HEAD)"
  (
    cd "$destination"
    env \
      API_URL=https://api.github.test \
      DEFAULT_BRANCH=main \
      GH_TOKEN=test-only \
      OPENCODE_TEST_CURL_LOG="$build_curl_log" \
      OPENCODE_TEST_CURL_MODE="$mode" \
      OPENCODE_TEST_GIT_LOG="$build_git_log" \
      PATCH_SHA256="$build_patch_sha256" \
      REPOSITORY="$repo" \
      RUN_ATTEMPT=1 \
      RUN_ID=8001 \
      RUNNER_TEMP="$build_runner_temp" \
      SERVER_URL=https://github.test \
      TARGET_SHA="$target" \
        bash "$tmp_dir/build-publish.sh"
  )
}

: >"$build_curl_log"
: >"$build_git_log"
expect_fail "build publisher reports an ambiguous one-shot PR POST without retrying" \
  run_build_publish "$build_publish_repo" build-fail
[[ "$(grep -cE -- '^POST ' "$build_curl_log" || true)" == "1" ]] ||
  die "build publisher attempted its PR POST more than once"
[[ "$(grep -cE -- '^PUSH ' "$build_git_log" || true)" == "1" ]] ||
  die "build publisher did not make exactly one deterministic branch push"

: >"$build_curl_log"
: >"$build_git_log"
run_build_publish "$build_retry_repo" build-existing
[[ ! -s "$build_curl_log" ]] || die "build publisher wrote after finding its deterministic pull request"
[[ ! -s "$build_git_log" ]] || die "build publisher pushed after finding its deterministic pull request"
pass "build rerun preflight suppresses duplicate branches and pull requests after an ambiguous failure"

: >"$build_curl_log"
: >"$build_git_log"
expect_fail "closed deterministic build pull request is terminal" \
  run_build_publish "$build_closed_repo" build-closed
grep -Fq -- 'closed or merged; that run is terminal' "$tmp_dir/expected-failure.err" ||
  die "closed build pull request did not report terminal state"
[[ ! -s "$build_curl_log" && ! -s "$build_git_log" ]] ||
  die "terminal build pull request caused a write"

: >"$build_curl_log"
: >"$build_git_log"
run_build_publish "$build_ready_repo" build-ready
[[ ! -s "$build_curl_log" && ! -s "$build_git_log" ]] ||
  die "human-promoted build pull request caused a write"
pass "closed build results are terminal and human-promoted results remain read-only"

: >"$build_curl_log"
: >"$build_git_log"
run_build_publish "$build_success_repo" build-success
[[ "$(grep -cE -- '^POST ' "$build_curl_log" || true)" == "1" &&
   "$(grep -cE -- '^PUSH ' "$build_git_log" || true)" == "1" ]] ||
  die "successful build publication did not perform one push and one PR POST"
pass "build publisher verifies a freshly persisted branch, commit, and pull request"

: >"$build_curl_log"
: >"$build_git_log"
expect_fail "build publisher rejects mismatched PR head response" \
  run_build_publish "$build_head_mismatch_repo" build-pr-head-mismatch
[[ "$(grep -cE -- '^POST ' "$build_curl_log" || true)" == "1" ]] ||
  die "mismatched build PR response was retried"

: >"$build_curl_log"
: >"$build_git_log"
expect_fail "build publisher rejects mismatched persisted PR" \
  run_build_publish "$build_persisted_mismatch_repo" build-persisted-mismatch
[[ "$(grep -cE -- '^POST ' "$build_curl_log" || true)" == "1" ]] ||
  die "mismatched persisted build PR was retried"
pass "build publisher fails closed on response and persisted-state mismatches"

printf '1..%d\n' "$pass_count"
