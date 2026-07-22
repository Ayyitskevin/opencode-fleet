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
OpenAI-compatible adapter, the mickey loopback URL, and an exact
`enabled_providers: ["ollama"]` gate. Plan, build, review, and ceiling routes
are exact values. Ordinary local execution removes common paid-provider
credentials from the child environment. The explicit allowlisted cloud lane
enables only its requested provider for that run. Alternate local models,
remote-compatible base URLs, extra providers, and implicit fallback are
configuration errors rather than routing choices.

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
