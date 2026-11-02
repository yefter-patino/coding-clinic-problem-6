#!/usr/bin/env bash
#
# Publish + sign for ONE registry. Called once per registry by the workflow.
#
#   scripts/release.sh DEST_REPOSITORY
#
# Inputs (environment, set by the workflow):
#   SOURCE_REF   the scanned image, IMAGE@sha256:DIGEST
#   TAGS         tags to apply, one per line
#   plus what scripts/sign-image.sh needs (CERT_IDENTITY and OIDC_ISSUER for keyless signing)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
dest_repo="${1:?usage: release.sh DEST_REPOSITORY}"
: "${SOURCE_REF:?SOURCE_REF is not set}"
: "${TAGS:?TAGS is not set}"

tags=()
while IFS= read -r tag; do
  [ -n "$tag" ] && tags+=("$tag")
done <<<"$TAGS"

published="$("$HERE/publish-image.sh" "$SOURCE_REF" "$dest_repo" "${tags[@]}")"
"$HERE/sign-image.sh" "$published"

echo "release: published and signed $published (tags: ${tags[*]})"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "| \`$dest_repo\` | \`${published##*@}\` | ${tags[*]} | signed + verified |" >>"$GITHUB_STEP_SUMMARY"
fi
