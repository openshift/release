"""standalone-ha: one weekly AWS periodic rendered from a scenario template, no cluster."""

from typing import Any

import pytest
from generate import (
    GENERATOR_DIR,
    SCENARIO_AS_BY_TEST,
    SCENARIO_KIND_BY_TEST,
    build_config,
    expand_cells,
)

TEST = "standalone-ha"


def _matrix(layout: str = "variant", **job: Any) -> dict[str, Any]:
    job = {"cron": "weekly", "clouds": ["aws"], "ocp": ["4.22"], "test": TEST,
           "variant": "aws-standalone-ha", **job}
    return {
        "global_defaults": {"repo": "quay/quay"},
        "quay": [{"branch": "redhat-3.18", "layout": layout, "jobs": [job]}],
    }


def test_standalone_ha_renders_the_weekly_periodic() -> None:
    [cell] = expand_cells(_matrix())
    assert cell.filename == "quay-quay-redhat-3.18__aws-standalone-ha.yaml"
    config = build_config(cell, GENERATOR_DIR / "templates")
    [test] = config["tests"]
    # Prow names it periodic-ci-quay-quay-redhat-3.18-aws-standalone-ha-e2e.
    assert test["as"] == "e2e"
    assert test["cron"] == "@weekly"
    assert test["steps"] == {
        "cluster_profile": "aws-quay-qe",
        "workflow": "quay-standalone-aws-ha",
    }
    assert [item["to"] for item in config["images"]["items"]] == ["quay-playwright-runner"]
    assert config["zz_generated_metadata"]["variant"] == "aws-standalone-ha"
    rendered = str(config)
    assert "ipi-" not in rendered
    assert "QUAY_OPERATOR" not in rendered


@pytest.mark.parametrize(
    ("matrix", "match"),
    [
        (_matrix(kind="presubmit", cron=None), "only valid for kind: periodic"),
        (_matrix(clouds=["gcp"]), "supports only clouds: \\[aws\\]"),
        (_matrix(storage="s3"), "does not support storage"),
        (_matrix(arches=["arm64"]), "does not support arches"),
        (_matrix(source="nightly"), "does not support source"),
        (_matrix(layout="base"), "requires layout: variant"),
        (_matrix(variant="Standalone_HA"), "variant must be lowercase"),
    ],
)
def test_standalone_ha_rejects(matrix: dict[str, Any], match: str) -> None:
    with pytest.raises(ValueError, match=match):
        expand_cells(matrix)


def test_standalone_ha_rejects_non_amd64_default_arch() -> None:
    matrix = _matrix()
    matrix["global_defaults"]["arch"] = "arm64"
    with pytest.raises(ValueError, match="supports only arch amd64"):
        expand_cells(matrix)


def test_variant_defaults_to_derived() -> None:
    matrix = _matrix()
    del matrix["quay"][0]["jobs"][0]["variant"]
    [cell] = expand_cells(matrix)
    assert cell.variant == f"aws-ocp422-{TEST}"


def test_variant_requires_layout_variant() -> None:
    matrix = _matrix(layout="base", test="e2e-install")
    with pytest.raises(ValueError, match="variant requires layout: variant"):
        expand_cells(matrix)


def test_every_scenario_test_has_a_kind() -> None:
    assert SCENARIO_KIND_BY_TEST.keys() == SCENARIO_AS_BY_TEST.keys()
