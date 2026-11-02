"""Policy tests for .github/workflows/container.yml.

A workflow is code too. These tests read the YAML and check the safety rules this project
promises, so a later edit cannot quietly break them:
  * nothing is pushed, logged in or signed unless the protected-branch gate said yes
  * the scan happens before anything is published
  * every action is pinned to a full commit SHA
  * permissions are minimal
"""

import re
from pathlib import Path

import pytest
import yaml

WORKFLOW = Path(__file__).parent.parent / ".github" / "workflows" / "container.yml"
GATE = "steps.gate.outputs.publish == 'true'"
SHA_PINNED = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")


@pytest.fixture(scope="module")
def workflow():
    # PyYAML reads the key "on" as True, so read it back under both names.
    data = yaml.safe_load(WORKFLOW.read_text())
    data["on"] = data.pop(True, data.get("on"))
    return data


@pytest.fixture(scope="module")
def image_steps(workflow):
    return workflow["jobs"]["image"]["steps"]


def step_index(steps, name_part):
    for index, step in enumerate(steps):
        if name_part in step.get("name", ""):
            return index
    raise AssertionError(f"no step named like {name_part!r}")


PUBLISHING_ACTIONS = (
    "aws-actions/configure-aws-credentials@", "aws-actions/amazon-ecr-login@", "azure/login@",
    "google-github-actions/auth@", "docker/login-action@", "imjasonh/setup-crane@", "sigstore/cosign-installer@",
)
# A shell line that RUNS one of these commands (an "echo" that only mentions them does not count).
PUBLISHING_COMMAND = re.compile(r"^\s*(scripts/release\.sh|scripts/publish-image\.sh|scripts/sign-image\.sh|az acr login|cosign |crane )")


def is_publishing_step(step):
    """Steps that log in to a cloud, copy to a registry or sign."""
    if step.get("uses", "").startswith(PUBLISHING_ACTIONS):
        return True
    return any(PUBLISHING_COMMAND.match(line) for line in step.get("run", "").splitlines())


def test_every_action_is_pinned_to_a_commit_sha(workflow):
    for job_name, job in workflow["jobs"].items():
        for step in job["steps"]:
            if "uses" in step:
                assert SHA_PINNED.match(step["uses"]), f"{job_name}: not pinned to a SHA: {step['uses']}"


def test_default_permissions_are_empty(workflow):
    assert workflow["permissions"] == {}


def test_only_the_image_job_can_get_an_oidc_token(workflow):
    for job_name, job in workflow["jobs"].items():
        allowed = job.get("permissions", {})
        if job_name == "image":
            assert allowed == {"contents": "read", "id-token": "write", "security-events": "write"}
        else:
            assert "id-token" not in allowed


def test_pull_requests_build_and_scan_but_pushes_are_limited_to_known_branches(workflow):
    assert "pull_request" in workflow["on"]
    assert "pull_request_target" not in workflow["on"]  # would run untrusted code with secrets
    branches = workflow["on"]["push"]["branches"]
    assert "**" not in branches and "*" not in branches


def test_the_gate_requires_a_protected_branch(image_steps):
    gate = image_steps[step_index(image_steps, "Should this run publish")]
    assert gate["env"]["REF_PROTECTED"] == "${{ github.ref_protected }}"
    assert '[ "$REF_PROTECTED" = "true" ]' in gate["run"]
    assert '[ "$REF_TYPE" = "branch" ]' in gate["run"]


def test_every_publishing_step_is_behind_the_gate(image_steps):
    publishing = [step for step in image_steps if is_publishing_step(step)]
    assert len(publishing) >= 8, "expected login, publish and sign steps for three registries"
    for step in publishing:
        assert GATE in step.get("if", ""), f"step is not behind the gate: {step.get('name')}"


def test_the_scan_runs_before_anything_is_published(image_steps):
    scan = step_index(image_steps, "Scan every platform")
    first_publish = min(i for i, step in enumerate(image_steps) if is_publishing_step(step))
    assert scan < first_publish
    # and the scan step is not allowed to be skipped or ignored
    assert "continue-on-error" not in image_steps[scan]
    assert "if" not in image_steps[scan]


def test_build_is_multi_arch_and_scanned_by_digest(workflow, image_steps):
    assert "linux/amd64" in workflow["env"]["PLATFORMS"] and "linux/arm64" in workflow["env"]["PLATFORMS"]
    build = image_steps[step_index(image_steps, "Build for every platform")]
    assert build["with"]["platforms"] == "${{ env.PLATFORMS }}"
    remember = image_steps[step_index(image_steps, "Remember the exact image")]
    assert "@$DIGEST" in remember["run"]


def test_checkout_does_not_leave_the_token_on_disk(workflow):
    for job in workflow["jobs"].values():
        for step in job["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                assert step["with"]["persist-credentials"] is False


def test_keyless_signing_identity_is_this_workflow(workflow):
    env = workflow["jobs"]["image"]["env"]
    assert env["CERT_IDENTITY"] == "https://github.com/${{ github.workflow_ref }}"
    assert env["OIDC_ISSUER"] == "https://token.actions.githubusercontent.com"


def test_no_expressions_are_pasted_into_shell_scripts(workflow):
    """${{ }} inside run: can be abused for script injection. Values must go through env: instead."""
    for job in workflow["jobs"].values():
        for step in job["steps"]:
            assert "${{" not in step.get("run", ""), f"expression inside run: in {step.get('name')}"
