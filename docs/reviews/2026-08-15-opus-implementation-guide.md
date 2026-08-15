# Implementation guide — 2026-08-15 review remediation

Companion to [2026-08-15-review.md](2026-08-15-review.md). This document
specifies every proposed change precisely enough to implement without the
review conversation. Line references are against commit `89ce639`.

## Ground rules for the implementing session

1. Read `AGENTS.md` and `docs/DECISIONS.md` before touching anything. Every
   change below either conforms to the doctrine or names the decision it
   amends. Do not bend doctrine silently.
2. Bash + `jq` only. No new runtime dependencies.
3. Every behavioral change lands with a test in the same commit, and the test
   must be able to fail: after writing it, temporarily revert the fix and
   confirm the test goes red, then restore.
4. Run `scripts/check` as a **non-root** user in an environment with
   `GIT_CONFIG_*` unset (until T1 lands, the suite is not hermetic).
5. Update `README.md` / `docs/` in the same commit as any contract change.
6. One concern per commit. Phases are ordered; within a phase, items are
   independent unless noted.
7. Phase 3 items marked **[needs owner approval]** amend doctrine. Do not
   implement them until Kevin has approved the corresponding decision-register
   amendment; implement the rest of the phase around them.

---

## Phase 0 — contract-breaking bugs

### C1. Fix rollout ancestor-SHA authorization (and the fixture that hid it)

**Files:** `scripts/github-rollout` (`central_lineage_is_authorized`, ~:86-94),
`tests/fixtures/fake-gh-rollout`, `tests/rollout.test.sh`.

**Problem:** The `ahead` branch of lineage authorization requires
`.head_commit.sha == $head`, but GitHub's compare endpoint
(`GET /repos/{owner}/{repo}/compare/{basehead}`) has no `head_commit`
property. `jq` evaluates it to `null`, so every true-ancestor
`--central-sha` is rejected; only `status == "identical"` (exact live head)
ever authorizes. The fixture fabricates `head_commit`, so the suite passes
against a phantom contract. Commit `89ce639` treated the symptom.

**Change:** Authorize the ancestor case from fields the API actually returns:
`.status == "ahead"`, `.merge_base_commit.sha == $base` (the candidate SHA),
and take head identity from the live ref read the script already performs
immediately before the compare (`central_head`) rather than from the compare
body. Keep `identical` handling. Update `tests/fixtures/fake-gh-rollout` to
emit the real `commit-comparison` shape — `status`, `ahead_by`, `behind_by`,
`merge_base_commit`, `base_commit`, `commits`, `total_commits` — with **no**
`head_commit` key.

**Acceptance:** New rollout test cases: (a) ancestor SHA in default-branch
lineage plans successfully; (b) non-ancestor SHA (status `diverged` /
`behind`) is rejected; (c) a fixture emitting `head_commit` is grounds for
test failure (assert the fixture output shape once, so drift back is caught).
Existing 41 cases stay green.

### C2. Run-record lifecycle: traps in `scripts/oc`

**Files:** `scripts/oc`, `tests/launcher.test.sh`.

**Problem:** `scripts/oc` has no traps. Ctrl-C/SIGTERM/SIGHUP during the
model run (`:816`) skips the epilogue (`:817-825`), leaving `record.json`
permanently `active`/`provisioning` with no `exitCode`/`endedAt`. A die
between run-dir creation (`:641`) and record creation (`:659`) leaves a
recordless run directory. The installers already follow D9 with EXIT-trap
reconciliation; the launcher is the outlier.

**Change:** After the record is first written, install `trap` handlers: INT
and TERM re-raise through an EXIT handler that, when the script is dying
before the normal epilogue ran, writes status `interrupted` with `endedAt`
(reuse `write_run_record`; add the status value to any doc that enumerates
statuses). Create the record (status `provisioning`) *before* the
worktree-collision and branch-validity dies so no run dir exists without a
record; use the same `mktemp`+`mv` atomic pattern as `write_run_record` for
initial creation. Do not trap before the lock — a pre-lock die has no state
to reconcile.

