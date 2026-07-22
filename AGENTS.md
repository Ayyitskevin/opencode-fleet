# OpenCode Fleet repository contract

This repository owns the small control plane that makes OpenCode available
across Kevin's repositories without silently widening authority or cloud spend.

## Invariants

- Local execution opens exactly one catalogued repository at a time.
- Local Ollama is the default. Paid providers require an explicit `--cloud`
  request and an explicitly configured cloud model.
- Session sharing is disabled.
- External-directory access and direct pushes are denied.
- GitHub comment automation is owner-only and read-only.
- Mutating GitHub automation is manual, protected, branch/PR-only, and never
  deploys, migrates, changes secrets, or pushes a protected default branch.
- Every action, workflow, installer, and reusable workflow reference is pinned
  immutably and updated intentionally.
- Never place credentials, tokens, private repository contents, or client data
  in this repository, its tests, logs, or fixtures.

## Working conventions

- Prefer Bash plus `jq`; do not introduce a runtime dependency without a
  demonstrated need.
- Keep the repository catalog declarative in `config/repos.json`.
- Make launcher and workflow policy fail closed on missing or malformed input.
- Test policy boundaries with hostile actor, command, fork, ref, and config
  cases before publication.
- Use `scripts/check` as the local acceptance gate.
