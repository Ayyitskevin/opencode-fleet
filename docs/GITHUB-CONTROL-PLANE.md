# GitHub control plane

The GitHub integration is deliberately narrower than the local OpenCode fleet. It provides owner-only, read-only review across enrolled repositories and a separately approved path that can produce a bounded draft pull request. It never gives an OpenCode model a GitHub write token and never pushes directly to a default branch.

The files in this repository are a local implementation until the central
repository and consumer callers are intentionally published. No rollout
command should silently enable them. The central
`Ayyitskevin/opencode-fleet` repository must remain public: public consumer
repositories can call only public reusable workflows, and authenticated access
to a private central repository does not satisfy that architecture boundary.

## Trust boundaries

The two reusable workflows have three jobs with distinct credentials:

```text
untrusted event/input
        |
        v
gate: GitHub read token, deterministic authorization
        |
        v
model: provider secret, GitHub contents read-only
        |
        v
publish: GitHub write token, no provider secret
```

The separation is the primary control. Prompt injection can influence model text or proposed edits, but it cannot obtain the publishing token. The publish job accepts only bounded, deterministic output and validates it independently before any write.

Both workflows use GitHub-hosted `ubuntu-24.04` runners. They do not use self-hosted runners, OIDC, `pull_request_target`, `secrets: inherit`, the native `opencode github run` command, or persisted checkout credentials.

## Review workflow

`.github/workflows/review.yml` has no reusable-workflow inputs or caller-supplied secrets. A consumer caller may forward only newly created issue or pull-request review comments matching one of these forms:

- `/oc review`
- `/oc review: <non-empty request>`
- `/oc plan`
- `/oc plan: <non-empty request>`

The central gate does not trust the caller's `if` expression. It checks the repository namespace, owner login, stable owner ID `133295304`, original actor, rerun actor, event sender, comment author, `OWNER` association, exact command grammar, byte bounds, and control characters again. Pull requests must be open and their head and base repositories must both equal the caller repository, so fork code is rejected. The model checkout is pinned to the live pull-request head SHA or live default-branch SHA.

The model job is read-only. Project OpenCode configuration, plugins, external
skills, LSP downloads, external directories, shell, edits, and sharing are
disabled through pure mode, isolated HOME/XDG roots, and explicit environment
switches. Its only outbound credential is the `OPENCODE_API_KEY` exposed by the
`opencode-review` environment. Model output is parsed from bounded JSONL,
stripped of control characters, mention-neutralized, hashed, and passed as
base64 to the publisher. The publisher posts one top-level issue or pull-request
comment with the exact target SHA and workflow-run link.

Both global and agent-level read policies explicitly deny common credential
files at root and nested paths, including environment files, netrc/npm/pypi
credentials, Git credentials, secret JSON/YAML, private keys, and SSH identity
files. Grep and LSP are separately denied at both scopes because those
content-returning tools do not inherit the read tool's path exclusions.
Unknown tools inherit the global deny; the remaining glob/list permissions
enumerate paths without returning file contents.

Publication uses a deterministic execution marker containing the run ID,
authorized target SHA, and command. It deliberately excludes model-response
bytes, so a rerun that produces different wording still finds the already
published execution and cannot duplicate the comment. The response digest
continues to protect cross-job payload integrity. The mutating comment request
is issued once; an ambiguous failure is recovered by rerunning the stable
marker preflight, never by blindly retrying a non-idempotent POST.

## Draft build workflow

`.github/workflows/build.yml` accepts one required string input named `request`. It is intended only for an owner-started `workflow_dispatch` caller on the live default branch.

The gate verifies the stable owner identity, both original and rerun actors, caller repository, default ref, event SHA, and live default-branch SHA. It then fetches `.github/opencode-policy.json` at that exact SHA and validates the policy before a model receives the request.

