#!/usr/bin/env bash

# Canonical fleet policy contracts.
#
# The credential read table and the shell deny tables are the security surface
# of the local lane. They were previously validated only structurally — "the
# first entry allows, every later entry denies" — which is vacuously true for a
# table with no credential entries left in it, and says nothing about which
# paths are actually denied. They are pinned here by exact content and exact
# order, once, so the launcher, the diagnostic, and the installer cannot drift
# apart and no deny rule can be removed without failing every gate.
#
# Order is part of the contract: OpenCode resolves permissions by pattern
# order, so these are compared as entry lists rather than objects.

fleet_read_table() {
  cat <<'JSON'
{
  "*": "allow",
  ".env": "deny",
  ".env.*": "deny",
  "**/.env": "deny",
  "**/.env.*": "deny",
  ".envrc": "deny",
  "**/.envrc": "deny",
  ".netrc": "deny",
  "**/.netrc": "deny",
  ".npmrc": "deny",
  "**/.npmrc": "deny",
  ".pypirc": "deny",
  "**/.pypirc": "deny",
  ".git-credentials": "deny",
  "**/.git-credentials": "deny",
  "credentials.json": "deny",
  "**/credentials.json": "deny",
  "secrets.json": "deny",
  "**/secrets.json": "deny",
  "secrets.yaml": "deny",
  "**/secrets.yaml": "deny",
  "secrets.yml": "deny",
  "**/secrets.yml": "deny",
  "secrets.toml": "deny",
  "**/secrets.toml": "deny",
  "*.pem": "deny",
  "**/*.pem": "deny",
  "*.key": "deny",
  "**/*.key": "deny",
  "*.p12": "deny",
  "**/*.p12": "deny",
  "*.pfx": "deny",
  "**/*.pfx": "deny",
  "*.ppk": "deny",
  "**/*.ppk": "deny",
  "*credentials*": "deny",
  "**/*credentials*": "deny",
  "id_rsa": "deny",
  "**/id_rsa": "deny",
  "id_dsa": "deny",
  "**/id_dsa": "deny",
  "id_ecdsa": "deny",
  "**/id_ecdsa": "deny",
  "id_ecdsa_sk": "deny",
  "**/id_ecdsa_sk": "deny",
  "id_ed25519": "deny",
  "**/id_ed25519": "deny",
  "id_ed25519_sk": "deny",
  "**/id_ed25519_sk": "deny"
}
JSON
}

