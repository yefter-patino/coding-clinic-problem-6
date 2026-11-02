#!/usr/bin/env bash
#
# Copies an already-scanned image to a registry WITHOUT rebuilding it, so the digest that was
# scanned is exactly the digest that gets published. Works for multi-arch images: the index,
# every platform image and the build attestations (SBOM, provenance) are all copied.
#
#   scripts/publish-image.sh SOURCE@sha256:DIGEST DEST_REPOSITORY TAG [TAG...]
#
# Prints DEST_REPOSITORY@sha256:DIGEST on success (use it to sign). Logs go to stderr.
# Safe to run again: tags that already point at the same digest are left alone.
set -euo pipefail

log() { echo "publish: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

source_ref="${1:?usage: publish-image.sh SOURCE@sha256:DIGEST DEST_REPOSITORY TAG [TAG...]}"
dest_repo="${2:?missing DEST_REPOSITORY}"
shift 2
[ $# -ge 1 ] || die "give at least one tag"

case "$source_ref" in
  *@sha256:*) ;;
  *) die "the source must be pinned by digest (SOURCE@sha256:...)" ;;
esac
# The last part of the name must not carry a tag (":tag") or digest ("@sha256:...").
case "${dest_repo##*/}" in
  *:* | *@*) die "DEST_REPOSITORY must be a repository without a tag or digest" ;;
esac
case "$dest_repo" in */*) ;; *) die "DEST_REPOSITORY must include the registry host" ;; esac
source_digest="${source_ref##*@}"

copied="false"
for tag in "$@"; do
  existing="$(crane digest "${dest_repo}:${tag}" 2>/dev/null || true)"
  if [ "$existing" = "$source_digest" ]; then
    log "${dest_repo}:${tag} already points at ${source_digest}, nothing to do"
    copied="true"
    continue
  fi
  if [ "$copied" = "false" ]; then
    log "copying ${source_ref} -> ${dest_repo}:${tag}"
    crane copy "$source_ref" "${dest_repo}:${tag}" >&2
    copied="true"
  else
    log "tagging ${dest_repo}@${source_digest} as ${tag}"
    crane tag "${dest_repo}@${source_digest}" "$tag" >&2
  fi
done

# Prove the registry holds exactly what was scanned.
dest_digest="$(crane digest "${dest_repo}@${source_digest}")"
[ "$dest_digest" = "$source_digest" ] || die "digest changed during copy: ${source_digest} -> ${dest_digest}"
echo "${dest_repo}@${dest_digest}"
