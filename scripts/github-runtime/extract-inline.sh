#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s <workflow> <runtime-block>\n' "$0" >&2
  exit 64
fi

workflow="$1"
block="$2"

[[ -f "$workflow" ]] || {
  printf 'workflow not found: %s\n' "$workflow" >&2
  exit 66
}

[[ "$block" =~ ^[a-z0-9-]+$ ]] || {
  printf 'invalid runtime block name: %s\n' "$block" >&2
  exit 64
}

awk -v start="# runtime:${block}:start" -v stop="# runtime:${block}:end" '
  index($0, start) {
    if (active || seen) exit 65
    match($0, /^ */)
    indent = RLENGTH
    active = 1
    seen = 1
    next
  }
  index($0, stop) {
    if (!active) exit 65
    active = 0
    closed = 1
    next
  }
  active {
    leading = 0
    while (leading < length($0) && substr($0, leading + 1, 1) == " ") leading++
    if (length($0) == 0) {
      print ""
      next
    }
    if (leading < indent) exit 65
    print substr($0, indent + 1)
  }
  END {
    if (!seen || !closed || active) exit 65
  }
' "$workflow"
