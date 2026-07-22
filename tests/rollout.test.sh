#!/usr/bin/env bash

set -euo pipefail

test_path="$(readlink -f "${BASH_SOURCE[0]}")"
fleet_root="$(cd "$(dirname "$test_path")/.." && pwd)"
manifest="$fleet_root/tests/fixtures/fleet-rollout-repos.json"
central_sha=0123456789abcdef0123456789abcdef01234567
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

central_root="$temp_root/central"
mkdir -p \
  "$central_root/config" \
  "$central_root/templates/callers" \
  "$central_root/templates/policies" \
  "$central_root/.github/workflows"
cp "$manifest" "$central_root/config/repos.json"
cp "$fleet_root/templates/callers/review.yml.tpl" \
  "$fleet_root/templates/callers/build.yml.tpl" \
  "$central_root/templates/callers/"
cp "$fleet_root/templates/policies/restricted.json.tpl" \
  "$fleet_root/templates/policies/standard.json.tpl" \
  "$central_root/templates/policies/"
cp "$fleet_root/.github/workflows/review.yml" \
  "$fleet_root/.github/workflows/build.yml" \
  "$central_root/.github/workflows/"

fake_bin="$temp_root/bin"
mkdir -p "$fake_bin"
ln -s "$fleet_root/tests/fixtures/fake-gh-rollout" "$fake_bin/gh"

common_env=(
  PATH="$fake_bin:$PATH"
  OPENCODE_FLEET_MANIFEST="$manifest"
  FAKE_GH_CENTRAL_ROOT="$central_root"
)

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    printf 'expected command to fail: %q ' "$@" >&2
    printf '\n' >&2
    exit 1
  fi
}

# Rendering requires an immutable central commit and refuses preexisting output.
assert_fails env OPENCODE_FLEET_MANIFEST="$manifest" \
  "$fleet_root/scripts/render-callers" \
  --repository ExampleRestricted \
  --central-sha latest \
  --output "$temp_root/invalid-sha"
assert_fails env OPENCODE_FLEET_MANIFEST="$manifest" \
  "$fleet_root/scripts/render-callers" \
  --repository ExampleRestricted \
  --central-sha 0000000000000000000000000000000000000000 \
  --output "$temp_root/zero-sha"

nonempty_output="$temp_root/nonempty"
mkdir -p "$nonempty_output"
touch "$nonempty_output/owned-by-someone-else"
assert_fails env OPENCODE_FLEET_MANIFEST="$manifest" \
  "$fleet_root/scripts/render-callers" \
  --repository ExampleRestricted \
  --central-sha "$central_sha" \
  --output "$nonempty_output"

restricted_output="$temp_root/restricted"
restricted_metadata="$(
  env OPENCODE_FLEET_MANIFEST="$manifest" \
    "$fleet_root/scripts/render-callers" \
    --repository ExampleRestricted \
    --central-sha "$central_sha" \
    --output "$restricted_output"
)"
jq -e '.githubMode == "review" and (.files | length) == 2' \
  <<<"$restricted_metadata" >/dev/null
[[ -f "$restricted_output/.github/workflows/opencode-review.yml" ]]
[[ ! -e "$restricted_output/.github/workflows/opencode-build.yml" ]]
jq -e '
  (keys | sort) == [
    "allowed_exact",
    "allowed_prefixes",
    "max_files",
    "max_patch_bytes",
    "mode",
    "version"
  ] and .mode == "review-only"
' "$restricted_output/.github/opencode-policy.json" >/dev/null
grep -Fq "review.yml@$central_sha" \
  "$restricted_output/.github/workflows/opencode-review.yml"
grep -Fq 'github.actor_id == 133295304' \
  "$restricted_output/.github/workflows/opencode-review.yml"
grep -Fq "github.event.comment.author_association == 'OWNER'" \
  "$restricted_output/.github/workflows/opencode-review.yml"
grep -Fq "github.event.comment.body == '/oc review'" \
  "$restricted_output/.github/workflows/opencode-review.yml"
grep -Fq "github.event.comment.body == '/oc plan'" \
  "$restricted_output/.github/workflows/opencode-review.yml"
if grep -Fq "github.event.comment.body == '/opencode'" \
   "$restricted_output/.github/workflows/opencode-review.yml"; then
  printf 'review caller accepted the forbidden /opencode alias\n' >&2
  exit 1
fi
if grep -Eq 'id-token|secrets:|OPENCODE_API_KEY|@latest' \
   "$restricted_output/.github/workflows/opencode-review.yml"; then
  printf 'review caller widened credentials or used a mutable reference\n' >&2
  exit 1
fi

standard_output="$temp_root/standard"
standard_metadata="$(
  env OPENCODE_FLEET_MANIFEST="$manifest" \
    "$fleet_root/scripts/render-callers" \
    --repository ExampleStandard \
    --central-sha "$central_sha" \
    --output "$standard_output"
)"
jq -e '.githubMode == "manual-build" and (.files | length) == 3' \
  <<<"$standard_metadata" >/dev/null
