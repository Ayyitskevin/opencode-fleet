# Rollback and recovery

Rollback is local, preview-first, and preservation-oriented. It never removes a
dedicated clone, run branch, private worktree, backup tree, or recovery record.
Every mutation requires --apply and the same global lock used by the launcher.

## Build run rollback

Find the run ID in the launcher output or in:

    ~/.local/state/opencode-fleet/runs/<run-id>/record.json

Preview:

    scripts/rollback run <run-id>

Apply:

    scripts/rollback run <run-id> --apply

The command verifies all of the following before changing the worktree:

- the record is a valid build record for one exact active catalog entry;
- the source is the catalogued independent clone;
- the worktree is the lane-owned path for that run;
- its Git common directory belongs to that dedicated clone;
- its branch matches the recorded run branch; and
- HEAD still equals the recorded base commit.

The last check is intentional: automatic rollback refuses committed changes.
A committed run branch must be reviewed or preserved manually.

Before restoration, rollback writes these private recovery artifacts:

- unstaged.patch — binary-capable tracked-file patch;
- staged.patch — binary-capable index patch;
- status.z — NUL-delimited pre-rollback Git status; and
- untracked/ — every untracked file moved intact out of the worktree.

The worktree is then restored to the base commit, verified clean, and its run
record becomes rolled-back with rollbackRecovery pointing to the evidence.
The private worktree and branch remain in place.

To recover later, inspect the saved status, apply the appropriate patch with
Git, and copy selected quarantined files back. Do not blindly apply both
patches without reviewing their staged/unstaged relationship.

## Local config and launcher rollback

The local installer writes:

    ~/.local/state/opencode-fleet/install.json

Preview and apply:

    scripts/rollback install
    scripts/rollback install --apply

Rollback validates that recorded targets are exactly the selected home's
OpenCode config and oc launcher. Current installed targets are moved into a new
private recovery directory before timestamped backups are restored. If there
was no previous target, the installed target remains preserved in recovery and
the destination becomes absent.

A previous install record is restored when one was backed up. Otherwise the
current record moves into recovery. Nothing is deleted.

## CLI rollback

The pinned CLI installer writes:

    ~/.local/state/opencode-fleet/cli-install.json

Preview and apply:

    scripts/rollback cli
    scripts/rollback cli --apply

The current CLI is moved into recovery before its prior binary is restored. If
there was no prior binary, the newly installed CLI remains recoverable there
and the destination becomes absent.

## Install backups and interrupted operations

Install backups live below install-backups/ and cli-backups/ in the fleet state
root. Recovery operations live below recovery/. All are private to the user.

Before replacing any target, each installer first acquires the same
non-blocking `session.lock` used by sessions, clone sync, and rollback. It then
writes and syncs a mode-600
`prepared` record containing the transaction ID, backup root, exact targets,
backup paths, and candidate digest. After final target validation it atomically
changes that record to `installed` and syncs it again. An ordinary trapped
failure restores the previous targets and previous record, while preserving the
failed current target and prepared record below the transaction's backup root.

A power loss or untrappable termination can leave the durable record in
`prepared` state. Both rollback commands accept that state so the recorded
backup set remains recoverable, but preview and inspect the target types,
digests, and backup root before applying rollback. Do not rerun an installer
blindly over a prepared transaction. The scripts refuse target directories and
symlinked state roots; the durable record prevents the earlier unrecorded
partial-target window.

If rollback itself stops, preserve its recovery directory and inspect which
targets are present before retrying. Because current targets are moved rather
than deleted, the recovery directory is the authoritative evidence.

## Clone and worktree retention

scripts/sync-clones never deletes or converts an existing path. It refuses root
execution, keeps its state root inside the selected canonical home, rejects
symlinked path ancestors before and after state creation, and preserves an
invalid or partial target for inspection after clone failure.

No rollback command removes:

- dedicated clones;
- Git worktrees or run branches;
- install backup directories;
- rollback recovery directories; or
- run/install records except when a current install record is itself moved
  into its recovery transaction.

Cleanup of those items is a separate human-reviewed decision. A backup does not
authorize deletion of shared or potentially useful state.

## GitHub lane

The local rollback commands do not change GitHub.

For remote automation, disable the affected thin caller, revoke its environment
credential, and leave the central reusable workflow commit intact for audit.
Do not automatically close pull requests or delete branches, environments,
secrets, or logs.