The model job can read allowed paths, enumerate paths, and edit its isolated
checkout. It cannot use grep, LSP, or another unlisted content-returning tool,
run shell commands, use network tools, load repository OpenCode configuration,
use external directories, or access a GitHub write token. The host makes Git
metadata read-only and hashes its paths, types, modes, ownership, and contents
around model execution. It then reopens only the index and object directories
needed for deterministic staging and proves that HEAD and all other protected
metadata are unchanged. Staged changes outside the repository policy or the
central denylist are rejected.

The only cross-job mutation artifact is a text patch. It is limited to 20 files and 204,800 bytes globally, with repository policy allowed to set lower limits. Job outputs include the patch as base64 plus its SHA-256 digest; no artifact store is used.

The publish job starts from a fresh checkout of the authorized SHA, applies the
patch to the index, and runs a byte-identical validator. It also requires the
regenerated canonical patch digest to equal the model job's digest and rechecks
that the live default branch has not moved. Only then does deterministic code
create `opencode/<run-id>`, push that new branch, and open a draft pull request.
Before either write it checks bounded existing pull requests and the exact
branch. A pre-existing result succeeds only when its tree, sole parent,
run marker, patch digest, head/base identities and SHAs, title, body, state,
draft flag, number, and URL all match. Each branch/commit/pull result is re-read
after mutation before the workflow continues. A closed or merged deterministic
pull request is terminal. A human-promoted non-draft result remains read-only
idempotent state. Branch and pull-request writes are each one-shot; an ambiguous
failure tells the operator to rerun the deterministic preflight. The workflow
never merges, force-pushes, deletes a branch, demotes a pull request, or writes
to the default branch.

## Repository policy

Manual-build repositories carry `.github/opencode-policy.json` with exactly this schema:

```json
{
  "version": 1,
  "mode": "draft-pr",
  "allowed_exact": ["README.md"],
  "allowed_prefixes": ["docs/", "tests/"],
  "max_files": 20,
  "max_patch_bytes": 204800
}
```

The six keys are exact; extension keys fail closed. `allowed_exact` contains relative POSIX file paths. `allowed_prefixes` contains relative POSIX directory prefixes ending in `/`. Absolute paths, backslashes, empty or dot segments, traversal, controls, and oversized entries are rejected. Bounds are integers: `max_files` is 1–20 and `max_patch_bytes` is 1–204800.

The shipped standard policy is intentionally documentation-and-test-only.
Source and operational-script work remains in the operator-present local lane.
Repository allowlists can only narrow the central policy. The central validator
rejects:

- workflow, agent, policy, environment, key, certificate, and submodule files;
- dependency manifests and lockfiles;
- infrastructure, deployment, migration, authentication, billing, payment, clinical, and secret paths;
- paths not explicitly allowed by the repository policy;
- deletions, renames, unmerged entries, mode changes, symlinks, submodules, binary patches, whitespace errors, excess files, and excess bytes.

Restricted or review-only repositories do not receive the manual build caller.
`curriculum` and `Minerva` remain local/manual and must not be enrolled in this
remote mutation path.

## Installation and provenance

Both model jobs install OpenCode `1.18.4` from the exact Linux x64 archive. Installation requires:

- exact archive size `59,265,621` bytes;
- SHA-256 `bab463c3fb3224d388bb7cfad63f38703df9cf0be2cfd2ce8cb49d886b53a174`;
- an archive containing only the `opencode` executable;
- an exact `opencode --version` result of `1.18.4`.

The workflows invoke `opencode --pure run` with the fixed `opencode/claude-sonnet-4-6` model route. Updating either the version, archive digest, size, or model is a reviewed central change; consumers remain pinned to the old central workflow commit until their caller SHA is deliberately advanced.

`actions/checkout` is pinned to commit `d23441a48e516b6c34aea4fa41551a30e30af803` and always uses `persist-credentials: false`.

An exact checksum prevents unnoticed artifact drift but does not prove publisher identity. The upstream release currently has no additional signature verification in this implementation. Treat a version/digest update as a supply-chain review, not a routine autoupdate.

## Required GitHub configuration

For each enrolled consumer repository:

