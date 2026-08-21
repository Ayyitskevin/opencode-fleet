# Decision register

## D1 — Local execution is the cost fallback

OpenCode launches inside one dedicated clone at a time and uses local Ollama by
default. Paid providers are an explicit command-line escalation and never an
automatic fallback.

## D2 — GitHub automation is a separate authority plane

Remote review and remote build are distinct reusable workflows. Public comments
cannot request build authority. Mutating runs are manual, protected, and produce
only a bounded patch, branch, and draft pull request. The central reusable
workflow repository remains public because public consumers cannot call a
private central workflow; authenticated API readability is not an equivalent
substitute, and rollout rejects it.

## D3 — Provider credentials and GitHub write credentials never share a job

The model job receives the provider credential and no GitHub token. A later,
deterministic publisher receives a bounded artifact and the minimum GitHub token,
but no provider credential.

## D4 — Native `opencode github run` is not the fleet boundary

Pinned OpenCode 1.18.4 can bypass OIDC with `USE_GITHUB_TOKEN`, but its native
handler still has broad build behavior, can change branches, and creates
non-draft pull requests. The fleet uses `opencode --pure run` with host-owned
validation and publication instead.

## D5 — Empty repositories remain empty

Placeholders are recorded in the manifest and onboard automatically when they
receive their first intentional commit. Automation does not fabricate content to
claim coverage.

## D6 — Rollout plans belong to one immutable repository tree

The rollout first proves the requested central commit belongs to the fixed
central repository's live default-branch lineage. It fetches and Git-blob
verifies every manifest/template/policy/workflow input at that SHA, then derives
consumer files, content identities, deletions, and its base from one exact,
non-truncated consumer Git tree. Local dirty files and environment manifest
overrides are not rollout authority. Apply rechecks mutable refs before its
first write. A moved ref, unavailable branch lookup, or exact no-op fails closed
instead of creating ambiguous external state. Mutating branch and pull-request
requests are one-shot; every result is re-read and a rerun may reuse external
state only after verifying the exact parent, complete leaf tree, ref, head/base
identities and SHAs, title, body, state, draft flag, number, and URL.

## D7 — Remote build authority is documentation-and-test-only

The operator-present local lane can work throughout a catalogued repository.
The optional remote draft-PR lane is limited to `README.md`, `docs/`, and
`tests/`; application, security, money, deployment, and fleet-control code is
outside its policy even in standard-risk repositories.

## D8 — Local means one exact loopback provider

The normal cost fallback contains only the Ollama provider, the pinned
OpenAI-compatible adapter, the host-local loopback URL, and an exact
`enabled_providers: ["ollama"]` gate. Plan, build, and review pin
`qwen3.8:27b`; there is no approved ceiling route. Host profiles pin the exact
Muse simple/vision tag and Ornith fast-code tag available on Mickey and Flow.
Ordinary local execution removes common paid-provider credentials from the
child environment. The explicit allowlisted cloud lane enables only its
requested provider for that run. Remote-compatible base URLs, extra providers,
and implicit fallback are configuration errors rather than routing choices.

## D9 — Install intent is durable before target mutation

Local config and CLI installers persist and sync a `prepared` transaction
record before replacing a target. Success atomically advances it to
`installed`; trapped failure restores the previous targets and record while
preserving failed state. A power loss therefore leaves a recoverable prepared
record instead of an unrecorded partial install. Both installers acquire the
shared non-blocking session lock before any config, launcher, binary, install
record, or backup mutation, so they cannot race a session, sync, rollback, or
one another.

## D10 — Idempotency keys describe execution, not model wording

Review comments use run ID, target SHA, and command as their stable execution
identity; response bytes are integrity-checked separately. Build branches use
only the run ID and exact patch digest in their pull marker. Closed build or
rollout pull requests are terminal, while a human-promoted pull request remains
read-only. Automation does not duplicate, reopen, demote, or overwrite these
states.

## D11 — Read denial owns every content-returning path