fleet_bash_table() {
  case "$1" in
    global)
      cat <<'JSON'
{
  "*": "ask",
  "bash *": "deny",
  "*/bash *": "deny",
  "sh *": "deny",
  "*/sh *": "deny",
  "zsh *": "deny",
  "*/zsh *": "deny",
  "env *": "deny",
  "*/env *": "deny",
  "command *": "deny",
  "xargs *": "deny",
  "*/xargs *": "deny",
  "gh *": "deny",
  "*/gh *": "deny",
  "hub *": "deny",
  "*/hub *": "deny",
  "git remote set-url*": "deny",
  "git config *credential*": "deny",
  "git config *pushurl*": "deny",
  "git push*": "deny",
  "git * push*": "deny",
  "/usr/bin/git push*": "deny",
  "*/git push*": "deny",
  "git reset --hard*": "deny",
  "git * reset --hard*": "deny",
  "/usr/bin/git reset --hard*": "deny",
  "*/git reset --hard*": "deny",
  "git clean*": "deny",
  "git * clean*": "deny",
  "/usr/bin/git clean*": "deny",
  "*/git clean*": "deny",
  "rm -rf*": "deny",
  "rm -fr*": "deny",
  "rm -r -f*": "deny",
  "rm -f -r*": "deny",
  "rm --recursive*": "deny",
  "rm --force*": "deny",
  "/bin/rm -rf*": "deny",
  "/bin/rm -fr*": "deny",
  "/usr/bin/rm -rf*": "deny",
  "/usr/bin/rm -fr*": "deny",
  "*/rm -rf*": "deny",
  "*/rm -fr*": "deny",
  "sudo *": "deny",
  "/usr/bin/sudo *": "deny",
  "*/sudo *": "deny",
  "*git*push*": "deny"
}
JSON
      ;;
    review)
      cat <<'JSON'
{
  "*": "ask",
  "bash *": "deny",
  "*/bash *": "deny",
  "sh *": "deny",
  "*/sh *": "deny",
  "zsh *": "deny",
  "*/zsh *": "deny",
  "env *": "deny",
  "*/env *": "deny",
  "command *": "deny",
  "xargs *": "deny",
  "*/xargs *": "deny",
  "gh *": "deny",
  "*/gh *": "deny",
  "hub *": "deny",
  "*/hub *": "deny",
  "git commit*": "deny",
  "git remote set-url*": "deny",
  "git config *credential*": "deny",
  "git config *pushurl*": "deny",
  "git push*": "deny",
  "git * push*": "deny",
  "/usr/bin/git push*": "deny",
  "*/git push*": "deny",
  "git reset --hard*": "deny",
  "git * reset --hard*": "deny",
  "/usr/bin/git reset --hard*": "deny",
  "*/git reset --hard*": "deny",
  "git clean*": "deny",
  "git * clean*": "deny",
  "/usr/bin/git clean*": "deny",
  "*/git clean*": "deny",
  "rm -rf*": "deny",
  "rm -fr*": "deny",
  "rm -r -f*": "deny",
  "rm -f -r*": "deny",
  "rm --recursive*": "deny",
  "rm --force*": "deny",
  "/bin/rm -rf*": "deny",
  "/bin/rm -fr*": "deny",
  "/usr/bin/rm -rf*": "deny",
  "/usr/bin/rm -fr*": "deny",
  "*/rm -rf*": "deny",
  "*/rm -fr*": "deny",
  "sudo *": "deny",
  "/usr/bin/sudo *": "deny",
  "*/sudo *": "deny",
  "*git*push*": "deny"
}
JSON
      ;;
    build)
      cat <<'JSON'
{
  "*": "ask",
  "bash *": "deny",
  "*/bash *": "deny",
  "sh *": "deny",
  "*/sh *": "deny",
  "zsh *": "deny",
  "*/zsh *": "deny",
  "env *": "deny",
  "*/env *": "deny",
  "command *": "deny",
  "xargs *": "deny",
  "*/xargs *": "deny",
  "gh *": "deny",
  "*/gh *": "deny",
  "hub *": "deny",
  "*/hub *": "deny",
  "git commit*": "ask",
  "git remote set-url*": "deny",
  "git config *credential*": "deny",
  "git config *pushurl*": "deny",
  "git push*": "deny",
  "git * push*": "deny",
  "/usr/bin/git push*": "deny",
  "*/git push*": "deny",
  "git reset --hard*": "deny",
  "git * reset --hard*": "deny",
  "/usr/bin/git reset --hard*": "deny",
  "*/git reset --hard*": "deny",
  "git clean*": "deny",
  "git * clean*": "deny",
  "/usr/bin/git clean*": "deny",
  "*/git clean*": "deny",
  "rm -rf*": "deny",
  "rm -fr*": "deny",
  "rm -r -f*": "deny",
  "rm -f -r*": "deny",
  "rm --recursive*": "deny",
  "rm --force*": "deny",
  "/bin/rm -rf*": "deny",
  "/bin/rm -fr*": "deny",
  "/usr/bin/rm -rf*": "deny",
  "/usr/bin/rm -fr*": "deny",
  "*/rm -rf*": "deny",
  "*/rm -fr*": "deny",
  "sudo *": "deny",
  "/usr/bin/sudo *": "deny",
  "*/sudo *": "deny",
  "*git*push*": "deny"
}
JSON
      ;;
    *)
      printf 'fleet_bash_table: unknown scope: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# Pins the permission surface shared by the staged config and the injected
# runtime guard. Callers supply the document; the tables come from above.
fleet_permission_contract() {
  cat <<'JQ'
(.permission.read | to_entries) == ($readTable | to_entries) and
(.permission.bash | to_entries) == ($bashGlobal | to_entries) and
.permission.external_directory == "deny" and
.permission.webfetch == "deny" and
.permission.websearch == "deny" and
.permission.task == "deny" and
.permission.skill == "deny" and
.permission.grep == "deny" and
.permission.lsp == "deny" and
.permission["*"] == "ask" and
(.agent | keys | sort) == ["fleet-build", "fleet-plan", "fleet-review"] and
.agent["fleet-plan"].permission.bash == "deny" and
.agent["fleet-plan"].permission.edit == "deny" and
.agent["fleet-review"].permission.edit == "deny" and
.agent["fleet-build"].permission.edit == "allow" and
(.agent["fleet-review"].permission.bash | to_entries) ==
  ($bashReview | to_entries) and
(.agent["fleet-build"].permission.bash | to_entries) ==
  ($bashBuild | to_entries) and
all(.agent[];
  .permission.external_directory == "deny" and
  .permission.webfetch == "deny" and
  .permission.websearch == "deny" and
  .permission.task == "deny" and
  .permission.skill == "deny" and
  .tools == {skill: false})
JQ
}

# Applies the contract to a JSON document on stdin.
fleet_assert_permission_contract() {
  jq -e \
    --argjson readTable "$(fleet_read_table)" \
    --argjson bashGlobal "$(fleet_bash_table global)" \
    --argjson bashReview "$(fleet_bash_table review)" \
    --argjson bashBuild "$(fleet_bash_table build)" \
    "$(fleet_permission_contract)" >/dev/null
}
