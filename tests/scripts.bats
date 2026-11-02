#!/usr/bin/env bats
# Unit tests for the helper scripts. Trivy is faked, so no network or images are needed.

SCRIPTS="$BATS_TEST_DIRNAME/../scripts"

setup() {
  export MOCK_DIR="$BATS_TEST_TMPDIR"
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  export GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
  unset MUTABLE_TAGS DEFAULT_BRANCH MOCK_FAIL_PLATFORMS PLATFORMS TRIVY_SEVERITY TRIVY_IGNORE_UNFIXED
  cd "$BATS_TEST_TMPDIR"
}

# ------------------------------------------------------------------ image-tags.sh
@test "main gets a commit tag, the branch tag and latest" {
  GITHUB_REF_NAME=main run "$SCRIPTS/image-tags.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'sha-0123456789ab\nmain\nlatest')" ]
}

@test "a release branch gets a cleaned branch tag but not latest" {
  GITHUB_REF_NAME="release/2026.10 Hotfix" run "$SCRIPTS/image-tags.sh"
  [ "$output" = "$(printf 'sha-0123456789ab\nrelease-2026.10-hotfix')" ]
}

@test "MUTABLE_TAGS=false gives only the commit tag (for immutable registries)" {
  MUTABLE_TAGS=false GITHUB_REF_NAME=main run "$SCRIPTS/image-tags.sh"
  [ "$output" = "sha-0123456789ab" ]
}

@test "the default branch name comes from DEFAULT_BRANCH" {
  DEFAULT_BRANCH=trunk GITHUB_REF_NAME=trunk run "$SCRIPTS/image-tags.sh"
  [[ "$output" == *latest* ]]
  DEFAULT_BRANCH=trunk GITHUB_REF_NAME=main run "$SCRIPTS/image-tags.sh"
  [[ "$output" != *latest* ]]
}

@test "a branch literally called latest cannot steal the latest tag" {
  GITHUB_REF_NAME=latest run "$SCRIPTS/image-tags.sh"
  [ "$output" = "sha-0123456789ab" ]
}

@test "a bad commit id is refused" {
  GITHUB_SHA="not-a-sha" GITHUB_REF_NAME=main run "$SCRIPTS/image-tags.sh"
  [ "$status" -eq 1 ]
}

# ------------------------------------------------------------------ scan-image.sh
IMAGE="localhost:5000/yefter-demo-app@sha256:1111111111111111111111111111111111111111111111111111111111111111"

@test "every platform is scanned for vulnerabilities and secrets, by digest" {
  run "$SCRIPTS/scan-image.sh" "$IMAGE"
  [ "$status" -eq 0 ]
  grep -q -- "--platform linux/amd64 --exit-code 1 $IMAGE" trivy-calls.log
  grep -q -- "--platform linux/arm64 --exit-code 1 $IMAGE" trivy-calls.log
  grep -q -- "--scanners vuln,secret --severity CRITICAL,HIGH" trivy-calls.log
  grep -q -- "--ignore-unfixed" trivy-calls.log
}

@test "one bad platform fails the scan, but all platforms are still scanned" {
  MOCK_FAIL_PLATFORMS=linux/amd64 run "$SCRIPTS/scan-image.sh" "$IMAGE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: linux/amd64"* ]]
  [[ "$output" == *"PASS: linux/arm64"* ]]
  [[ "$output" == *"will NOT be published"* ]]
}

@test "severity, platforms and unfixed handling come from the environment" {
  PLATFORMS="linux/arm64" TRIVY_SEVERITY=CRITICAL TRIVY_IGNORE_UNFIXED=false run "$SCRIPTS/scan-image.sh" "$IMAGE"
  [ "$status" -eq 0 ]
  run grep -q -- "linux/amd64" trivy-calls.log
  [ "$status" -ne 0 ]
  grep -q -- "--severity CRITICAL " trivy-calls.log
  run grep -c -- "--ignore-unfixed" trivy-calls.log
  [ "$output" = "0" ]
}

@test "a SARIF report is written for GitHub's Security tab" {
  run "$SCRIPTS/scan-image.sh" "$IMAGE"
  [ -s trivy-results.sarif ]
}

@test ".trivyignore is used when present" {
  echo "CVE-2026-0001" >.trivyignore
  run "$SCRIPTS/scan-image.sh" "$IMAGE"
  grep -q -- "--ignorefile .trivyignore" trivy-calls.log
}

@test "scanning by tag is refused (the tag could change after the scan)" {
  run "$SCRIPTS/scan-image.sh" "localhost:5000/yefter-demo-app:latest"
  [ "$status" -eq 1 ]
  [ ! -e trivy-calls.log ]
}

# ------------------------------------------------------------------ input checks (no tools needed)
@test "publish-image.sh refuses bad input before calling crane" {
  run "$SCRIPTS/publish-image.sh" "$IMAGE" "repo-without-host" sha-1
  [ "$status" -eq 1 ]
  run "$SCRIPTS/publish-image.sh" "$IMAGE" "registry.example.com/app"
  [ "$status" -eq 1 ]
}

@test "sign-image.sh needs to know which identity may sign (keyless mode)" {
  unset CERT_IDENTITY OIDC_ISSUER COSIGN_KEY
  run "$SCRIPTS/sign-image.sh" "$IMAGE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CERT_IDENTITY is not set"* ]]
}