Credential paths are denied for the read tool at root and nested locations.
Grep and LSP are separately denied because their permission checks do not
reapply those read-path exclusions and can return repository content. The
remaining allowed enumeration tools return paths, not file contents; unknown
tools inherit the fail-closed default.

## D12 — Practising with another local model is an allowlisted escalation

D8 originally treated any model other than the pinned routes as a configuration
error. That kept the daily lane deterministic but left the staged provider
catalog unreachable, so deliberate practice with a different local model had no
sanctioned path at all and the only way to try one was to edit the route table
and defeat strict validation.

`--experiment ollama/ornith-1.5:35b` is that path: an explicit command-line
request checked against the exact direct-only allowlist, required to exist in
the staged provider catalog, forbidden from shadowing the Qwen daily route, and
mutually exclusive with the other escalations.

D8's actual invariants are unchanged: only the Ollama provider, only the local
loopback URL, `enabled_providers` exactly `["ollama"]`, no environment model
override, and no fallback. What is amended is only the claim that all alternate
local models are errors: the verified Ornith tag has one explicit, auditable
fast-code path.

## D13 — A record that outlives its process must not lie

Installers reconcile their transaction records through traps (D9), but the
launcher did not, so an ordinary Ctrl-C left a run record permanently claiming
to be `active` with no exit code or end time. Records are durable evidence, and
evidence that is wrong is worse than evidence that is missing.

Every run now finalizes its own record on any exit: `completed` or `failed`
from the model's status, `interrupted` with the signal when a session is
signalled, `aborted` when the launcher dies between provisioning and execution.
The record is created before any provisioning failure can occur, so a run
directory never exists without one.

## D14 — Run evidence is readable, and publication stays human

Run records and preserved build worktrees were write-only. `oc runs`, `oc show`,
`oc diff`, `oc stats`, and `oc note` make that evidence usable — all read-only
over lane-owned private state except the note append, none of them starting a
run, touching a catalogued clone, or gaining any authority the launcher did not
already have.

Promotion is deliberately not automated. No fleet script pushes anywhere; a
finished run branch is reviewed with `oc diff` and published by the operator by
hand. That boundary is the point, not an omission.

## D15 — Policy contracts are pinned by content, not by shape

The credential read table and the shell deny tables were validated
structurally: the first entry allows, every later entry denies, the last bash
entry is the push catch-all. That is vacuously true of a table with no
credential entries left in it, so silently deleting most credential denials
passed every gate.

`scripts/lib/fleet-contracts.sh` holds those tables once, by exact content and
exact order, and the launcher, doctor, and installer all assert against it.
Order is part of the contract because OpenCode resolves permissions by pattern
order. Diagnosis now accepts exactly what the launcher accepts, so doctor can
no longer report a healthy fleet that `oc` refuses to run.

## D16 — A sandbox is less authority, not more

AGENTS.md says local execution opens exactly one catalogued repository at a
time. That invariant exists to stop a model reaching Kevin's real repositories
and credentials — not to make scratch work impossible. In practice it did the
latter: trying a model on a throwaway idea required creating a GitHub
repository, editing the catalog, and provisioning a dedicated clone, which is
precisely the friction that sends practice back to other tools.

`oc sandbox` opens a repository under the mode-700 fleet state directory that
has no remote at all. The launcher verifies the absence of every remote before
execution and refuses a sandbox that has acquired one. That is the whole
justification: a sandbox grants strictly less authority than any catalogued
clone, because there is nothing to push to and no GitHub identity to act as.

Everything else is unchanged — same runtime guard, same global lock, same
mode-600 run records, same private build worktree, same rollback. Sandbox
worktrees live under their own root so a sandbox can never collide with a
catalogued repository of the same name, and rollback anchors a sandbox run to
the sandbox root rather than the workspace, refusing a record that claims to be
a sandbox while pointing anywhere else.

Sandboxes are never deleted automatically, consistent with the rest of the
retention doctrine: a scratch repository is still evidence until a human
decides otherwise.