jq -e '
  .mode == "draft-pr" and
  .max_files == 20 and
  .max_patch_bytes == 204800 and
  .allowed_exact == ["README.md"] and
  .allowed_prefixes == ["docs/", "tests/"] and
  ([.allowed_prefixes[], .allowed_exact[]] |
    all(. != "app/" and . != "src/" and . != "scripts/" and
        . != "aphrodite/" and . != "argus/" and . != "mnemosyne/"))
' \
  "$standard_output/.github/opencode-policy.json" >/dev/null
grep -Fq "build.yml@$central_sha" \
  "$standard_output/.github/workflows/opencode-build.yml"
grep -Fq 'github.actor_id == 133295304' \
  "$standard_output/.github/workflows/opencode-build.yml"
grep -Fq 'github.ref_name == github.event.repository.default_branch' \
  "$standard_output/.github/workflows/opencode-build.yml"
if grep -Eq 'id-token|secrets:|OPENCODE_API_KEY|@latest|environment:' \
   "$standard_output/.github/workflows/opencode-build.yml"; then
  printf 'build caller bypassed the central environment/secret contract\n' >&2
  exit 1
fi

assert_fails env OPENCODE_FLEET_MANIFEST="$manifest" \
  "$fleet_root/scripts/render-callers" \
  --repository Empty --central-sha "$central_sha" --output "$temp_root/empty-render"
assert_fails env OPENCODE_FLEET_MANIFEST="$manifest" \
  "$fleet_root/scripts/render-callers" \
  --repository curriculum --central-sha "$central_sha" --output "$temp_root/curriculum-render"

# A caller-supplied local manifest cannot replace the manifest fetched from the
# authorized central commit. The rollout still resolves the pinned identity.
malicious_manifest="$temp_root/malicious-manifest.json"
jq '.owner = "Mallory" | .repositories[0].fullName = "Mallory/ExampleRestricted"' \
  "$manifest" >"$malicious_manifest"
malicious_log="$temp_root/malicious-manifest.log"
pinned_manifest_plan="$(env \
  PATH="$fake_bin:$PATH" \
  OPENCODE_FLEET_MANIFEST="$malicious_manifest" \
  FAKE_GH_CENTRAL_ROOT="$central_root" \
  FAKE_GH_LOG="$malicious_log" \
  "$fleet_root/scripts/github-rollout" \
  ExampleRestricted --central-sha "$central_sha")"
jq -e '.ready == true and .fullName == "Ayyitskevin/ExampleRestricted"' \
  <<<"$pinned_manifest_plan" >/dev/null
grep -Fq $'GET\trepos/Ayyitskevin/opencode-fleet/contents/config/repos.json?ref=' \
  "$malicious_log"

invalid_branch_manifest="$temp_root/invalid-branch-manifest.json"
jq '(.repositories[] | select(.name == "ExampleRestricted") | .defaultBranch) = "main//escape"' \
  "$manifest" >"$invalid_branch_manifest"
invalid_branch_log="$temp_root/invalid-branch-manifest.log"
invalid_local_plan="$(env \
  PATH="$fake_bin:$PATH" \
  OPENCODE_FLEET_MANIFEST="$invalid_branch_manifest" \
  FAKE_GH_CENTRAL_ROOT="$central_root" \
  FAKE_GH_LOG="$invalid_branch_log" \
  "$fleet_root/scripts/github-rollout" \
  ExampleRestricted --central-sha "$central_sha")"
jq -e '.ready == true and .defaultBranch == "main"' \
  <<<"$invalid_local_plan" >/dev/null

# By contrast, malformed content fetched from the pinned central commit fails
# before the first consumer-repository API lookup or external write.
bad_central_root="$temp_root/bad-central"
cp -a "$central_root" "$bad_central_root"
jq '.owner = "Mallory" | .repositories[0].fullName = "Mallory/ExampleRestricted"' \
  "$manifest" >"$bad_central_root/config/repos.json"
bad_central_log="$temp_root/bad-central.log"
assert_fails env \
  PATH="$fake_bin:$PATH" \
  FAKE_GH_CENTRAL_ROOT="$bad_central_root" \
  FAKE_GH_LOG="$bad_central_log" \
  "$fleet_root/scripts/github-rollout" \
  ExampleRestricted --central-sha "$central_sha"
if grep -Eq $'^GET\trepos/Ayyitskevin/ExampleRestricted|^(POST|PUT|PATCH|DELETE)' \
   "$bad_central_log"; then
  printf 'invalid pinned manifest reached consumer state or mutation\n' >&2
  exit 1
fi

