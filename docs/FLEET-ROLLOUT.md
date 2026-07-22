# Fleet rollout

The GitHub rollout is deliberately separate from the local OpenCode fallback.
Local work uses dedicated clones and Ollama. GitHub automation is an optional,
owner-only convenience lane installed through a reviewed draft pull request.

Nothing in this runbook authorizes deployment, migration, default-branch
publication, secret mutation, or environment creation.

## Generated consumer files

Each eligible repository receives:

- `.github/workflows/opencode-review.yml` — exact owner-ID and `OWNER`
  association gate for `/oc review`, `/oc review: ...`, `/oc plan`, and
  `/oc plan: ...`; it calls the central `review.yml` by an exact commit ID.
- `.github/opencode-policy.json` — the closed-schema authority and patch budget.
- `.github/workflows/opencode-build.yml` — standard-risk repositories only;
  owner-only manual dispatch on the repository's live default branch, calling
  the central `build.yml` by an exact commit ID.

The callers do not contain a provider secret binding, OIDC permission, mutable
action reference, installer, model configuration, or sharing control. Those
belong to the pinned central workflows. The central workflows obtain
`OPENCODE_API_KEY` only from their named caller-repository environments.

The old `.github/workflows/opencode.yml` is removed in the same proposed tree.
Review-only rollout also removes a stale generated build caller if one exists.

## Risk policy

The manifest's risk and GitHub-mode pair is authoritative:

| Risk | GitHub mode | Generated authority |
| --- | --- | --- |
| `standard` | `manual-build` | owner comment review plus protected manual draft-PR build |
| `restricted` | `review` | owner comment review only; no patch authority |
| `upstream` | `manual` | no remote caller; local/manual review only |
| `placeholder` | `disabled` | no files or first commit |

Policy JSON permits exactly these keys: `version`, `mode`, `allowed_exact`,
`allowed_prefixes`, `max_files`, and `max_patch_bytes`. Central validation
rejects unknown keys and always-denied paths regardless of consumer policy.
Restricted and upstream policies are `review-only`. Standard policy permits a
bounded draft-PR patch only to `README.md`, `docs/`, and `tests/`, with at most
20 files and 204,800 patch bytes. Source and operational-script work stays in
the local, operator-present lane; the remote convenience lane cannot modify
application, authentication, billing, deployment, or fleet-control code.

## Immutable rendering

Rendering requires a real, lowercase 40-character commit ID; symbolic refs,
short IDs, and the all-zero object ID are rejected.

```bash
sha=<exact-opencode-fleet-commit>
out=$(mktemp -d)
scripts/render-callers \
  --repository mnemosyne \
  --central-sha "$sha" \
  --output "$out"
```

The output directory must be absent or empty. Rendering a placeholder,
disabled repository, or upstream/manual repository fails closed.

That standalone command is an offline rendering aid. The rollout command does
not trust the working tree, an environment manifest override, or local template
edits as authority. It proves that the supplied commit belongs to the fixed
`Ayyitskevin/opencode-fleet` default-branch lineage, fetches the manifest,
caller templates, policy, and reusable workflow files from GitHub at that exact
commit, verifies every decoded Git blob ID, and renders only from that temporary
pinned source root.

The central repository is a public control-plane dependency, not merely a
repository the rollout credential can read. `Ayyitskevin/opencode-fleet` must
remain `PUBLIC`; the REST metadata must say both `visibility: "public"` and
`private: false`. The rollout stops before inspecting or mutating a consumer
when either field is absent, private, or contradictory. This is mandatory
because public consumer repositories can call only public reusable workflows.

## Read-only plan

Planning is the default and performs only GitHub API reads:

```bash
scripts/github-rollout mnemosyne --central-sha "$sha"
```

The JSON result identifies every proposed write and deletion, the rollout
branch, special-case handling, and readiness blockers. A non-ready eligible
repository returns a nonzero exit after printing its plan. Placeholder and
manual-only plans are informational and stop after central lineage and catalog
verification; they never inspect or mutate their consumer repository.

Readiness requires all of the following:

1. Central repository metadata has exact owner login and ID `133295304`, is
   explicitly public (`visibility: "public"`, `private: false`), and the
   supplied central SHA is an exact commit in the live default-branch lineage.
2. The manifest fetched at that SHA has a matching Git blob ID and conforms to
   the fixed `Ayyitskevin` owner and repository schema.
3. Live consumer identity includes exact owner login and ID `133295304`;
   non-empty state and default branch exactly match `config/repos.json`.
4. The default ref resolves to an exact commit and a complete, non-truncated
   tree. Existing callers, rendered-file hashes, and deletions are all derived
   from that one immutable tree snapshot.
5. Every required caller template, policy, and reusable workflow is fetched
   from that exact central commit and verified against its Git blob ID before
   rendering.
6. `opencode-review` exists in the consumer repository and contains the
   environment-scoped secret named `OPENCODE_API_KEY`.
7. Every enrolled repository has a protected default branch requiring at least
   one human approval, stale-review dismissal, last-push approval, enforced
   administrators, and strict status checks whose unique contexts are each
   bound to the GitHub Actions App ID `15368`. User, team, and app pull-request bypass
   allowances are empty, and deletion and force-push are both disabled.
8. A standard/manual-build repository also has:
   - `opencode-build` with its own environment-scoped `OPENCODE_API_KEY`;
   - exactly one required-reviewers rule containing exactly Kevin
     (`Ayyitskevin`, GitHub ID `133295304`) as a `User`;
   - one custom deployment branch policy matching the exact default branch.
