#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SOURCE_USER_JS="$SCRIPT_DIR/user.js"

MOZILLA_DIR="${MOZILLA_DIR:-$HOME/.mozilla/firefox}"
readonly PROFILES_INI="$MOZILLA_DIR/profiles.ini"

DRY_RUN=0
TARGET_NAME=""

usage() {
  cat <<'EOF' >&2
Usage: install.sh [-p <profile-name>] [-n] [-h]

  -p <name>   link only into the named Firefox profile
  -n          dry-run: print actions without making changes
  -h          show this help

Environment:
  MOZILLA_DIR   Firefox profile root (default: ~/.mozilla/firefox)

Links user.js from this repo into every registered Firefox profile.
Firefox follows symlinks and reads user.js only at startup, so changes
flow through on the next restart after `git pull` — no re-run needed.
EOF
  exit "${1:-1}"
}

while getopts ":p:nh" opt; do
  case "$opt" in
    p) TARGET_NAME="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    h) usage 0 ;;
    \?) echo "error: unknown option: -$OPTARG" >&2; usage ;;
    :)  echo "error: option -$OPTARG requires an argument" >&2; usage ;;
  esac
done

[[ -n "$HOME" ]]           || { echo "error: HOME is not set" >&2; exit 1; }
[[ -f "$SOURCE_USER_JS" ]] || { echo "error: source not found: $SOURCE_USER_JS" >&2; exit 1; }
[[ -f "$PROFILES_INI" ]]   || { echo "error: $PROFILES_INI not found — is Firefox installed and has it been run once?" >&2; exit 1; }

# Collect registered profiles from [ProfileN] sections.
# Each record: <name>\t<isrelative>\t<path>
mapfile -t PROFILE_RECORDS < <(
  awk -v RS='' -F'\n' '
    /^\[Profile[0-9]+\]/ {
      name = ""; path = ""; isrel = "1"
      for (i = 1; i <= NF; i++) {
        if      ($i ~ /^Name=/)       name  = substr($i, 6)
        else if ($i ~ /^Path=/)       path  = substr($i, 6)
        else if ($i ~ /^IsRelative=/) isrel = substr($i, 12)
      }
      if (path != "") print name "\t" isrel "\t" path
    }
  ' "$PROFILES_INI"
)

if [[ ${#PROFILE_RECORDS[@]} -eq 0 ]]; then
  echo "error: no profiles registered in $PROFILES_INI" >&2
  exit 1
fi

# Print path of $2 relative to directory $1 (both absolute). Falls back to an
# absolute path on coreutils too old for `realpath --relative-to` (< 8.23).
relative_to() {
  local base="$1" target="$2"
  local rel
  if rel="$(realpath -m --relative-to="$base" "$target" 2>/dev/null)"; then
    printf '%s\n' "$rel"
  else
    printf '%s\n' "$target"
  fi
}

link_one() {
  local name="$1" isrel="$2" path="$3"
  local profile_dir
  if [[ "$isrel" == "1" ]]; then
    profile_dir="$MOZILLA_DIR/$path"
  else
    profile_dir="$path"
  fi

  if [[ ! -d "$profile_dir" ]]; then
    echo "warn: profile '$name' dir missing on disk: $profile_dir — skipping" >&2
    return 0
  fi

  local target="$profile_dir/user.js"
  local rel_source
  rel_source="$(relative_to "$profile_dir" "$SOURCE_USER_JS")"

  # Idempotent: already a symlink resolving to our source?
  if [[ -L "$target" ]]; then
    local existing
    existing="$(readlink -f "$target" 2>/dev/null || true)"
    if [[ "$existing" == "$SOURCE_USER_JS" ]]; then
      echo "ok: '$name' already linked"
      return 0
    fi
  fi

  # Back up any pre-existing user.js (regular file, hardlink, or stale symlink)
  # so local tweaks are never lost silently.
  if [[ -e "$target" || -L "$target" ]]; then
    local backup
    backup="$profile_dir/user.js.bak.$(date +%s)"
    if (( DRY_RUN )); then
      echo "dry: would back up $target -> $backup"
    else
      cp -a "$target" "$backup"
      echo "backed up: $target -> $backup"
    fi
  fi

  if (( DRY_RUN )); then
    echo "dry: would link $target -> $rel_source"
  else
    ln -sf "$rel_source" "$target"
    echo "linked: '$name' -> $SOURCE_USER_JS"
  fi
}

matched=0
for rec in "${PROFILE_RECORDS[@]}"; do
  IFS=$'\t' read -r name isrel path <<< "$rec"
  if [[ -n "$TARGET_NAME" && "$name" != "$TARGET_NAME" ]]; then
    continue
  fi
  matched=1
  link_one "$name" "$isrel" "$path"
done

if [[ -n "$TARGET_NAME" && "$matched" -eq 0 ]]; then
  echo "error: profile '$TARGET_NAME' not found in $PROFILES_INI" >&2
  echo "registered profiles:" >&2
  for rec in "${PROFILE_RECORDS[@]}"; do
    IFS=$'\t' read -r name _ _ <<< "$rec"
    echo "  - $name" >&2
  done
  exit 1
fi