# Explicit public metadata is accepted and reaches the normal consumer
# readiness plan. The adversarial variants below remain readable API responses.
public_central_log="$temp_root/public-central.log"
public_central_plan="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$public_central_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleRestricted --central-sha "$central_sha"
)"
jq -e '.ready == true and .fullName == "Ayyitskevin/ExampleRestricted"' \
  <<<"$public_central_plan" >/dev/null
grep -Fq $'GET\trepos/Ayyitskevin/opencode-fleet' "$public_central_log"

central_trust_cases=(
  'FAKE_GH_PRIVATE_CENTRAL|explicitly public'
  'FAKE_GH_MISSING_CENTRAL_VISIBILITY|explicitly public'
  'FAKE_GH_MISSING_CENTRAL_PRIVATE|explicitly public'
  'FAKE_GH_CONTRADICTORY_CENTRAL_VISIBILITY|explicitly public'
  'FAKE_GH_UNAUTHORIZED_CENTRAL_SHA|authorized default-branch lineage'
  'FAKE_GH_BAD_CENTRAL_BLOB|does not match its Git blob ID'
)
for central_trust_case in "${central_trust_cases[@]}"; do
  IFS='|' read -r central_trust_flag central_trust_error \
    <<<"$central_trust_case"
  central_trust_log="$temp_root/central-trust-${central_trust_flag,,}.log"
  set +e
  central_trust_output="$(
    env "${common_env[@]}" \
      FAKE_GH_LOG="$central_trust_log" \
      "$central_trust_flag=1" \
      "$fleet_root/scripts/github-rollout" \
      ExampleRestricted --central-sha "$central_sha" 2>&1
  )"
  central_trust_status=$?
  set -e
  [[ "$central_trust_status" -ne 0 ]]
  grep -Fq "$central_trust_error" <<<"$central_trust_output"
  if grep -Eq $'^GET\trepos/Ayyitskevin/ExampleRestricted|^(POST|PUT|PATCH|DELETE)' \
     "$central_trust_log"; then
    printf '%s central trust failure reached consumer state or mutation\n' \
      "$central_trust_flag" >&2
    exit 1
  fi
done

# The rollout always uses its owned renderer; an environment value cannot
# substitute executable policy or metadata.
pinned_renderer_plan="$(
  env "${common_env[@]}" \
    OPENCODE_FLEET_RENDERER="$temp_root/attacker-renderer" \
    FAKE_GH_LOG="$temp_root/pinned-renderer.log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleRestricted --central-sha "$central_sha"
)"
jq -e '.ready == true and .fullName == "Ayyitskevin/ExampleRestricted"' \
  <<<"$pinned_renderer_plan" >/dev/null

# Dry-run planning uses only GET requests and canonical GitHub identities.
restricted_log="$temp_root/restricted-plan.log"
restricted_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$restricted_log" \
    "$fleet_root/scripts/github-rollout" ExampleRestricted --central-sha "$central_sha"
)"
jq -e '
  .ready == true and
  .applyRequested == false and
  .baseCommit == "1111111111111111111111111111111111111111" and
  (.operations.write | length) == 2 and
  (.operations.delete | index(".github/workflows/opencode.yml")) != null and
  .operations.draftPullRequest == true
' <<<"$restricted_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$restricted_log"; then
  printf 'plan-only rollout attempted a GitHub write\n' >&2
  exit 1
fi
grep -Fq $'GET\trepos/Ayyitskevin/ExampleRestricted/git/trees/2222222222222222222222222222222222222222?recursive=1' \
  "$restricted_log"
if grep -Fq $'GET\trepos/Ayyitskevin/ExampleRestricted/contents/.github/workflows/opencode.yml' \
   "$restricted_log"; then
  printf 'plan inspected legacy state through a mutable contents lookup\n' >&2
  exit 1
fi

# Restricted mode also removes a stale build caller discovered in the same
# immutable tree snapshot.
stale_build_plan="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$temp_root/stale-build.log" \
    FAKE_GH_STALE_BUILD=1 \
    "$fleet_root/scripts/github-rollout" \
    ExampleRestricted --central-sha "$central_sha"
)"
jq -e '
  .ready == true and
  (.operations.delete | sort) == [
    ".github/workflows/opencode-build.yml",
    ".github/workflows/opencode.yml"
  ]
' <<<"$stale_build_plan" >/dev/null

standard_log="$temp_root/standard-plan.log"
standard_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$standard_log" \
    "$fleet_root/scripts/github-rollout" ExampleStandard --central-sha "$central_sha"
)"
jq -e '
  .ready == true and
  .operations.createBranch == true and
  .operations.draftPullRequest == true and
  (.operations.write | length) == 3
' \
  <<<"$standard_plan" >/dev/null
grep -Fq $'GET\trepos/Ayyitskevin/ExampleStandard/environments/opencode-build/secrets' \
  "$standard_log"
grep -Fq $'GET\trepos/Ayyitskevin/ExampleStandard/branches/main/protection' \
  "$standard_log"

