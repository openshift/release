"""omr-v3-disconnected-install: one scenario template, variant override, mirror-registry branch."""

from typing import Any

import pytest
from generate import GENERATOR_DIR, build_config, expand_cells

OMR_TEST = "omr-v3-disconnected-install"


def _matrix(branch: str = "master", layout: str = "variant", **job: Any) -> dict[str, Any]:
    job = {"kind": "presubmit", "clouds": ["aws"], "ocp": ["4.22"], "test": OMR_TEST,
           "variant": "omr-v3", **job}
    return {
        "global_defaults": {"repo": "quay/quay"},
        "quay": [{"branch": branch, "layout": layout, "jobs": [job]}],
    }


@pytest.mark.parametrize("branch", ["master", "mirror-registry-3.0"])
def test_omr_keeps_hand_written_names(branch: str) -> None:
    [cell] = expand_cells(_matrix(branch, run_if_changed="^cmd/"))
    assert cell.filename == f"quay-quay-{branch}__omr-v3.yaml"
    config = build_config(cell, GENERATOR_DIR / "templates")
    assert [test["as"] for test in config["tests"]] == ["disconnected-install"]
    assert config["tests"][0]["run_if_changed"] == "^cmd/"
    assert config["images"]["run_if_changed"] == "^cmd/"
    assert config["zz_generated_metadata"] == {
        "branch": branch, "org": "quay", "repo": "quay", "variant": "omr-v3",
    }


def test_omr_renders_only_the_scenario() -> None:
    [cell] = expand_cells(_matrix())
    config = build_config(cell, GENERATOR_DIR / "templates")
    assert "run_if_changed" not in config["images"]
    assert [item["to"] for item in config["images"]["items"]] == ["quay-mirror"]
    assert config["tests"][0]["steps"]["pre"] == [
        {"chain": "quay-aws-ipi-disconnected-omr-v3-provision"}
    ]


def test_variant_defaults_to_derived() -> None:
    job = _matrix()
    del job["quay"][0]["jobs"][0]["variant"]
    [cell] = expand_cells(job)
    assert cell.variant == f"aws-ocp422-{OMR_TEST}"


@pytest.mark.parametrize(
    ("matrix", "match"),
    [
        (_matrix(kind="periodic", cron="daily", source="stable"), "only valid for kind: presubmit"),
        (_matrix(clouds=["gcp"]), "supports only clouds: \\[aws\\]"),
        (_matrix(storage="s3"), "does not support storage"),
        (_matrix(arches=["arm64"]), "does not support arches"),
        (_matrix(layout="base"), "requires layout: variant"),
        (_matrix(variant="OMR_v3"), "variant must be lowercase"),
        (_matrix(branch="mirror-registry-3.0", test="e2e-install"), "only runs tests"),
    ],
)
def test_omr_rejects(matrix: dict[str, Any], match: str) -> None:
    with pytest.raises(ValueError, match=match):
        expand_cells(matrix)


def test_omr_rejects_non_amd64_default_arch() -> None:
    matrix = _matrix()
    matrix["global_defaults"]["arch"] = "arm64"
    with pytest.raises(ValueError, match="supports only arch amd64"):
        expand_cells(matrix)


def test_variant_requires_layout_variant() -> None:
    matrix = _matrix(layout="base", test="e2e-install")
    with pytest.raises(ValueError, match="variant requires layout: variant"):
        expand_cells(matrix)
