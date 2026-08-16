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

Every finished run records its duration and, for builds, a diffstat of the work
it produced. `oc runs`, `oc show`, `oc diff`, and `oc stats` read that evidence
back; `oc note` annotates a finished run with what actually happened, so
practice with different local models accumulates instead of evaporating. All of
these are read-only over lane-owned state except `note`, which appends to one
record. An interrupted session — Ctrl-C is the normal way to leave a TUI —
finalizes its own record as `interrupted` rather than claiming to be active
forever.

The runtime guard disables sharing, auto-update, external-directory access,
web access, nested tasks, and direct pushes. Destructive Git operations,
recursive deletion, and privilege escalation are deny-listed across their
common spellings rather than proven impossible; every command that is not
explicitly denied still requires an operator prompt, and no Bash command has
an automatic allow rule. Planning denies Bash entirely; review/build commands
require an explicit prompt unless denied outright. Content-returning grep and
LSP tools are denied because their permission checks do not inherit the read
tool's credential-path exclusions; path-only enumeration remains available.

## Routes and interface

    oc list
    oc doctor [--strict] [--local-models]
    oc sandbox new <name>
    oc sandbox list
    oc sandbox <name> [plan|build|review]
    oc runs [repository]
    oc show <run-id>
    oc diff <run-id>
    oc note <run-id> <text>
    oc stats [--model | --repo]
  oc <repository> [plan|build|review]
     [--ceiling | --cloud | --experiment ollama/<model>]
     [--prompt <file>] [--dry-run]

Examples:

    oc Icarus
    oc Icarus build
    oc Icarus review --ceiling
    oc Icarus plan --experiment ollama/qwen3.8:27b
    OPENCODE_FLEET_CLOUD_MODEL=provider/model oc Icarus review --cloud
    oc sandbox practice build --prompt task.txt --experiment ollama/qwen3.8:27b

All ordinary modes use the pinned cost-efficient
ollama/qwen3-coder:30b. --ceiling is the only route to
ollama/qwen3-coder-next:q8_0. These local selections are deterministic and
cannot be changed with environment model overrides.

`--experiment` is the one sanctioned way to run a different local model, for
practice and comparison. It accepts only exact `ollama/<model>` entries listed
in `localExperiments` in config/model-routes.json, requires that model to exist
in the staged provider catalog, may not shadow a pinned route, and is mutually
exclusive with `--ceiling` and `--cloud`. Like every other escalation it is a
command-line request, never an environment override, and never a fallback.
The allowlist carries the staged local models that are not already pinned to a
route; the two pinned models are rejected from it so an experiment can never
quietly shadow the daily lane. Trim the list to taste — an entry that is not
in the staged provider catalog, or is not pulled in Ollama, fails closed, and
`scripts/doctor --local-models` reports the difference.

`--prompt <file>` switches a run from the interactive TUI to a non-interactive
`opencode run` of the file's contents. The model receives the prompt as a
positional message and works in the same private worktree (build) or source
path (plan/review) as an interactive run, under the same guard, lock, and
sanitized environment. Output is captured into the run record so a
non-interactive practice run leaves reviewable evidence alongside its diffstat.
It is the invocation shape `oc compare` will build on; on its own it is the
way to run a model against a task without holding a terminal. The
non-interactive `opencode run --pure --dir` shape was smoke-tested under the
fleet's isolated runtime (sanitized environment, `--pure`, injected guard)
against the installed 1.18.18 binary: a trivial reply and a `fleet-build`
file-write task both completed without hanging. The fleet pins 1.18.4, so
confirm on the pinned binary before relying on it in production.