focal_log="$temp_root/focal-plan.log"
focal_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$focal_log" \
    "$fleet_root/scripts/github-rollout" Focal --central-sha "$central_sha"
)"
jq -e '.ready == true and (.specialCases | length) == 1' <<<"$focal_plan" >/dev/null
grep -Fq $'GET\trepos/Ayyitskevin/Focal' "$focal_log"
if grep -Fq 'Ayyitskevin/mise' "$focal_log"; then
  printf 'Focal rollout used the legacy Mise alias\n' >&2
  exit 1
fi

chronos_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$temp_root/chronos-plan.log" \
    "$fleet_root/scripts/github-rollout" Chronos --central-sha "$central_sha"
)"
jq -e '
  .ready == true and
  .defaultBranch == "feat/wheel-dashboard-mvp" and
  (.specialCases | length) == 1
' <<<"$chronos_plan" >/dev/null

# Empty and local/manual-only repositories stop after the pinned central
# catalog is verified; they never inspect or mutate a consumer repository.
curriculum_log="$temp_root/curriculum-plan.log"
curriculum_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$curriculum_log" \
    "$fleet_root/scripts/github-rollout" curriculum --central-sha "$central_sha"
)"
jq -e '.ready == false and .githubMode == "manual"' <<<"$curriculum_plan" >/dev/null
grep -Fq $'GET\trepos/Ayyitskevin/opencode-fleet/contents/config/repos.json?ref=' \
  "$curriculum_log"
if grep -Eq $'^GET\trepos/Ayyitskevin/curriculum|^(POST|PUT|PATCH|DELETE)' \
   "$curriculum_log"; then
  printf 'manual-only repository reached consumer state or mutation\n' >&2
  exit 1
fi

minerva_log="$temp_root/minerva-plan.log"
minerva_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$minerva_log" \
    "$fleet_root/scripts/github-rollout" Minerva --central-sha "$central_sha"
)"
jq -e '.ready == false and (.blockers[0] | contains("unmerged draft PR"))' \
  <<<"$minerva_plan" >/dev/null
if grep -Eq $'^GET\trepos/Ayyitskevin/Minerva|^(POST|PUT|PATCH|DELETE)' \
   "$minerva_log"; then
  printf 'placeholder repository reached consumer state or mutation\n' >&2
  exit 1
fi
assert_fails env "${common_env[@]}" FAKE_GH_LOG="$minerva_log" \
  "$fleet_root/scripts/github-rollout" Minerva --central-sha "$central_sha" --apply

# Environment and secret drift fail closed before any mutation.
missing_secret_log="$temp_root/missing-secret.log"
set +e
missing_secret_plan="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$missing_secret_log" \
    FAKE_GH_MISSING_REVIEW_SECRET=1 \
    "$fleet_root/scripts/github-rollout" ExampleRestricted --central-sha "$central_sha"
)"
missing_secret_status=$?
set -e
[[ "$missing_secret_status" -ne 0 ]]
jq -e '.ready == false and any(.blockers[]; contains("opencode-review"))' \
  <<<"$missing_secret_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$missing_secret_log"; then
  printf 'missing review secret did not stop GitHub mutation\n' >&2
  exit 1
fi

vulcan_log="$temp_root/vulcan-plan.log"
set +e
vulcan_plan="$(
  env "${common_env[@]}" FAKE_GH_LOG="$vulcan_log" \
    "$fleet_root/scripts/github-rollout" Vulcan --central-sha "$central_sha"
)"
vulcan_status=$?
set -e
[[ "$vulcan_status" -ne 0 ]]
jq -e '
  .ready == false and
  any(.blockers[]; contains("opencode-review")) and
  (.specialCases | length) == 1
' <<<"$vulcan_plan" >/dev/null

missing_build_env_log="$temp_root/missing-build-env.log"
set +e
missing_build_env_plan="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$missing_build_env_log" \
    FAKE_GH_MISSING_BUILD_ENV=1 \
    "$fleet_root/scripts/github-rollout" ExampleStandard --central-sha "$central_sha"
)"
missing_build_env_status=$?
set -e
[[ "$missing_build_env_status" -ne 0 ]]
jq -e '.ready == false and any(.blockers[]; contains("opencode-build"))' \
  <<<"$missing_build_env_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$missing_build_env_log"; then
  printf 'missing build environment did not stop GitHub mutation\n' >&2
  exit 1
fi

