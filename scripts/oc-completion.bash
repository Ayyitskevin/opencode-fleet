#!/usr/bin/env bash

# Bash completion for the oc launcher.
#
# Source it from ~/.bashrc:
#
#     . /path/to/opencode-fleet/scripts/oc-completion.bash
#
# Repository names are case-sensitive mixed-case in the catalog, so completing
# them from the declarative manifest removes the most frequent daily typo.
# Everything here is a read-only lookup against files the user already owns.

_oc_fleet_root() {
  local source_path
  source_path="$(readlink -f "${BASH_SOURCE[0]}")"
  printf '%s\n' "$(cd "$(dirname "$source_path")/.." && pwd)"
}

_oc_complete() {
  local current previous fleet_root manifest routes state_root
  local subcommands="list doctor runs show diff note stats"
  local modes="plan build review"
  local flags="--ceiling --cloud --experiment --dry-run --help"

  current="${COMP_WORDS[COMP_CWORD]}"
  previous="${COMP_WORDS[COMP_CWORD - 1]}"
  fleet_root="$(_oc_fleet_root)"
  manifest="${OPENCODE_FLEET_MANIFEST:-$fleet_root/config/repos.json}"
  routes="${OPENCODE_FLEET_ROUTES:-$fleet_root/config/model-routes.json}"
  state_root="${OPENCODE_FLEET_STATE_ROOT:-$HOME/.local/state/opencode-fleet}"

  # A model may only be requested from the declared allowlist, so completion
  # offers exactly what the launcher would accept.
  if [[ "$previous" == "--experiment" ]]; then
    local experiments=""
    [[ ! -r "$routes" ]] ||
      experiments="$(jq -r '(.localExperiments // [])[]' "$routes" 2>/dev/null)"
    mapfile -t COMPREPLY < <(compgen -W "$experiments" -- "$current")
    return 0
  fi

  # Subcommands that take a run identity complete from lane-owned run state.
  case "${COMP_WORDS[1]:-}" in
    show|diff|note)
      if [[ "$COMP_CWORD" -eq 2 ]]; then
        local run_ids=""
        [[ ! -d "$state_root/runs" ]] ||
          run_ids="$(cd "$state_root/runs" && printf '%s\n' */ 2>/dev/null |
            sed 's:/$::')"
        mapfile -t COMPREPLY < <(compgen -W "$run_ids" -- "$current")
        return 0
      fi
      ;;
    runs)
      if [[ "$COMP_CWORD" -eq 2 ]]; then
        local names=""
        [[ ! -r "$manifest" ]] ||
          names="$(jq -r '.repositories[].name' "$manifest" 2>/dev/null)"
        mapfile -t COMPREPLY < <(compgen -W "$names" -- "$current")
        return 0
      fi
      ;;
    stats)
      if [[ "$COMP_CWORD" -eq 2 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--model --repo" -- "$current")
        return 0
      fi
      ;;
    doctor)
      mapfile -t COMPREPLY < <(compgen -W "--strict --local-models" -- "$current")
      return 0
      ;;
  esac

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    local names=""
    [[ ! -r "$manifest" ]] ||
      names="$(jq -r '.repositories[] | select(.state == "active") | .name' \
        "$manifest" 2>/dev/null)"
    mapfile -t COMPREPLY < <(compgen -W "$subcommands $names" -- "$current")
    return 0
  fi

  if [[ "$COMP_CWORD" -eq 2 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$modes $flags" -- "$current")
    return 0
  fi

  mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$current")
}

complete -F _oc_complete oc