9. The deterministic rollout-branch and exact-head/base pull-request lookups
   both succeed. An existing branch is recoverable only when its commit has the
   inspected base as its sole parent and every non-tree leaf exactly matches the
   rendered writes, deletions, modes, types, and object IDs. The pull-request
   lookup runs even when the branch is absent, and any recorded head commit and
   tree must satisfy the same exact plan before prior state is accepted.
10. At least one rendered write or stale-caller deletion is needed. An exact
   no-op exits nonzero and never creates a branch or pull request.

Only secret names are inspected. Secret values are never requested, printed,
stored, copied, or passed to the rollout tooling. Existing repository-level
secrets do not satisfy environment readiness.

## Explicit one-repository apply

After the plan is reviewed and every external environment/secret/branch rule is
configured by a human, apply is explicit:

```bash
scripts/github-rollout mnemosyne --central-sha "$sha" --apply
```

There is no `--all`. The command accepts one catalogue identity and uses the
GitHub Git Data API—not an existing local clone—to:

1. re-read the central repository metadata and stop before mutation if its
   public visibility, owner identity, or default branch changed since planning;
2. re-read the consumer default ref and stop before mutation if it moved since
   planning;
3. create one tree based on the inspected default-branch tree, unless the exact
   deterministic result branch was already reconciled;
4. create one commit whose sole parent is the inspected base commit, unless that
   exact commit was already reconciled;
5. create `opencode-fleet/rollout-<sha-prefix>`, reuse only its exact verified
   result, or deliberately leave an auto-deleted branch absent when its exact
   prior pull request is terminal or was promoted by a human;
6. open one marker-bound draft pull request against the exact default branch,
   create it after a recovered branch-only partial result, or return an exact
   existing draft as idempotent success.

After each mutation, apply re-reads the exact tree, commit, ref, and pull
request and compares the authorized object IDs, sole parent, complete leaf set,
head/base repositories and SHAs, title, body, state, draft flag, number, and
URL. It does not continue to the next mutation when any persisted value differs.

All API mutations occur below a single, marked line in `scripts/github-rollout`
and only after readiness succeeds. Dirty clones and active worktrees are never
read, reset, cleaned, checked out, or modified. A mismatched existing branch or
pull request, unavailable reconciliation lookup, unavailable exact tree, or
advanced default ref stops the command instead of guessing or overwriting state.

GitHub can return an ambiguous response while creating the branch or draft pull
request. Each mutating request is issued once. The command reports the exact
branch and commit and directs the operator to rerun the same command; the next
read-only preflight queries at most one exact-head/base pull request regardless
of whether its branch still exists. It verifies the branch commit when present
and independently verifies a prior pull request's recorded head parent and
complete leaf tree. It then creates only missing state or returns exact state as
idempotent success. A mismatch remains blocked for manual investigation. A
closed or merged exact pull request makes that deterministic rollout terminal.
A pull request promoted from draft by a human is accepted only as read-only
idempotent state. Neither outcome causes an auto-deleted branch or pull request
to be recreated, and automation never demotes or modifies it. Closing a pull
request or deleting the branch is a human action; the rollout tool never
performs either operation.

Review and merge remain human actions. The rollout command never merges the
draft pull request or changes repository settings.

## Fleet special cases

- **Chronos:** the live and manifested default is
  `feat/wheel-dashboard-mvp`. No code path assumes `main`.
- **Focal:** GitHub identity is `Ayyitskevin/Focal`; the redirected local
  `Ayyitskevin/mise` remote is never used.
- **curriculum:** upstream-derived and `manual`; it receives no comment or build
  caller. Local/manual review remains available after a dedicated clone exists.
- **Vulcan:** currently lacks the old caller and provider secret. Its review
  rollout remains blocked until `opencode-review` and its environment secret
  exist.
- **Apollo, Themis, Harmonia, and Prometheus:** empty placeholders remain empty.
- **Minerva:** `main` contains only its empty initialization commit while
  product content remains on an unmerged draft pull request. The rollout
  refuses to create first product content or race that review.
- **opencode-fleet:** publish and verify the central repository first; a consumer
  caller must pin the resulting exact central commit like every other caller.

## Verification and rollback

Run the owned adversarial gate without a real GitHub connection:

```bash
tests/rollout.test.sh
```

The test replaces `gh` with a fixture, proves plan mode issues only GET calls,
and exercises `--apply` solely against that fake API. It also covers a public
central repository plus private, missing, and contradictory central visibility,
hostile local and pinned manifests, unauthorized central lineage, Git blob
mismatch, renderer substitution, exact reviewer drift, inadequate
default-branch review and check protection, app bypass allowances,
missing/truncated tree snapshots, moving default refs, post-write tree/ref/PR
races, failed branch or pull-request lookup, terminal and human-promoted pull
requests with present or auto-deleted branches, exact no-op reruns, ambiguous
one-shot writes, recovered branch-only state, and fully idempotent
branch/pull-request reruns.

To roll back an unmerged rollout, leave the branch intact for audit and close
the draft pull request after human review. To roll back a merged caller, submit
a separate reviewed change that removes or disables the thin caller. Secret,
environment, branch, log, and pull-request deletion is never automated by this
tooling; see [ROLLBACK.md](ROLLBACK.md).