# Every enrollment or build-control drift blocks before a write. Chronos also
# fails closed if its unusual default branch stops matching the catalog.
readiness_cases=(
  'ExampleStandard|FAKE_GH_BAD_BUILD_REVIEWER|exactly one required reviewer'
  'ExampleStandard|FAKE_GH_EXTRA_BUILD_REVIEWER|exactly one required reviewer'
  'ExampleStandard|FAKE_GH_BAD_BUILD_BRANCH_POLICY|exact default branch'
  'ExampleStandard|FAKE_GH_UNPROTECTED|enrollment requires strict app-bound checks'
  'ExampleRestricted|FAKE_GH_INADEQUATE_PROTECTION|enrollment requires strict app-bound checks'
  'ExampleRestricted|FAKE_GH_BAD_CHECK_APP|enrollment requires strict app-bound checks'
  'ExampleRestricted|FAKE_GH_PROTECTION_BYPASS|no PR bypass actors'
  'ExampleStandard|FAKE_GH_EXISTING_ROLLOUT_BRANCH|exact commit does not match'
  'ExampleRestricted|FAKE_GH_TREE_FAILURE|exact default-branch tree'
  'ExampleRestricted|FAKE_GH_TREE_TRUNCATED|exact default-branch tree'
  'ExampleRestricted|FAKE_GH_BRANCH_LOOKUP_FAILURE|rollout branch state is unavailable'
  'ExampleRestricted|FAKE_GH_WRONG_OWNER|fixed fleet owner'
  'Chronos|FAKE_GH_DEFAULT_MISMATCH|live default branch differs'
)
for readiness_case in "${readiness_cases[@]}"; do
  IFS='|' read -r readiness_repository readiness_flag readiness_blocker \
    <<<"$readiness_case"
  readiness_log="$temp_root/readiness-${readiness_flag,,}.log"
  set +e
  readiness_plan="$(
    env "${common_env[@]}" \
      FAKE_GH_LOG="$readiness_log" \
      "$readiness_flag=1" \
      "$fleet_root/scripts/github-rollout" \
      "$readiness_repository" --central-sha "$central_sha"
  )"
  readiness_status=$?
  set -e
  [[ "$readiness_status" -ne 0 ]]
  jq -e --arg blocker "$readiness_blocker" '
    .ready == false and any(.blockers[]; contains($blocker))
  ' <<<"$readiness_plan" >/dev/null
  if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$readiness_log"; then
    printf '%s drift did not stop GitHub mutation\n' "$readiness_flag" >&2
    exit 1
  fi
done

# An exact no-op is reported as non-ready and cannot create a pointless branch
# or pull request.
review_blob="$(git hash-object -- "$standard_output/.github/workflows/opencode-review.yml")"
policy_blob="$(git hash-object -- "$standard_output/.github/opencode-policy.json")"
build_blob="$(git hash-object -- "$standard_output/.github/workflows/opencode-build.yml")"
generated_tree_env=(
  FAKE_GH_REVIEW_BLOB_SHA="$review_blob"
  FAKE_GH_POLICY_BLOB_SHA="$policy_blob"
  FAKE_GH_BUILD_BLOB_SHA="$build_blob"
)
recovery_env=(
  FAKE_GH_EXACT_ROLLOUT_BRANCH=1
  "${generated_tree_env[@]}"
)
noop_log="$temp_root/noop.log"
set +e
noop_plan="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$noop_log" \
    FAKE_GH_NO_LEGACY=1 \
    FAKE_GH_CURRENT=1 \
    FAKE_GH_REVIEW_BLOB_SHA="$review_blob" \
    FAKE_GH_POLICY_BLOB_SHA="$policy_blob" \
    FAKE_GH_BUILD_BLOB_SHA="$build_blob" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha"
)"
noop_status=$?
set -e
[[ "$noop_status" -ne 0 ]]
jq -e '
  .ready == false and
  .operations.write == [] and
  .operations.delete == [] and
  any(.blockers[]; contains("no rollout change is needed"))
' <<<"$noop_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$noop_log"; then
  printf 'no-op rollout attempted a GitHub write\n' >&2
  exit 1
fi

# An exact deterministic branch is reconciled. A missing PR can be created
# without rewriting Git objects or the ref, and an exact existing PR makes the
# whole apply idempotent.
recovery_plan_log="$temp_root/recovery-plan.log"
recovery_plan="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_LOG="$recovery_plan_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha"
)"
jq -e '
  .ready == true and
  .operations.createBranch == false and
  .operations.draftPullRequest == true and
  .recovery.existingBranchCommit == "4444444444444444444444444444444444444444" and
  .recovery.existingPullRequest == null
' <<<"$recovery_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$recovery_plan_log"; then
  printf 'recovery plan attempted a GitHub write\n' >&2
  exit 1
fi

recovery_apply_log="$temp_root/recovery-apply.log"
recovery_apply="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_LOG="$recovery_apply_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply
)"
jq -e '
  .applied == true and .idempotent == false and
  .operations.createBranch == false and
  .pullRequest == "https://github.com/Ayyitskevin/ExampleStandard/pull/99"
' <<<"$recovery_apply" >/dev/null
[[ "$(grep -Ec '^POST' "$recovery_apply_log")" == 1 ]]
grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/pulls' "$recovery_apply_log"

