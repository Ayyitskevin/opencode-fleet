# Quickstart

The shortest path from a fresh clone to a first local session. README.md
remains the authoritative reference for the safety contract; this page only
orders the steps.

Everything previews by default. Nothing downloads, and no command mutates a
target until `--apply`.

## 1. Prerequisites

- `bash`, `git`, `jq`, `flock`, `curl` (only for `doctor --local-models`).
- Ollama listening on `http://127.0.0.1:11434` with the routed models pulled.
- The exact OpenCode archive named and hashed in `config/versions.json`.
- A non-root user. The launcher refuses to run as root, and so does the gate.

## 2. Point the catalog at your machine

`config/repos.json` carries `workspaceRoot`, the one directory that may hold
dedicated clones. It ships as an absolute path for a specific machine, so set
it to yours before anything else — the launcher requires the path to be
canonical, symlink-free, and already present:

    mkdir -p /your/ai-workspace/opencode

Then edit `workspaceRoot` in `config/repos.json` to match.

## 3. Install the pinned CLI and the local config

    scripts/install-opencode-cli --archive /absolute/path/opencode-linux-x64.tar.gz
    scripts/install-opencode-cli --archive /absolute/path/opencode-linux-x64.tar.gz --apply

    scripts/install-local
    scripts/install-local --apply

Both write a durable `prepared` transaction record before touching a target and
advance it to `installed` only after validation. If either is interrupted, run
the matching `scripts/rollback install|cli --apply` before rerunning it — the
installers refuse to bury an unreconciled transaction.

## 4. Provision one dedicated clone

    scripts/sync-clones Icarus
    scripts/sync-clones Icarus --apply

## 5. Check the fleet, then the model plane

    scripts/doctor
    scripts/doctor --strict
    scripts/doctor --local-models

`--local-models` is the one check that reaches outside this repository. It is
opt-in, read-only, and queries only the pinned loopback endpoint to confirm the
daemon is up and every routed and allowlisted model is actually pulled — the
most common reason a fully valid launcher still fails to start work.

## 6. First session

    oc list
    oc Icarus                 # plan, read-only, no shell
    oc Icarus review
    oc Icarus build           # private worktree; the clone stays clean

Plan denies Bash and edits. Review denies edits and publication. Build works in
a private run worktree on its own branch, leaving the dedicated clone
untouched.

## 7. Read back what happened

    oc runs
    oc runs Icarus
    oc show <run-id>
    oc diff <run-id>
    oc note <run-id> "35b planned well but invented the test layout"
    oc stats --model

## 8. Practising with other local models

The sole direct-only fast-code route is Ornith 1.5. Confirm the active host's
exact routed tags are pulled (`scripts/doctor --strict`), then:

    oc Icarus plan --experiment ollama/ornith-1.5:35b

Run the same task across models, then compare with `oc diff` and `oc stats`.
Ornith is explicit-only, so it can never quietly become the default.

The verified host profiles are:

| Lane | Mickey | Flow |
| --- | --- | --- |
| daily code | `qwen3.8:27b` | `qwen3.8:27b` |
| direct-only fast code | `ornith-1.5:35b` | `ornith-1.5:35b` |
| simple / vision | `muse-glimmer:latest` | `muse-glimmer:30b` |

Other pulled models are outside this harness's agent-routing policy. Embeddings,
safety classifiers, medical models, and retrieval models remain available to
their owning services but are not silent substitutes for an OpenCode lane.

## 9. Throwaway practice

Practising should not require a catalogued GitHub repository:

    oc sandbox new scratch
    oc sandbox list
    oc sandbox scratch                    # plan
    oc sandbox scratch build              # private worktree, as usual
    oc sandbox scratch plan --experiment ollama/ornith-1.5:35b
    oc diff <run-id>

A sandbox has no remote, so nothing in it can be published. Build still needs
a clean tree — commit your scratch work first — and the model works in a
private worktree, which is what makes the same task comparable across
several models. Delete a sandbox by hand when you are done;
nothing removes one for you.

## 10. Publishing work

There is no automated push. Review a finished build with `oc diff <run-id>`,
then publish its branch yourself from the dedicated clone. See
[ROLLBACK.md](ROLLBACK.md) to undo a run instead.

## Optional: completion

    . scripts/oc-completion.bash

Completes catalogued repository names, subcommands, modes, flags, allowlisted
experiment models, and run IDs.

## Verifying a change

    scripts/check

Run it as a non-root user. It discovers every script and suite by glob, so a
newly added test cannot escape the gate by being forgotten.