1. Install only the appropriate caller template and replace `__CENTRAL_SHA__` with a reviewed 40-character commit SHA from `Ayyitskevin/opencode-fleet`.
2. Create the `opencode-review` environment for review-enabled repositories and add only `OPENCODE_API_KEY`.
3. For manual-build repositories, also create `opencode-build`, add only `OPENCODE_API_KEY`, restrict it to the default branch, and configure exactly one required-reviewers rule with exactly `Ayyitskevin` (GitHub ID `133295304`) as its sole `User` reviewer. If the owner is the required reviewer, GitHub's prevent-self-review option must remain off or the single-owner flow cannot proceed.
4. Apply default-branch protection. Require at least one human approval, dismiss stale reviews, require approval of the last push, enforce the rules for administrators, and require strict status checks with every unique context bound to the GitHub Actions App ID `15368`. Leave all user, team, and app pull-request bypass allowances empty, and disable force-push and deletion. The rollout readiness gate rejects a nominal protection object that omits any of these controls.
5. Keep Actions permissions at the minimum shown by the caller template. Do not add passed secrets or `secrets: inherit`.

The environment belongs to the consumer workflow run. GitHub does not support passing an `environment` through `on.workflow_call`; the called job's environment secret is used. See GitHub's [reusable workflow documentation](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows) and [deployment environment documentation](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments).

The central reusable workflow repository must be public. Its repository
metadata must report `visibility: "public"` and `private: false`; private,
missing, or contradictory visibility blocks every rollout before consumer
inspection or mutation, even when the authenticated API caller can read the
repository. This is a mandatory personal-account architecture invariant, not
an optional access configuration. Consumers still pin the workflow by full
commit SHA. Apply re-reads this metadata after planning and stops before its
first write if the central repository is no longer explicitly public.

## Cost and operational controls

Review runs cancel an older in-progress review for the same repository. Manual builds are serialized and never triggered by comments. Model jobs have hard 15-minute review and 20-minute build timeouts, 1 MiB JSONL output limits, and small final response or patch limits.

Set a provider-side monthly budget and alert; the workflow cannot enforce account-level spend. If hosted compute becomes too expensive, remove or rotate the environment secret and disable the consumer callers. The local OpenCode fleet remains the primary all-repository fallback and does not depend on these GitHub workflows.

Never put a local Ollama endpoint, Tailscale credential, or long-lived GitHub personal access token in these workflows. Connecting GitHub-hosted runners to the private fleet would expand the trust boundary and is intentionally excluded.

## Verification

Run these before advancing a consumer's central SHA:

```bash
/tmp/icarus-actionlint-1.7.12/actionlint \
  .github/workflows/review.yml \
  .github/workflows/build.yml
bash tests/workflow-security.test.sh
scripts/check
```

`tests/workflow-security.test.sh` extracts the exact inline runtime programs,
syntax-checks them, compares duplicated installer and validator blocks
byte-for-byte, exercises valid owner events, and attacks actor, association,
rerun, command, fork, ref, SHA, policy, path, deletion, binary, dependency,
allowlist, Git-metadata, staging, ambiguous-publication, and rerun-idempotency
boundaries. Its offline OpenCode fixture verifies the host's exact
`--pure run` invocation, isolated runtime roots, disable switches, and
read-only Git-metadata barrier without calling a provider. It does not prove
the upstream CLI's internal isolation semantics.

No test calls the provider or writes to GitHub. A live pilot is a separate, human-approved rollout step. Start with one low-risk review-only repository, observe output and spend, then pilot one documentation-only draft build before wider enrollment.

## Disable and rollback

The fastest kill switch is to disable the consumer caller or remove the relevant environment secret. That preserves the local fleet and central source for inspection while preventing new model jobs.

To roll back central behavior, change consumer callers to the last reviewed central commit SHA. Existing runs continue with the workflow commit they were pinned to. If a draft build partially publishes, close the draft pull request and delete its stable `opencode/<run-id>` branch manually after review; the workflow never performs deletion itself.