idempotent_log="$temp_root/idempotent-apply.log"
idempotent_apply="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_EXISTING_ROLLOUT_PR=1 \
    FAKE_GH_LOG="$idempotent_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply
)"
jq -e '
  .applied == true and .idempotent == true and
  .operations.createBranch == false and
  .operations.draftPullRequest == false and
  .pullRequest == "https://github.com/Ayyitskevin/ExampleStandard/pull/99"
' <<<"$idempotent_apply" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$idempotent_log"; then
  printf 'idempotent rollout reconciliation attempted a GitHub write\n' >&2
  exit 1
fi

closed_pr_log="$temp_root/closed-pr.log"
set +e
closed_pr_plan="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_EXISTING_ROLLOUT_PR=1 \
    FAKE_GH_EXISTING_PR_CLOSED=1 \
    FAKE_GH_LOG="$closed_pr_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha"
)"
closed_pr_status=$?
set -e
[[ "$closed_pr_status" -ne 0 ]]
jq -e '
  .ready == false and
  any(.blockers[]; contains("closed or merged")) and
  .operations.createBranch == false
' <<<"$closed_pr_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$closed_pr_log"; then
  printf 'terminal rollout pull request caused a GitHub write\n' >&2
  exit 1
fi

promoted_pr_log="$temp_root/promoted-pr.log"
promoted_pr_apply="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_EXISTING_ROLLOUT_PR=1 \
    FAKE_GH_EXISTING_PR_READY=1 \
    FAKE_GH_LOG="$promoted_pr_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply
)"
jq -e '
  .applied == true and .idempotent == true and
  any(.specialCases[]; contains("promoted by a human"))
' <<<"$promoted_pr_apply" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$promoted_pr_log"; then
  printf 'human-promoted rollout reconciliation attempted a GitHub write\n' >&2
  exit 1
fi

# GitHub may auto-delete the deterministic branch after merge. The prior PR is
# still authoritative: its recorded head commit and full tree must match this
# exact plan before a closed result is treated as terminal or a human-promoted
# result is accepted as read-only idempotent state.
deleted_closed_log="$temp_root/deleted-closed-pr.log"
set +e
deleted_closed_plan="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_DELETED_ROLLOUT_BRANCH=1 \
    FAKE_GH_EXISTING_ROLLOUT_PR=1 \
    FAKE_GH_EXISTING_PR_CLOSED=1 \
    FAKE_GH_LOG="$deleted_closed_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha"
)"
deleted_closed_status=$?
set -e
[[ "$deleted_closed_status" -ne 0 ]]
jq -e '
  .ready == false and
  .operations.createBranch == false and
  .operations.draftPullRequest == false and
  .recovery.existingBranchCommit == null and
  .recovery.existingPullRequest ==
    "https://github.com/Ayyitskevin/ExampleStandard/pull/99" and
  any(.blockers[]; contains("closed or merged"))
' <<<"$deleted_closed_plan" >/dev/null
grep -Fq $'GET\trepos/Ayyitskevin/ExampleStandard/pulls?state=all&head=' \
  "$deleted_closed_log"
grep -Fq $'GET\trepos/Ayyitskevin/ExampleStandard/git/commits/4444444444444444444444444444444444444444' \
  "$deleted_closed_log"
grep -Fq $'GET\trepos/Ayyitskevin/ExampleStandard/git/trees/3333333333333333333333333333333333333333?recursive=1' \
  "$deleted_closed_log"
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$deleted_closed_log"; then
  printf 'closed rollout with an auto-deleted branch caused a GitHub write\n' >&2
  exit 1
fi

deleted_mismatch_log="$temp_root/deleted-pr-head-mismatch.log"
set +e
deleted_mismatch_plan="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_DELETED_ROLLOUT_BRANCH=1 \
    FAKE_GH_EXISTING_ROLLOUT_PR=1 \
    FAKE_GH_EXISTING_PR_CLOSED=1 \
    FAKE_GH_EXISTING_PR_HEAD_MISMATCH=1 \
    FAKE_GH_LOG="$deleted_mismatch_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha"
)"
deleted_mismatch_status=$?
set -e
[[ "$deleted_mismatch_status" -ne 0 ]]
jq -e '
  .ready == false and
  any(.blockers[]; contains("head commit/tree does not exactly match"))
' <<<"$deleted_mismatch_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$deleted_mismatch_log"; then
  printf 'mismatched prior PR head caused a GitHub write\n' >&2
  exit 1
fi

deleted_promoted_log="$temp_root/deleted-promoted-pr.log"
deleted_promoted_apply="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_DELETED_ROLLOUT_BRANCH=1 \
    FAKE_GH_EXISTING_ROLLOUT_PR=1 \
    FAKE_GH_EXISTING_PR_READY=1 \
    FAKE_GH_LOG="$deleted_promoted_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply
)"
jq -e '
  .applied == true and .idempotent == true and
  .commit == "4444444444444444444444444444444444444444" and
  .operations.createBranch == false and
  .operations.draftPullRequest == false and
  .recovery.existingBranchCommit == null and
  any(.specialCases[]; contains("promoted by a human"))
