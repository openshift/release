"""COS state handoff and cleanup failures, without contacting IBM Cloud."""

import os
from pathlib import Path
import re
import subprocess
import tarfile

import pytest
from generate import GENERATOR_DIR

REGISTRY = GENERATOR_DIR.parents[3] / "step-registry/quay"
DEPLOY = REGISTRY / "deploy-ibmcloud-cos/quay-deploy-ibmcloud-cos-commands.sh"
DEPROVISION = REGISTRY / "deprovision/quay-deprovision-commands.sh"


def _executable(path: Path, script: str) -> None:
    path.write_text(script)
    path.chmod(0o755)


@pytest.fixture
def cos_env(tmp_path: Path) -> dict[str, str]:
    for name in ("state", "shared", "bin", "profile"):
        (tmp_path / name).mkdir()
    state = tmp_path / "state"
    (state / "terraform.tfstate").write_text('{"resources": []}')
    (state / ".terraform.lock.hcl").write_text("# locked provider fixture\n")
    (state / ".terraform").mkdir()
    (state / ".terraform/provider").write_text("provider cache")
    (state / "terraform.tgz").write_text("old archive")
    (tmp_path / "profile/ibmcloud-api-key").write_text("synthetic-test-key")
    return {
        **os.environ,
        "PATH": f"{tmp_path / 'bin'}:{os.environ['PATH']}",
        "TEST_TERRAFORM_DIR": str(state),
        "SHARED_DIR": str(tmp_path / "shared"),
        "CLUSTER_PROFILE_DIR": str(tmp_path / "profile"),
        "QUAY_STORAGE_PROVIDER": "ibmcloud",
        "QUAY_COS_BUCKET": "test-bucket",
        "COS_INSTANCE_NAME": "test-instance",
        "COS_REGION": "us-east",
    }


def _save_state(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    # Load the production function alone and redirect its scratch directory.
    match = re.search(
        r"(?ms)^function save_cos_terraform_state\(\) \{.*?^\}",
        DEPLOY.read_text(),
    )
    assert match is not None
    function = match.group().replace(
        "cd /tmp/QUAY_IBMCLOUD_COS", 'cd "$TEST_TERRAFORM_DIR"'
    )
    return subprocess.run(
        ["bash", "-c", f"set -euo pipefail\n{function}\nsave_cos_terraform_state"],
        env=env, capture_output=True, text=True, timeout=10,
    )


def test_state_archive_preserves_provider_lock(cos_env: dict[str, str]) -> None:
    result = _save_state(cos_env)
    assert result.returncode == 0, result.stderr
    with tarfile.open(Path(cos_env["SHARED_DIR"]) / "terraform.tgz") as archive:
        files = {
            member.name.removeprefix("./"): archive.extractfile(member).read()
            for member in archive.getmembers() if member.isfile()
        }
    assert files == {
        "terraform.tfstate": b'{"resources": []}',
        ".terraform.lock.hcl": b"# locked provider fixture\n",
    }


def test_failed_archive_preserves_previous_state(
    cos_env: dict[str, str], tmp_path: Path,
) -> None:
    assert _save_state(cos_env).returncode == 0
    archive = Path(cos_env["SHARED_DIR"]) / "terraform.tgz"
    previous = archive.read_bytes()
    _executable(tmp_path / "bin/tar", "#!/bin/sh\nexit 28\n")
    assert _save_state(cos_env).returncode != 0
    assert archive.read_bytes() == previous


@pytest.mark.parametrize(
    ("failures", "expected_rc", "attempts"), [(0, 0, 1), (2, 0, 3), (3, 42, 3)]
)
def test_cleanup_reports_final_destroy_result(
    cos_env: dict[str, str], tmp_path: Path,
    failures: int, expected_rc: int, attempts: int,
) -> None:
    assert _save_state(cos_env).returncode == 0
    _executable(tmp_path / "bin/sleep", "#!/bin/sh\nexit 0\n")
    _executable(tmp_path / "bin/terraform", '''#!/bin/bash
set -euo pipefail
case "$1" in
  init) exit 0 ;;
  destroy)
    count=0
    if [[ -f "$SHARED_DIR/attempts" ]]; then
      read -r count < "$SHARED_DIR/attempts"
    fi
    count=$((count + 1))
    echo "$count" > "$SHARED_DIR/attempts"
    if (( count <= TEST_DESTROY_FAILURES )); then exit 42; fi
    exit 0 ;;
  *) exit 99 ;;
esac
''')
    # Execute the production IBM block without unrelated cloud credential reads.
    source = DEPROVISION.read_text()
    start = source.index('if [[ "$QUAY_STORAGE_PROVIDER" == \'ibmcloud\' ]]; then')
    end = source.index('if [[ "$QUAY_STORAGE_PROVIDER" == \'S3CloudFront\' ]]; then')
    result = subprocess.run(
        ["bash", "-c", "set -euo pipefail\n" + source[start:end]],
        env={**cos_env, "TEST_DESTROY_FAILURES": str(failures)}, cwd=tmp_path,
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == expected_rc, result.stdout + result.stderr
    assert int((Path(cos_env["SHARED_DIR"]) / "attempts").read_text()) == attempts