`oc compare` runs one `--prompt` task across N local models so practice
compounds into a record of which model is good at what. It is a local-only
lane: it rejects `--ceiling`, `--cloud`, and `--experiment`, and every model
must be listed in `localExperiments` and present in the staged provider
catalog. With no `--models` it runs the whole allowlist; `--models a,b,c`
runs a subset. Each model is a full `oc ... build --prompt --experiment
<model>` run — its own lock, private worktree, sanitized environment, run
record, and diffstat — so compare reuses the existing machinery without
widening any boundary. The global lock serializes the runs; compare itself
holds no lock and creates no worktree. The runs are reviewed afterwards with
`oc diff <run-id>` and `oc show <run-id>`, and the comparison table compare
prints (model, status, duration, diffstat, run) is read back from the same
records. The same 1.18.18-smoke-tested / pinned-1.18.4-unconfirmed caveat as
`--prompt` applies.

The staged catalog deliberately holds only models that can drive an agent.
Embedding models, safety classifiers, and single-domain models are left out
because they cannot run a coding lane, not because they are unwelcome.

`oc sandbox` is the throwaway practice lane. A sandbox is a private repository
under the mode-700 fleet state directory with **no remote at all**, so it
carries strictly less authority than any catalogued clone: there is nothing to
push to and no GitHub identity to act as. Otherwise it is an ordinary run —
same guard, same lock, same run records, same private build worktree, and the
same `oc diff` and rollback. A sandbox that acquires a remote stops being a
sandbox and is refused. Sandboxes are never deleted automatically; remove one
by hand when you are done with it.

The installed provider map is closed: it contains only `ollama`, uses
`@ai-sdk/openai-compatible`, and points to
`http://127.0.0.1:11434/v1`; `enabled_providers` is exactly `["ollama"]`.
The launcher and installer reject extra providers, remote base URLs, alternate
adapters, enabled-provider drift, and substituted local model routes before
model execution or installation. Every session removes paid-provider
credentials and cloud credential-file pointers from the model process
environment: both an explicit list of known provider variables and a sweep of
any credential-shaped variable name present, so a provider that did not exist
when the list was written is stripped too.

Cloud requires all three conditions:

1. config/model-routes.json has cloud.enabled set to true.
2. The exact provider/model is present in cloud.allowlist.
3. OPENCODE_FLEET_CLOUD_MODEL requests that exact entry with --cloud.

An empty allowlist is the shipped default. OpenCode is invoked once; a cloud
error is returned as-is without a local or second-cloud retry. The explicit
`--cloud` lane enables only the provider named by the allowlisted model and
preserves only that provider's credentials for that one run; every other
provider's credentials are removed exactly as they are locally. A model whose
provider has no declared credential mapping is refused rather than run with an
unscrubbed environment.

## Installation

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for the ordered path from a fresh
clone to a first session. This section is the authoritative reference for what
each installer guarantees.

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
    scripts/doctor --local-models

Doctor never prints raw remote URLs. `--local-models` is the one check that
reaches outside this repository: it is opt-in, read-only, and queries only the
pinned loopback endpoint to confirm the daemon is up and every routed and
allowlisted model is pulled. It is never part of the launch path.

Doctor validates the pinned CLI install record, target, version, archive pin,
and installed binary digest with the same acceptance contract as the launcher.
Strict mode also treats incomplete rollout warnings as failure.

## Verification

Run the gate as a non-root user; the launcher refuses to run as root and the
gate fails fast rather than dying mid-suite. The suites neutralize ambient and
host Git configuration, so `insteadOf` rewrites or a signing requirement in a
personal `~/.gitconfig` cannot change their results.

    scripts/check

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

The GitHub rollout inventory contains 22 active repositories and four explicit
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
- config/model-routes.json — deterministic local routes, the local experiment
  allowlist, and allowlisted cloud routes.
- config/versions.json — pinned CLI/archive hash and workflow dependencies.
- scripts/oc — one-repository launcher and run-history commands.
- scripts/lib/fleet-contracts.sh — canonical credential and shell deny tables
  shared by the launcher, doctor, and the installer.
- scripts/oc-completion.bash — optional Bash completion.
- scripts/doctor — no-model installation, policy, and clone diagnostics.
- scripts/sync-clones — one-repository dry-run-first provisioning.
- scripts/install-* — reversible local installers.
- scripts/rollback — run and install recovery.
- tests/ — policy and boundary tests.

No license has been selected. Licensing remains a human/legal decision before
public reuse is invited.
