#!/usr/bin/env bash
#
# Prints the tags for this build, one per line.
#
#   sha-<first 12 characters of the commit>   always. Never moves, so it is safe for registries
#                                             with immutable tags.
#   <branch name, cleaned up>                 only when MUTABLE_TAGS=true (default)
#   latest                                    only when MUTABLE_TAGS=true and on the default branch
#
# Inputs (environment): GITHUB_SHA, GITHUB_REF_NAME (set by GitHub Actions),
#                       DEFAULT_BRANCH (default "main"), MUTABLE_TAGS (default "true").
set -euo pipefail

: "${GITHUB_SHA:?GITHUB_SHA is not set}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is not set}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
MUTABLE_TAGS="${MUTABLE_TAGS:-true}"

if ! [[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: GITHUB_SHA must be a 40-character commit id" >&2
  exit 1
fi

echo "sha-${GITHUB_SHA:0:12}"

if [ "$MUTABLE_TAGS" = "true" ]; then
  # Docker tags allow letters, digits, "_", "." and "-" (max 128, not starting with "." or "-").
  slug="$(printf '%s' "$GITHUB_REF_NAME" | tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9_.-]+/-/g; s/^[.-]+//; s/-+$//' | cut -c1-100)"
  if [ -n "$slug" ] && [ "$slug" != "latest" ]; then
    echo "$slug"
  fi
  if [ "$GITHUB_REF_NAME" = "$DEFAULT_BRANCH" ]; then
    echo "latest"
  fi
fi
