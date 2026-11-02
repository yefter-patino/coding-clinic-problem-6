#!/usr/bin/env bash
#
# End-to-end test of scripts/publish-image.sh and scripts/sign-image.sh with the REAL tools
# (crane + cosign) and two REAL registries running locally. No cloud account is used.
#
# Needs: crane, cosign, jq, and two empty registries. CI starts them as service containers;
# on a laptop with Docker:
#   docker run -d -p 5001:5000 registry:3 && docker run -d -p 5002:5000 registry:3
#   tests/integration/local-registry-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../../scripts"
SRC="${SOURCE_REGISTRY:-localhost:5001}/yefter-demo-app"
DEST="${DEST_REGISTRY:-localhost:5002}/yefter-demo-app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS  $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $description"
    FAIL=$((FAIL + 1))
  fi
}
fails() { ! "$@"; }

for registry in "${SRC%%/*}" "${DEST%%/*}"; do
  if ! crane catalog "$registry" >/dev/null 2>&1; then
    echo "error: no registry answering at $registry (start one, see the top of this file)" >&2
    exit 1
  fi
done

echo "Building a fake 2-platform image with crane (no Docker build needed)..."
for arch in amd64 arm64; do
  mkdir -p "$WORK/$arch/app"
  echo "hello from $arch $RANDOM" >"$WORK/$arch/app/msg"
  tar -cf "$WORK/$arch.tar" -C "$WORK/$arch" .
  crane append -f "$WORK/$arch.tar" -t "$SRC:$arch" 2>/dev/null >/dev/null
  crane mutate --set-platform "linux/$arch" -t "$SRC:$arch" "$SRC:$arch" 2>/dev/null >/dev/null
done
crane index append -m "$SRC:amd64" -m "$SRC:arm64" -t "$SRC:ci" 2>/dev/null >/dev/null
DIGEST="$(crane digest "$SRC:ci")"
SOURCE_REF="$SRC@$DIGEST"
echo "  source: $SOURCE_REF"

echo "publish-image.sh"
OUT="$("$SCRIPTS/publish-image.sh" "$SOURCE_REF" "$DEST" sha-0123456789ab main latest 2>"$WORK/publish.log")"
check "prints the destination pinned by the SAME digest" test "$OUT" = "$DEST@$DIGEST"
for tag in sha-0123456789ab main latest; do
  check "tag $tag points at the scanned digest" test "$(crane digest "$DEST:$tag")" = "$DIGEST"
done
check "both platforms were copied" test "$(crane manifest "$DEST@$DIGEST" | jq '[.manifests[].platform.architecture] | sort | join(",")' -r)" = "amd64,arm64"
"$SCRIPTS/publish-image.sh" "$SOURCE_REF" "$DEST" sha-0123456789ab main latest >/dev/null 2>"$WORK/publish2.log"
check "running it again changes nothing" grep -q "already points at" "$WORK/publish2.log"
check "refuses a source that is not pinned by digest" fails "$SCRIPTS/publish-image.sh" "$SRC:ci" "$DEST" x
check "refuses a destination with a tag" fails "$SCRIPTS/publish-image.sh" "$SOURCE_REF" "$DEST:latest" x

echo "sign-image.sh (key pair + offline signing config, because there is no OIDC here)"
(cd "$WORK" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1)
(cd "$WORK" && mkdir other && cd other && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1)
cosign signing-config create --out "$WORK/offline-signing-config.json" >/dev/null 2>&1
export COSIGN_PASSWORD="" COSIGN_KEY="$WORK/cosign.key" COSIGN_PUBLIC_KEY="$WORK/cosign.pub"
export COSIGN_EXTRA_SIGN_ARGS="--signing-config $WORK/offline-signing-config.json"
export COSIGN_EXTRA_VERIFY_ARGS="--insecure-ignore-tlog=true"
check "signs and verifies the image" "$SCRIPTS/sign-image.sh" "$OUT"
"$SCRIPTS/sign-image.sh" "$OUT" >"$WORK/sign2.log" 2>&1
check "running it again does not sign twice" grep -q "already has a valid signature" "$WORK/sign2.log"
ARM_DIGEST="$(crane manifest "$OUT" | jq -r '.manifests[] | select(.platform.architecture == "arm64") | .digest')"
check "the arm64 image inside is signed too (--recursive)" \
  cosign verify --key "$COSIGN_PUBLIC_KEY" --insecure-ignore-tlog=true "$DEST@$ARM_DIGEST"
check "a different key does NOT verify it" \
  fails cosign verify --key "$WORK/other/cosign.pub" --insecure-ignore-tlog=true "$OUT"
check "the unsigned source copy is NOT verified (signatures are per registry)" \
  fails cosign verify --key "$COSIGN_PUBLIC_KEY" --insecure-ignore-tlog=true "$SOURCE_REF"
check "refuses to sign by tag" fails "$SCRIPTS/sign-image.sh" "$DEST:latest"

echo "release.sh (publish + sign for one registry, exactly as the workflow calls it)"
SOURCE_REF="$SOURCE_REF" TAGS=$'sha-0123456789ab\nmain' "$SCRIPTS/release.sh" "$DEST-release" >"$WORK/release.log" 2>&1
check "the image arrives with the same digest" test "$(crane digest "$DEST-release:main")" = "$DIGEST"
check "and it is signed" cosign verify --key "$COSIGN_PUBLIC_KEY" --insecure-ignore-tlog=true "$DEST-release@$DIGEST"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
