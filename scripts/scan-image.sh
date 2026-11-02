#!/usr/bin/env bash
#
# Scans every platform of a multi-arch image with Trivy, and fails if any platform has
# vulnerabilities (or leaked secrets) at the chosen severity.
#
#   scripts/scan-image.sh IMAGE@sha256:DIGEST
#
# Inputs (environment):
#   PLATFORMS             default "linux/amd64,linux/arm64"
#   TRIVY_SEVERITY        default "CRITICAL,HIGH"
#   TRIVY_IGNORE_UNFIXED  default "true"  (only fail on problems that have a fix available)
#   SARIF_FILE            default "trivy-results.sarif" (results of the first platform, for GitHub)
# Trivy also reads its own TRIVY_* variables, for example TRIVY_INSECURE=true for a local registry.
set -euo pipefail

image="${1:?usage: scan-image.sh IMAGE@sha256:DIGEST}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
SEVERITY="${TRIVY_SEVERITY:-CRITICAL,HIGH}"
IGNORE_UNFIXED="${TRIVY_IGNORE_UNFIXED:-true}"
SARIF_FILE="${SARIF_FILE:-trivy-results.sarif}"

case "$image" in
  *@sha256:*) ;;
  *) echo "error: scan the image by digest (IMAGE@sha256:...), not by tag" >&2; exit 1 ;;
esac

common=(image --scanners "vuln,secret" --severity "$SEVERITY" --no-progress)
if [ "$IGNORE_UNFIXED" = "true" ]; then
  common+=(--ignore-unfixed)
fi
if [ -f .trivyignore ]; then
  common+=(--ignorefile .trivyignore)
fi

failed=""
first="true"
IFS=',' read -r -a platforms <<<"$PLATFORMS"
for platform in "${platforms[@]}"; do
  platform="${platform// /}"
  [ -n "$platform" ] || continue

  echo "::group::Trivy: $platform"
  if trivy "${common[@]}" --platform "$platform" --exit-code 1 "$image"; then
    echo "PASS: $platform"
  else
    echo "FAIL: $platform"
    failed="$failed $platform"
  fi
  echo "::endgroup::"

  # SARIF report for GitHub's Security tab (first platform only: one report per category).
  if [ "$first" = "true" ]; then
    trivy "${common[@]}" --platform "$platform" --exit-code 0 --format sarif --output "$SARIF_FILE" "$image" ||
      echo "warning: could not write $SARIF_FILE" >&2
    first="false"
  fi
done

if [ -n "$failed" ]; then
  echo "::error::Trivy found $SEVERITY problems in:$failed. The image will NOT be published."
  exit 1
fi
echo "Trivy: no $SEVERITY problems in any platform ($PLATFORMS)."