' <<<"$deleted_promoted_apply" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$deleted_promoted_log"; then
  printf 'human-promoted rollout with an auto-deleted branch caused a GitHub write\n' >&2
  exit 1
fi
if grep -Fq $'GET\trepos/Ayyitskevin/ExampleStandard/git/ref/heads/opencode-fleet%2Frollout-' \
   "$deleted_promoted_log"; then
  printf 'human-promoted rollout attempted to require or recreate its deleted branch\n' >&2
  exit 1
fi

pull_lookup_log="$temp_root/pull-lookup-failure.log"
set +e
pull_lookup_plan="$(
  env "${common_env[@]}" "${recovery_env[@]}" \
    FAKE_GH_PULL_LOOKUP_FAILURE=1 \
    FAKE_GH_LOG="$pull_lookup_log" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha"
)"
pull_lookup_status=$?
set -e
[[ "$pull_lookup_status" -ne 0 ]]
jq -e '
  .ready == false and
  any(.blockers[]; contains("pull request state is unavailable"))
' <<<"$pull_lookup_plan" >/dev/null
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$pull_lookup_log"; then
  printf 'failed pull-request lookup did not stop GitHub mutation\n' >&2
  exit 1
fi

# Every successful GitHub mutation is re-read at its exact immutable identity.
# A mismatch stops the remaining publication sequence without a retry.
post_write_cases=(
  'FAKE_GH_CREATED_TREE_MISMATCH|created rollout tree does not exactly match|git/commits'
  'FAKE_GH_REF_RACE|could not be verified at exact commit|/pulls'
  'FAKE_GH_PR_HEAD_MISMATCH|ambiguous response|__none__'
  'FAKE_GH_PERSISTED_PR_MISMATCH|did not persist with the authorized commit|__none__'
)
for post_write_case in "${post_write_cases[@]}"; do
  IFS='|' read -r post_write_flag post_write_error forbidden_post \
    <<<"$post_write_case"
  post_write_log="$temp_root/post-write-${post_write_flag,,}.log"
  set +e
  post_write_output="$(
    env "${common_env[@]}" "${generated_tree_env[@]}" \
      FAKE_GH_LOG="$post_write_log" \
      "$post_write_flag=1" \
      "$fleet_root/scripts/github-rollout" \
      ExampleStandard --central-sha "$central_sha" --apply 2>&1
  )"
  post_write_status=$?
  set -e
  [[ "$post_write_status" -ne 0 ]]
  grep -Fq "$post_write_error" <<<"$post_write_output"
  if [[ "$forbidden_post" != __none__ ]] &&
     grep -F $'POST\t' "$post_write_log" | grep -Fq "$forbidden_post"; then
    printf '%s mismatch continued to forbidden publication stage\n' \
      "$post_write_flag" >&2
    exit 1
  fi
  [[ "$(grep -Fc $'POST\trepos/Ayyitskevin/ExampleStandard/pulls' "$post_write_log")" -le 1 ]]
done

assert_fails env "${common_env[@]}" \
  "$fleet_root/scripts/github-rollout" \
  ExampleStandard,ExampleRestricted --central-sha "$central_sha" --apply

# A default-branch move between planning and apply is detected before the
# first mutation.
advanced_log="$temp_root/default-advanced.log"
set +e
advanced_output="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$advanced_log" \
    FAKE_GH_DEFAULT_ADVANCE=1 \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply 2>&1
)"
advanced_status=$?
set -e
[[ "$advanced_status" -ne 0 ]]
grep -Fq 'default branch advanced after planning' <<<"$advanced_output"
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$advanced_log"; then
  printf 'advanced default branch did not stop GitHub mutation\n' >&2
  exit 1
fi

# Central visibility is mutable repository state. Apply rechecks it after the
# plan and before its first write.
visibility_flip_log="$temp_root/central-visibility-flip.log"
set +e
visibility_flip_output="$(
  env "${common_env[@]}" \
    FAKE_GH_LOG="$visibility_flip_log" \
    FAKE_GH_CENTRAL_VISIBILITY_FLIP=1 \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply 2>&1
)"
visibility_flip_status=$?
set -e
[[ "$visibility_flip_status" -ne 0 ]]
grep -Fq 'central repository became non-public' <<<"$visibility_flip_output"
if grep -Eq '^(POST|PUT|PATCH|DELETE)' "$visibility_flip_log"; then
  printf 'central visibility change did not stop GitHub mutation\n' >&2
  exit 1
fi