**Acceptance:** New launcher test: start a run against the fake model, SIGTERM
the launcher process group mid-run, assert the record ends `interrupted` with
`endedAt` set, the lock is immediately reacquirable, and a subsequent run
succeeds with a fresh ID. Second case: force the worktree-collision die and
assert the run dir contains a record.

### C3. Fail-closed clean-tree gate

**Files:** `scripts/oc:566-568`, `tests/launcher.test.sh`.

**Problem:** `[[ -z "$(git ... status --porcelain=v1 ...)" ]] || dirty=true`
discards git's exit status: an erroring `git status` (corrupt index,
permissions) yields empty output and `dirty=false` — build proceeds exactly
when git cannot vouch for cleanliness.

**Change:** Capture output and status separately; die
`"cannot determine clone cleanliness"` on nonzero status, then test the
captured output.

**Acceptance:** Test with a clone whose `.git/index` is made unreadable (or a
`git` shim forced to fail `status`): build refuses with the new message.

### C4. Pin the credential deny tables by content

**Files:** `scripts/oc` (`validate_runtime_guard` ~:100-189,
`validate_staged_config` ~:191-283), `scripts/doctor`, `scripts/install-local`
(policy gate ~:155-239), `tests/launcher.test.sh`.

**Problem:** Validators check the read/bash tables structurally (first entry,
"rest are deny", last bash key). A read table reduced to `{"*": "allow"}`
passes; removing 20 credential deny keys from the guard passes. The gates
promise "strict semantic validation" and deliver shape validation.

**Change:** Compare the full `permission.read` and `permission.bash` objects
against canonical literals, exactly as `validate_routes` already does for
routes. Single source of truth: add the canonical tables once (see H1's
shared-contract mechanism; if H1 is done first, put them there), so the
staged config, guard, doctor, and install-local validate the same literal.
The staged config's read/bash tables and the guard's are intentionally
identical today — assert that equality rather than maintaining two literals.

**Acceptance:** Mutation tests: delete one credential deny key from the
staged config → launcher refuses; same for the guard; same via doctor
(`--strict` fails) and install-local. Assert the specific die message (see
T6).

---

## Phase 1 — make the acceptance gate honest

### T1. Hermetic git environment for the whole suite

**Files:** all five `tests/*.test.sh` (shared preamble), `scripts/check`.

**Problem:** Reproduced: ambient `GIT_CONFIG_*` (insteadOf rewrites) breaks
`tests/local-lane.test.sh:87`; a user gitconfig with `commit.gpgsign` breaks
test commits. The product scrubs git config for children; the tests don't
scrub themselves.

