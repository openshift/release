"""e2e-chainsaw: quay-operator repo target, both suites in one job, odf-only storage."""

from pathlib import Path
from typing import Any

import pytest
from conftest import FIXTURES_DIR
from generate import (
    GENERATOR_DIR,
    _check_configs,
    _write_configs,
    dump_config,
    expand_cells,
    generate_all,
)

CHAINSAW_DIR = FIXTURES_DIR / "chainsaw"
CHAINSAW_NAME = "quay-quay-operator-redhat-5.0__aws-ocp50-e2e-chainsaw.yaml"
CHAINSAW_FIXTURE = FIXTURES_DIR / f"{CHAINSAW_NAME}.in"
INSTALL_NAME = "quay-quay-redhat-5.0__aws-ocp50-e2e-install.yaml"


def _results() -> list[tuple[list[Any], str, dict[str, Any]]]:
    results, _retired = generate_all(
        matrix_path=CHAINSAW_DIR / "matrix.yaml.in", templates_dir=GENERATOR_DIR / "templates"
    )
    return results


def _chainsaw_config() -> dict[str, Any]:
    return {filename: config for _group, filename, config in _results()}[CHAINSAW_NAME]


def _matrix(**job: Any) -> dict[str, Any]:
    job = {"cron": "weekly", "source": "nightly", "clouds": ["aws"], "ocp": ["5.0"],
           "test": "e2e-chainsaw", **job}
    return {
        "global_defaults": {"repo": "quay/quay"},
        "quay": [{"branch": "redhat-5.0", "jobs": [job]}],
    }


def test_chainsaw_targets_quay_operator_and_writes_sibling_dir(tmp_path: Path) -> None:
    results = _results()
    out = tmp_path / "quay"
    _write_configs(results, out, dry_run=False)
    assert (out / INSTALL_NAME).exists()
    assert (tmp_path / "quay-operator" / CHAINSAW_NAME).exists()
    assert not (out / CHAINSAW_NAME).exists()
    assert _check_configs(results, [], out) == 0
    (tmp_path / "quay-operator" / CHAINSAW_NAME).unlink()
    assert _check_configs(results, [], out) == 1

    metadata = _chainsaw_config()["zz_generated_metadata"]
    assert metadata == {
        "branch": "redhat-5.0",
        "org": "quay",
        "repo": "quay-operator",
        "variant": "aws-ocp50-e2e-chainsaw",
    }


def test_chainsaw_runs_both_suites_in_one_job() -> None:
    tests = _chainsaw_config()["tests"]
    assert [test["as"] for test in tests] == ["aws-odf-nightly"]
    assert tests[0]["steps"]["env"]["CHAINSAW_SUITE"] == "all"
    assert tests[0]["cron"] == "@weekly"
    assert tests[0]["timeout"] == "4h0m0s"


def test_chainsaw_uses_aws_quay_qe_cluster_profile() -> None:
    for test in _chainsaw_config()["tests"]:
        assert test["steps"]["cluster_profile"] == "aws-quay-qe"


def test_chainsaw_rejects_presubmit() -> None:
    with pytest.raises(ValueError, match="e2e-chainsaw is only valid for kind: periodic"):
        expand_cells(_matrix(kind="presubmit"))


def test_chainsaw_rejects_non_odf_storage() -> None:
    with pytest.raises(ValueError, match="storage must be 'odf' for test e2e-chainsaw"):
        expand_cells(_matrix(storage="s3"))


def test_chainsaw_rejects_fips() -> None:
    with pytest.raises(ValueError, match="fips is not supported for test e2e-chainsaw"):
        expand_cells(_matrix(fips=True))


def test_check_finds_retired_file_in_sibling_dir_without_active_cell(tmp_path: Path) -> None:
    out = tmp_path / "quay"
    out.mkdir()
    (tmp_path / "quay-operator").mkdir()
    (tmp_path / "quay-operator" / CHAINSAW_NAME).write_text("foo: bar\n")
    assert _check_configs([], [CHAINSAW_NAME], out) == 1


def test_golden_chainsaw_bytes() -> None:
    assert dump_config(_chainsaw_config()) == CHAINSAW_FIXTURE.read_text()