# An ambiguous branch response is one-shot and directs the operator into the
# exact-ref preflight on rerun.
ref_failure_log="$temp_root/ref-failure.log"
set +e
ref_failure_output="$(
  env "${common_env[@]}" \
    "${generated_tree_env[@]}" \
    FAKE_GH_LOG="$ref_failure_log" \
    FAKE_GH_REF_FAILURE=1 \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply 2>&1
)"
ref_failure_status=$?
set -e
[[ "$ref_failure_status" -ne 0 ]]
grep -Fq 'could not be verified at exact commit' <<<"$ref_failure_output"
grep -Fq 'preserve external state and rerun the exact preflight' \
  <<<"$ref_failure_output"
[[ "$(grep -Fc $'POST\trepos/Ayyitskevin/ExampleStandard/git/refs' "$ref_failure_log")" == 1 ]]
if grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/pulls' "$ref_failure_log"; then
  printf 'ambiguous branch creation continued to pull-request publication\n' >&2
  exit 1
fi

# --apply is tested only against the fake API. It makes one atomic tree/commit,
# creates one branch, and opens one draft PR for the selected repository.
apply_log="$temp_root/apply.log"
capture_dir="$temp_root/captured"
apply_result="$(
  env "${common_env[@]}" \
    "${generated_tree_env[@]}" \
    FAKE_GH_LOG="$apply_log" \
    FAKE_GH_CAPTURE_DIR="$capture_dir" \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply
)"
jq -e '
  .ready == true and
  .applied == true and
  .idempotent == false and
  .commit == "4444444444444444444444444444444444444444" and
  .pullRequest == "https://github.com/Ayyitskevin/ExampleStandard/pull/99"
' <<<"$apply_result" >/dev/null
grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/git/trees' "$apply_log"
grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/git/commits' "$apply_log"
grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/git/refs' "$apply_log"
grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/pulls' "$apply_log"
if awk -F '\t' '
  $1 != "GET" && $2 !~ /^repos\/Ayyitskevin\/ExampleStandard\// { bad = 1 }
  END { exit bad ? 0 : 1 }
' "$apply_log"; then
  printf 'apply mutated more than the selected consumer repository\n' >&2
  exit 1
fi

tree_capture="$capture_dir/POST_repos_Ayyitskevin_ExampleStandard_git_trees.json"
pr_capture="$capture_dir/POST_repos_Ayyitskevin_ExampleStandard_pulls.json"
jq -e '
  any(.tree[]; .path == ".github/workflows/opencode-review.yml" and .type == "blob") and
  any(.tree[]; .path == ".github/workflows/opencode-build.yml" and .type == "blob") and
  any(.tree[]; .path == ".github/opencode-policy.json" and .type == "blob") and
  any(.tree[]; .path == ".github/workflows/opencode.yml" and .sha == null)
' "$tree_capture" >/dev/null
jq -e '.draft == true and .base == "main"' "$pr_capture" >/dev/null

# A pull-request outage leaves an explicit, recoverable branch instead of
# retrying a non-idempotent POST or hiding the partial external state.
pr_failure_log="$temp_root/pr-failure.log"
set +e
pr_failure_output="$(
  env "${common_env[@]}" \
    "${generated_tree_env[@]}" \
    FAKE_GH_LOG="$pr_failure_log" \
    FAKE_GH_PR_FAILURE=1 \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply 2>&1
)"
pr_failure_status=$?
set -e
[[ "$pr_failure_status" -ne 0 ]]
grep -Fq 'preserve the branch' <<<"$pr_failure_output"
grep -Fq 'docs/FLEET-ROLLOUT.md' <<<"$pr_failure_output"
[[ "$(grep -Fc $'POST\trepos/Ayyitskevin/ExampleStandard/pulls' "$pr_failure_log")" == 1 ]]
grep -Fq $'POST\trepos/Ayyitskevin/ExampleStandard/git/refs' "$pr_failure_log"

invalid_pr_log="$temp_root/invalid-pr-response.log"
set +e
invalid_pr_output="$(
  env "${common_env[@]}" \
    "${generated_tree_env[@]}" \
    FAKE_GH_LOG="$invalid_pr_log" \
    FAKE_GH_INVALID_PR_RESPONSE=1 \
    "$fleet_root/scripts/github-rollout" \
    ExampleStandard --central-sha "$central_sha" --apply 2>&1
)"
invalid_pr_status=$?
set -e
[[ "$invalid_pr_status" -ne 0 ]]
grep -Fq 'ambiguous response' <<<"$invalid_pr_output"
grep -Fq 'rerun the exact preflight' <<<"$invalid_pr_output"
[[ "$(grep -Fc $'POST\trepos/Ayyitskevin/ExampleStandard/pulls' "$invalid_pr_log")" == 1 ]]

if rg -n 'sk-[A-Za-z0-9]|BEGIN [A-Z ]*PRIVATE KEY|OPENCODE_API_KEY' "$capture_dir"; then
  printf 'captured rollout payload contained secret material or a secret binding\n' >&2
  exit 1
fi

printf 'rollout tests passed\n'
