# OpenCode Fleet

OpenCode Fleet is Kevin's hardened fallback lane for running OpenCode against
exactly one catalogued repository at a time. Local Ollama is the normal path.
Paid cloud use is off by default, explicitly allowlisted when enabled, and
never a fallback.

The GitHub workflows are a separate convenience lane. They do not weaken the
local guard or grant the local launcher publication authority. Remote builds
are deliberately narrower than local builds: they may propose changes only to
`README.md`, `docs/`, and `tests/`; source and operational-script edits require
the operator-present local lane.

The central `Ayyitskevin/opencode-fleet` repository must remain public so every
public consumer can call its pinned reusable workflows. Rollout rejects private,
missing, or contradictory central visibility before touching a consumer.

## Local safety contract

The launcher accepts repository identities from config/repos.json, never
arbitrary paths. Before model execution it verifies that the selected path is:

- inside the canonical dedicated OpenCode workspace;
- a real independent clone with its own .git directory, not a symlink, linked
  worktree, or shared clone;
- backed by exactly one credential-free matching GitHub origin; and
- clean and on its catalogued default branch for build.

One global lock serializes every local session, installer, rollback, and clone
provisioning mutation.
Plan denies Bash and source edits. Review denies the edit tool and publication;
any shell command still requires an operator prompt. Build creates a unique
private worktree and branch under the mode-700 fleet state directory, leaving
the dedicated clone clean. Every real session gets a mode-600 run record.
Worktrees remain available for review or reversible rollback.

The runtime guard disables sharing, auto-update, external-directory access,
web access, nested tasks, direct pushes, destructive Git operations, recursive
deletion, and sudo. No Bash command has an automatic allow rule. Planning
denies Bash entirely; review/build commands require an explicit prompt unless
denied outright. Content-returning grep and LSP tools are denied because their
permission checks do not inherit the read tool's credential-path exclusions;
path-only enumeration remains available.

## Routes and interface

    oc list
    oc doctor [--strict]
    oc <repository> [plan|build|review] [--ceiling | --cloud] [--dry-run]

Examples:

    oc Icarus
    oc Icarus build
    oc Icarus review --ceiling
    OPENCODE_FLEET_CLOUD_MODEL=provider/model oc Icarus review --cloud

All ordinary modes use the pinned cost-efficient
ollama/qwen3-coder:30b. --ceiling is the only route to
ollama/qwen3-coder-next:q8_0. These local selections are deterministic and
cannot be changed with environment model overrides.

The installed provider map is closed: it contains only `ollama`, uses
`@ai-sdk/openai-compatible`, and points to
`http://127.0.0.1:11434/v1`; `enabled_providers` is exactly `["ollama"]`.
The launcher and installer reject extra providers, remote base URLs, alternate
adapters, enabled-provider drift, and substituted local model routes before
model execution or installation. Normal local and ceiling sessions also remove
common paid-provider credentials and cloud credential-file pointers from the
model process environment.

Cloud requires all three conditions:

1. config/model-routes.json has cloud.enabled set to true.
2. The exact provider/model is present in cloud.allowlist.
3. OPENCODE_FLEET_CLOUD_MODEL requests that exact entry with --cloud.

An empty allowlist is the shipped default. OpenCode is invoked once; a cloud
error is returned as-is without a local or second-cloud retry. The explicit
`--cloud` lane enables only the provider named by the allowlisted model and
preserves its provider environment for that one run; this exception is never
active for ordinary local or ceiling execution.

## Installation

Both installers preview by default. They do not download anything.

1. Obtain the exact archive named and hashed in config/versions.json.
2. Preview, then install the pinned CLI:

       scripts/install-opencode-cli --archive /absolute/path/opencode-linux-x64.tar.gz
       scripts/install-opencode-cli --archive /absolute/path/opencode-linux-x64.tar.gz --apply

3. Preview, then install the staged config and canonical oc symlink:

       scripts/install-local
       scripts/install-local --apply

Existing targets are timestamp-backed-up before atomic replacement. Each
installer first acquires the same non-blocking fleet session lock used by the
launcher, sync, and rollback commands. It then persists a mode-600 `prepared`
transaction record and syncs it, then replaces targets, validates them, and
atomically marks the record
`installed`. A trapped failure restores the previous targets and record while
preserving failed current state in the timestamped backup. OpenCode
config/state/cache trees are hardened by removing group/other access. Install
records live under ~/.local/state/opencode-fleet/.

Provision one dedicated clone at a time:

    scripts/sync-clones Icarus
    scripts/sync-clones Icarus --apply
    scripts/sync-clones Icarus --source /absolute/local/Icarus --apply

The local-source form uses --no-hardlinks and rewrites origin to the
credential-free catalogued GitHub identity. Clone provisioning refuses root
execution and requires its state root to remain beneath a canonical,
symlink-free selected home. Placeholders are never fabricated.

After installation and clone provisioning:

    scripts/doctor
    scripts/doctor --strict

Doctor never prints raw remote URLs. It validates the pinned CLI install record,
target, version, archive pin, and installed binary digest with the same
acceptance contract as the launcher. Strict mode also treats incomplete rollout
warnings as failure.

## Verification

    tests/manifest.test.sh
    tests/launcher.test.sh
    tests/local-lane.test.sh
    tests/workflow-security.test.sh
    tests/rollout.test.sh
    scripts/check

The focused tests use temporary homes, clones, binaries, and state roots; they
do not install machine-local files or contact a network. The workflow test uses
an offline fixture to prove that the host invokes the exact
`opencode --pure run` contract with isolated runtime settings. That fixture
does not execute a provider or claim to prove the upstream CLI's isolation
semantics; a live pilot remains a separate human-approved acceptance step.

The GitHub rollout inventory contains 21 active repositories and five explicit
placeholders. Every active repository is addressable by the local launcher;
placeholder entries remain disabled until their first intentional product
commit. Remote caller rollout is separate, one repository at a time, and
requires environment and branch protections to pass the read-only plan.

## Rollback

All rollback commands preview first:

    scripts/rollback run <run-id>
    scripts/rollback run <run-id> --apply
    scripts/rollback install --apply
    scripts/rollback cli --apply

Run rollback refuses commits. Before restoring the base commit it preserves
binary staged/unstaged patches, status evidence, and every untracked file under
a private recovery directory. Install rollback moves the current target into
recovery before restoring its timestamped backup. See docs/ROLLBACK.md for the
exact recovery contract.

## Repository layout

- config/repos.json — repository inventory and authority class.
- config/opencode.jsonc — staged loopback Ollama and permission config.
- config/runtime-guard.json — launcher-injected non-negotiable guard.
- config/model-routes.json — deterministic local and allowlisted cloud routes.
- config/versions.json — pinned CLI/archive hash and workflow dependencies.
- scripts/oc — one-repository launcher.
- scripts/doctor — no-model installation, policy, and clone diagnostics.
- scripts/sync-clones — one-repository dry-run-first provisioning.
- scripts/install-* — reversible local installers.
- scripts/rollback — run and install recovery.
- tests/ — policy and boundary tests.

No license has been selected. Licensing remains a human/legal decision before
public reuse is invited.