**Change:** In each test preamble (or a sourced `tests/lib.sh` if you prefer —
keep it tiny): `unset "${!GIT_CONFIG@}"`, export `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, and set
`commit.gpgsign=false` in per-repo config where commits are made. Also
replace the environment-sensitive `git remote get-url origin` assertion at
`local-lane.test.sh:86` with `git config --get remote.origin.url` (raw value,
no insteadOf application — the launcher itself reads the raw key).

**Acceptance:** Suite passes with hostile ambient config exported
(`GIT_CONFIG_COUNT=1` insteadOf rewrite plus a gpgsign gitconfig), and still
passes clean.

### T2. Root fail-fast for the gate

**Files:** `scripts/check`.

**Change:** First statement after `set -euo pipefail`:
`[[ "$(id -u)" -ne 0 ]] || die`-equivalent with message
`check: run the acceptance gate as a non-root user (scripts/oc refuses root)`.

**Acceptance:** As root, `scripts/check` exits 1 immediately with that
message instead of dying mid-suite.

### T3. Glob-based gate inventory

**Files:** `scripts/check`.

**Problem:** Hardcoded inventory; new scripts/tests silently escape
`bash -n` and execution.

**Change:** Glob `scripts/*`, `scripts/github-runtime/*.sh`,
`tests/*.test.sh`, `tests/fixtures/*` for `bash -n` (skip non-bash files by
shebang/extension check, fail on unrecognized executables rather than
skipping silently); execute every `tests/*.test.sh` found. Keep launcher →
local-lane → workflow-security → rollout ordering by sorting or explicit
ordering of known suites followed by any new ones.

**Acceptance:** Drop a `tests/zz-canary.test.sh` containing `exit 1` into the
tree → gate fails; remove it → green.

### T4. Cloud-lane credential contract pinned

**Files:** `tests/launcher.test.sh` (~:458), `scripts/oc` (see H3 decision).

**Change:** Extend the cloud-run jq assertion to the full contract the
local-lane block already pins: `githubToken == ""`, `sshAgent == ""`, plus an
explicit assertion for each other provider key. Which way those assert
depends on H3 (cloud sanitization): if H3 lands, assert scrubbed; if Kevin
declines H3, assert current passthrough with a comment citing D8 so any
future change is a visible, intentional test edit.

**Acceptance:** Temporarily remove `-u GITHUB_TOKEN` from the shared env
block → suite goes red.

### T5. Extraction guards in workflow-security tests

**Files:** `tests/workflow-security.test.sh` (~:61-99).

**Problem:** Reproduced: awk job-slicing anchored on `^  model:` /
`^  publish:` yields an empty file after a rename and the D3 negative greps
pass vacuously; `post_has_retry` matches one exact curl formatting and
"passes" when it matches nothing.

**Change:** After each slice, assert non-empty and containing a sentinel
(`runs-on:`). In `post_has_retry`, count matched POST blocks and fail the
test if zero were seen.

**Acceptance:** Rename `model:` → `run-model:` in a scratch copy of the
workflow → test now fails loudly instead of passing.

### T6. Launcher negative tests assert the refusal reason

**Files:** `tests/launcher.test.sh` (~:199-304).

**Change:** Capture stderr per negative case and grep the specific `oc:` die
message that mutation should trigger (the launcher already emits distinct
messages). Follow the discipline `tests/rollout.test.sh` already uses.

**Acceptance:** Spot-check by breaking one validator's message string —
the corresponding case fails for the right reason.

### T7. Lock-contention and rollback-refusal coverage

**Files:** `tests/local-lane.test.sh`.

**Change:** (a) Holding `session.lock` via flock, assert
`rollback run --apply` and `sync-clones --apply` refuse (mirroring the
existing oc/installer contention cases). (b) Three rollback cases: staged
changes captured into non-empty `staged.patch` and restored clean; committed
run branch → refusal `refuses committed changes`, worktree untouched;
branch renamed → branch-mismatch refusal.

### T8. Interruption coverage

**Files:** `tests/launcher.test.sh`, `tests/local-lane.test.sh`.

**Change:** The C2 acceptance test covers launcher interruption. Add the
installer half: `kill -9` between prepared-record write and first target
replacement (add a testing-mode sleep/stop hook analogous to the existing
`OPENCODE_FLEET_TEST_FAIL_*` hooks), then assert the durable `prepared`
record is present, doctor flags it, and `rollback install --apply` recovers.

---

## Phase 2 — hardening and consistency

### H1. Shared validation contract for oc and doctor

**Files:** new `scripts/lib/` (or `config/contracts/*.jq`), `scripts/oc`,
`scripts/doctor`.

**Problem:** Doctor's guard/config checks are a diverging subset of the
launcher's → false-healthy reports. Two hand-maintained copies of 90-line jq
programs cannot stay identical.

**Change:** Extract the guard/config/routes/manifest jq contracts into files
(e.g. `scripts/lib/validate-guard.jq`) read by both `oc` and `doctor` via
`jq -f`. Also reorder doctor's CLI check: digest comparison before
`"$opencode_bin" --version` execution.

**Acceptance:** A guard mutation that oc rejects is also flagged by
`doctor --strict` (add one shared mutation case exercising both).
`scripts/check` stays green.

### H2. Model-child environment: allowlist instead of denylist

**Files:** `scripts/oc` (~:708-816), `tests/launcher.test.sh`.

**Problem:** The sanitizer denylist is fail-open and already missing
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, and newer providers' keys.

**Change:** Invert: launch the child with `env -i` plus an explicit keep-list
— `PATH`, `TERM`, `LANG`/`LC_*`, `USER`, `LOGNAME`, `SHELL`, plus every
variable the script already sets explicitly (`HOME`, `XDG_*`, `OPENCODE_*`,
`GIT_*`, ...). Delete the 44-entry denylist. In `--cloud` mode, additionally
pass through only the provider variables mapped to the allowlisted provider
via an explicit provider→env-var table that fails closed on unknown providers
(this is H3; land them together).

**Acceptance:** Local-lane env test extended: set a fake
`SOME_FUTURE_PROVIDER_API_KEY` in the parent → absent from the child.
Existing seven credential assertions stay green.

### H3. Cloud lane passes through only the requested provider's credentials **[needs owner approval — contract choice]**

**Files:** `scripts/oc`, `tests/launcher.test.sh`, `README.md`, D8 wording.

**Problem:** In `--cloud` mode no provider sanitizers are applied, so every
provider's credentials reach the child; only `enabled_providers` narrowing
remains. README's "enables only the provider named by the allowlisted model
and preserves its provider environment for that one run" is ambiguous about
the others.

**Change (recommended):** With H2's allowlist in place, `--cloud` passes
through only the requested provider's variables (table: `anthropic` →
`ANTHROPIC_API_KEY`; `openai` → `OPENAI_API_KEY`, `OPENAI_ORG_ID`,
`OPENAI_PROJECT`; extend as providers are actually allowlisted — unknown
provider = die). Tighten the README sentence to match. If Kevin prefers the
current behavior, skip the oc change and pin it in tests instead (T4's else
branch).

### H4. Dispatch help/doctor before policy validation

**Files:** `scripts/oc` (~:448-478), `tests/launcher.test.sh`.

**Change:** Move the `""|-h|--help|help` and `doctor` dispatch above the
five `validate_*` calls (doctor performs its own diagnostics; that is its
job). Keep full validation for `list` and repository launches.

**Acceptance:** With a malformed `runtime-guard.json`, `oc doctor` runs and
diagnoses it; `oc <repo>` still refuses.

### H5. Gate all `OPENCODE_FLEET_*` overrides as test-only

**Files:** `scripts/oc` (~:612-616), `scripts/doctor`, `scripts/rollback`,
`scripts/sync-clones`, tests.

**Problem:** `STATE_ROOT`/`MANIFEST`/`WORKSPACE_ROOT`/`CONFIG`/`GUARD`/
`ROUTES` are honored unconditionally; a stray `OPENCODE_FLEET_STATE_ROOT`
silently splits the global session lock.

**Change:** Extend the existing test-only gate to every `OPENCODE_FLEET_*`
override in all scripts that honor them (the tests already set
`OPENCODE_FLEET_TESTING=1`).

**Acceptance:** Without `OPENCODE_FLEET_TESTING=1`, setting
`OPENCODE_FLEET_STATE_ROOT` makes each script die with the test-only
message.

### H6. Installers refuse to bury a `prepared` transaction

**Files:** `scripts/install-local`, `scripts/install-opencode-cli`,
`tests/local-lane.test.sh`.

**Change:** Before backing up an existing install record, parse it; if
`.status == "prepared"`, die directing the operator to
`scripts/rollback install|cli` (ROLLBACK.md already tells humans this — make
the tool enforce it). No override flag: recovery-first is the doctrine.

### H7. Verify-then-use anchoring in installers and rollback

**Files:** `scripts/install-opencode-cli`, `scripts/install-local`,
`scripts/rollback`.

**Change:** (a) CLI installer: under the lock, copy the archive into the
mode-700 staging dir, re-verify SHA-256 against the pin, and run both tar
reads against that verified copy. (b) install-local: hash the source config
at validation time; compare the staged temp copy against that captured hash.
(c) rollback: re-run the git preconditions (HEAD == baseCommit, branch ==
runBranch, common-dir) after acquiring the lock; re-read and content-compare
the install record post-lock (hash captured pre-lock). (d) Reconcile
handlers relocate staged temporaries (`config_temporary`,
`launcher_temporary`, `binary_temporary`, extract dir) into the transaction
backup root instead of littering live directories.

**Acceptance:** Extend the existing fault-injection tests: post-lock record
swap → refusal; failed transaction leaves no stray dotfiles in the scratch
home (assert by listing).

### H8. Rollout robustness trio

**Files:** `scripts/github-rollout`, `tests/rollout.test.sh`,
`tests/fixtures/fake-gh-rollout`.

**Change:** (a) Write detection selects tree entries by `.path` and compares
the full `(mode, type, sha)` triple against `("100644", "blob",
rendered_blob)` so mode-only drift plans as a write. (b) Drop the
`size > 0` heuristic; the ref/commit/tree fetches are the authoritative
emptiness gate. (c) Add explicit `per_page=100` to the environment-secrets
and matching-refs reads and fail closed if a full page comes back.

### H9. Workflow validator and central-authority fixes

**Files:** `.github/workflows/build.yml` (both duplicated validator copies),
`templates/callers/*.tpl` if affected, `tests/workflow-security.test.sh`.

**Change:** (a) `safe_changed_path()`: reject any path containing NL/CR/TAB
before splitting (`read` stops at the first newline, so the per-segment
checks are dead beyond it). Apply to model-side and publish-side copies —
the byte-identical-blocks test keeps them in lockstep. (b) Enforce D7
centrally: validate the fetched consumer policy's `allowed_exact` ==
`["README.md"]` and `allowed_prefixes` == `["docs/", "tests/"]` for the
standard risk class (Git-blob comparison against the shipped template is
acceptable), so a consumer policy edit cannot widen remote authority beyond
what DECISIONS.md D7 promises.

**Acceptance:** New workflow-security cases: newline-embedded staged path
rejected; widened consumer policy rejected by the gate.

### H10. Config/docs truth reconciliation

**Files:** `config/opencode.jsonc`, `config/runtime-guard.json`,
`config/versions.json`, both workflow configs, `scripts/check` or
`tests/workflow-security.test.sh`, `README.md`, `scripts/oc`.

**Change:** (a) Extend the shared credential deny table everywhere it is
duplicated with: `.envrc`, `id_ecdsa`, `id_dsa`, `id_ecdsa_sk`,
`id_ed25519_sk`, `*.p12`, `*.pfx`, `*.ppk`, `secrets.toml` (root + `**/`
forms). C4's content pinning then locks the extended list. (b) Add deny
spellings for the README's claims: `rm -fr*`, `*/rm -rf*`, `*/rm -fr*`,
`*/sudo *`, `git * reset --hard*`, `git * clean*` — or, where a pattern
family can't be closed, soften the README sentence to "deny-listed
best-effort; everything else requires an operator prompt". (c) Add a test
that greps the three workflows' `uses:` checkout SHAs and installer
version/sha256/size constants and compares them to `config/versions.json`;
extend `validate_versions` to require the `actionsCheckout` shape.
(d) Model catalog labels: drop or align the role suffixes ("planning",
"heavy", "ceiling", "work vision") with reality — pair with R1 below, which
is what actually makes those models reachable. (e) Remove the machine-local
`/tmp/icarus-actionlint-1.7.12` path from GITHUB-CONTROL-PLANE.md; reference
an actionlint version instead.

---

## Phase 3 — the practice lane (owner's local-model goal)

Ordering: R1 → R2 → R4 → R5 → R6 first (small-to-medium, high daily value),
then R3, then R7/R8 which build on R1/R3.

### R1. Sanctioned local model selection: `--model` + `localExperiments` allowlist **[needs owner approval — amends D8]**

**Files:** `config/model-routes.json`, `scripts/oc`, `scripts/doctor`,
`tests/launcher.test.sh`, `README.md`, `docs/DECISIONS.md`, `AGENTS.md`.

**Problem:** 9 of 11 staged Ollama models are unreachable: routes pin two
models, the cloud allowlist regex rejects `ollama/*`, and D8 calls alternate
local models "configuration errors". The owner's stated goal is daily
practice **with these models**.

**Change:** Add `"localExperiments": []` to `config/model-routes.json` —
exact `ollama/<model>` strings, each required by validation to exist in the
staged provider catalog, deduplicated, non-overlapping with the pinned
routes. Add `--experiment <ollama/model>` (long, explicit name preferred
over `--model` to keep the daily path deterministic) to `oc`, mutually
exclusive with `--ceiling`/`--cloud`, valid only for entries in
`localExperiments`; never an environment override; recorded in the run
record (`costClass: "local-experiment"`). Validation stays fail-closed:
empty allowlist ships as default, exactly like the cloud lane.

**Doctrine:** Amend D8 with a new paragraph (or D12): local experimentation
is a first-class, allowlisted, CLI-explicit escalation on the loopback
provider only; provider closure, loopback URL, no-fallback, and
no-env-override invariants unchanged.

**Acceptance:** `--experiment` with an unlisted model refuses; with a listed
model, dry-run JSON and the run record show the model and cost class; env
var cannot select it; `--experiment` + `--cloud` refuses.

### R2. Run-history tooling: `oc runs`, `oc show`, `oc diff` + documented promotion

**Files:** `scripts/oc`, `docs/ROLLBACK.md`, `README.md`,
`tests/local-lane.test.sh`.

**Problem:** Run records and preserved worktrees are write-only; ROLLBACK.md
tells the owner to read record paths by hand; how a good build travels from
the private worktree to origin is undocumented (push is denied in-session by
design, so promotion is necessarily a human step — currently an unassisted
one).

**Change:** Three read-only subcommands over lane-owned state: `oc runs
[repo]` (table: run ID, repo, mode, model, status, created, diffstat when
present), `oc show <run-id>` (pretty-print record), `oc diff <run-id>`
(`git -C <worktree> diff <baseCommit>` pass-through; refuse when the
worktree is gone). Document the manual promotion recipe in ROLLBACK.md (or a
new short doc): review with `oc diff`, then from the *dedicated clone* fetch
the run branch from the worktree and push it deliberately. **Do not**
implement an `oc promote` push command in this pass — it is the one item
that crosses "no fleet script ever pushes"; leave it to a future explicit
decision if the manual recipe proves tiresome.

**Acceptance:** Subcommands work against fixture state; all three are
read-only (no mutation of records/worktrees — assert mtimes/digests
unchanged); missing-run and missing-worktree paths refuse cleanly.

### R3. Sandbox lane: `oc sandbox` for throwaway practice **[needs owner approval — amends the one-catalogued-repo invariant]**

**Files:** `scripts/oc`, `tests/launcher.test.sh`, `tests/local-lane.test.sh`,
`README.md`, `docs/DECISIONS.md`, `AGENTS.md`.

**Problem:** Practice requires a real catalogued GitHub repository —
`oc` dies "repository is not catalogued" and clone validation demands a
matching GitHub origin. Daily-practice friction pushes the owner back to
other tools, defeating the goal.

**Change:** `oc sandbox new [name]` creates a git-init'd, remote-less
repository under `$state_root/sandboxes/<name>` (mode 700, via the existing
`ensure_private_directory` chain; name validated like run IDs);
`oc sandbox list`; `oc sandbox <name> [plan|build|review]` runs the normal
lanes against it. Sandboxes carry strictly less authority than catalogued
clones: no origin (validation asserts **zero** remotes instead of one exact
origin), nothing to push to, same guard, same lock, same run records
(record gains `"sandbox": true`). Build mode may run in-place (worktree
optional) since there is no clone to protect — decide one way and test it.
No automated deletion; document manual cleanup, consistent with the
retention doctrine.

**Doctrine:** New decision (D12/D13): the one-catalogued-repository
invariant exists to prevent authority widening over real repositories and
credentials; a remote-less scratch repo inside the private state root widens
where a model may write while granting strictly less authority than any
catalogued clone.

**Acceptance:** Sandbox sessions launch without any manifest entry; a
sandbox with a remote configured refuses; catalogued-repo behavior
unchanged; lock contention covers sandbox runs.

### R4. `doctor --local-models` + QUICKSTART

**Files:** `scripts/doctor`, `docs/QUICKSTART.md`, `README.md`.

**Problem:** Doctor validates everything except the one dependency practice
actually needs: a running Ollama with the routed models pulled. First-session
failures surface as opaque CLI errors.

**Change:** Opt-in flag `--local-models`: GET
`http://127.0.0.1:11434/v1/models` (the exact pinned loopback base URL;
loopback only, read-only, never part of the launch path or default doctor),
verify every model referenced by routes, ceiling, and `localExperiments` is
present; warn normally, fail under `--strict`. Fail closed with a clear
message when the daemon is unreachable. Add `docs/QUICKSTART.md`: the
shortest path from clone → installers → sync-clones → doctor → first
session, cross-linked from README (README stays authoritative).

### R5. Practice feedback loop: run metrics, `oc note`, `oc stats`

**Files:** `scripts/oc`, `scripts/rollback` (record validation),
`tests/local-lane.test.sh`, `README.md`.

**Change:** (a) At run end, add `durationSeconds` and, for build runs, a
diffstat (`files`/`insertions`/`deletions` vs `baseCommit`) to the record —
additive optional fields; keep `schemaVersion: 1` and teach rollback's
validation to tolerate the new keys. (b) `oc note <run-id> <text>` appends a
timestamped note into the record (jq-encoded, never shell-interpolated).
(c) `oc stats [--model | --repo]` aggregates records: runs, completion rate,
mean duration, mean diffstat per model — the memory that makes model
practice compound.

### R6. Bash completion for `oc`

**Files:** `scripts/oc-completion.bash`, `scripts/install-local`, `README.md`.

**Change:** Complete repository names from `config/repos.json`, subcommands
(`list`, `doctor`, plus R2/R3 additions as they land), modes, flags, and run
IDs from `$state_root/runs/` for run-taking subcommands. Install as an
additional preview+apply target through install-local's existing transaction
machinery. Bash only.

### R7. `oc resume <run-id>` — deferred, experimental

Re-enter an existing run's runtime home and worktree with the identical
sanitized environment. **Blocked on one manual verification**: that pinned
OpenCode 1.18.4 session-continue semantics behave under `--pure` with an
injected HOME. Requires a `resumed` status and a rollback interaction rule
(rollback already refuses when HEAD moved; a resumed build with commits is
covered by that check — state it in the docs). Do not build until the manual
check passes; if it does, the implementation is doctrine-clean (same
authority, same lock, fail-closed on any record/worktree/CLI mismatch).

### R8. `oc compare` — build last, after R1 (and ideally R3)

One task, N allowlisted local models, sequential runs (the global lock
already serializes), one run record/worktree each, then a comparison table
(status, duration, diffstat, worktree paths) reviewed via `oc diff`.
Requires a non-interactive invocation shape (`opencode run` with a prompt
file) — new surface needing its own tests; keep interactive default, make
compare opt-in, hard-reject `--cloud`. Sandbox-first delivery is acceptable.

---

## Suggested commit sequence

1. C1, C2, C3, C4 (one commit each)
2. T1–T8 (T1 first; T4 after the H3 decision)
3. H1–H10 (H2+H3 together; H4/H5 trivial; H6–H8 independent)
4. R1 (after approval) → R2 → R4 → R5 → R6 → R3 (after approval) → R7/R8

After each phase: `scripts/check` green as non-root, and for Phase 2+ run
`actionlint` on the three workflows.
