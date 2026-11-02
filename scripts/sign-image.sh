#!/usr/bin/env bash
#
# Signs an image (and every platform inside it) with Cosign, then verifies the signature.
#
#   scripts/sign-image.sh IMAGE@sha256:DIGEST
#
# Keyless (default, used in GitHub Actions): no keys to store. Cosign gets a short-lived
# certificate from Sigstore for the workflow's OIDC identity. Needs:
#   CERT_IDENTITY  who must have signed it, e.g. https://github.com/OWNER/REPO/.github/workflows/container.yml@refs/heads/main
#   OIDC_ISSUER    https://token.actions.githubusercontent.com
#
# Key pair (used by the local test): set COSIGN_KEY and COSIGN_PUBLIC_KEY (and COSIGN_PASSWORD).
# COSIGN_EXTRA_SIGN_ARGS / COSIGN_EXTRA_VERIFY_ARGS add extra flags (for example an offline signing config).
#
# Safe to run again: if a valid signature is already there, it does not sign twice.
set -euo pipefail

ref="${1:?usage: sign-image.sh IMAGE@sha256:DIGEST}"
case "$ref" in
  *@sha256:*) ;;
  *) echo "error: sign by digest (IMAGE@sha256:...), never by tag: a tag can be moved after signing" >&2; exit 1 ;;
esac

# shellcheck disable=SC2206  # split the extra flags on spaces on purpose
extra_sign=(${COSIGN_EXTRA_SIGN_ARGS:-})
# shellcheck disable=SC2206
extra_verify=(${COSIGN_EXTRA_VERIFY_ARGS:-})

if [ -n "${COSIGN_KEY:-}" ]; then
  : "${COSIGN_PUBLIC_KEY:?COSIGN_PUBLIC_KEY is needed with COSIGN_KEY}"
  sign_identity=(--key "$COSIGN_KEY")
  verify_identity=(--key "$COSIGN_PUBLIC_KEY")
else
  : "${CERT_IDENTITY:?CERT_IDENTITY is not set (who is allowed to sign)}"
  : "${OIDC_ISSUER:?OIDC_ISSUER is not set}"
  sign_identity=()
  verify_identity=(--certificate-identity "$CERT_IDENTITY" --certificate-oidc-issuer "$OIDC_ISSUER")
fi

verify() {
  cosign verify "${verify_identity[@]}" "${extra_verify[@]}" "$ref" >/dev/null 2>&1
}

if verify; then
  echo "sign: $ref already has a valid signature, not signing again"
  exit 0
fi

echo "sign: signing $ref (and each platform inside it)"
cosign sign --yes --recursive "${sign_identity[@]}" "${extra_sign[@]}" "$ref"

if verify; then
  echo "sign: verified $ref"
else
  echo "error: the signature on $ref could not be verified" >&2
  cosign verify "${verify_identity[@]}" "${extra_verify[@]}" "$ref" >&2 || true
  exit 1
fi
