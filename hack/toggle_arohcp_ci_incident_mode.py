#!/usr/bin/env python3
"""Toggle ARO-HCP automatic pipeline scheduling and automated retests."""

import argparse
from pathlib import Path

import yaml

CONFIG_PATH = Path("core-services/pipeline-controller/config.yaml")
ARO_HCP = (
    "- org: Azure\n"
    "  repos:\n"
    "    - name: ARO-HCP\n"
    "      branches:\n"
    "        - main\n"
    "      mode:\n"
    "        trigger: "
)

RETESTER_PATH = Path("core-services/retester/_config.yaml")
ARO_HCP_RETESTER = (
    "    Azure:\n"
    "      enabled: true\n"
    "      repos:\n"
    "        ARO-HCP:\n"
    "          enabled: "
)


def unique_mapping(loader, node):
    """Reject duplicate mapping keys rather than silently taking the last one."""
    loader.flatten_mapping(node)
    result = {}
    for key, value in loader.construct_pairs(node):
        if key in result:
            raise ValueError(f"duplicate YAML key: {key}")
        result[key] = value
    return result


def load_unique_yaml(contents):
    """Use a local constructor table without changing PyYAML's global loader."""
    loader = yaml.SafeLoader(contents)
    try:
        loader.yaml_constructors = loader.yaml_constructors.copy()
        loader.yaml_constructors[yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG] = unique_mapping
        return loader.get_single_data()
    finally:
        loader.dispose()


def validate_targets(config: str, retester: str) -> None:
    """Check semantic identity as well as the strict text replacement anchors."""
    pipeline = load_unique_yaml(config)
    organizations = [org for org in pipeline["orgs"] if org["org"] == "Azure"]
    if len(organizations) != 1:
        raise ValueError("expected exactly one Azure pipeline organization")
    repositories = [
        repo for repo in organizations[0]["repos"]
        if repo == "ARO-HCP" or (isinstance(repo, dict) and repo.get("name") == "ARO-HCP")
    ]
    if len(repositories) != 1 or not isinstance(repositories[0], dict):
        raise ValueError("expected exactly one named ARO-HCP pipeline repository")
    if repositories[0].get("branches") != ["main"]:
        raise ValueError("expected ARO-HCP pipeline scope to be main only")
    retries = load_unique_yaml(retester)
    if "ARO-HCP" not in retries["retester"]["orgs"]["Azure"]["repos"]:
        raise ValueError("missing ARO-HCP retester repository")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable"))
    args = parser.parse_args()

    current, desired = ("auto", "manual") if args.action == "enable" else ("manual", "auto")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    retester = RETESTER_PATH.read_text(encoding="utf-8")
    validate_targets(config, retester)
    expected = f"{ARO_HCP}{current}\n"
    if config.count(expected) != 1:
        raise ValueError(f"expected one ARO-HCP main pipeline in {current} mode and the supported YAML layout")

    retests_current, retests_desired = ("true", "false") if args.action == "enable" else ("false", "true")
    expected_retester = f"{ARO_HCP_RETESTER}{retests_current}\n"
    if retester.count(expected_retester) != 1:
        raise ValueError(
            f"expected one ARO-HCP retester entry with enabled: {retests_current} and the supported YAML layout"
        )

    # Validate both configs before writing either; do not alter job definitions.
    RETESTER_PATH.write_text(
        retester.replace(expected_retester, f"{ARO_HCP_RETESTER}{retests_desired}\n", 1),
        encoding="utf-8",
    )
    CONFIG_PATH.write_text(config.replace(expected, f"{ARO_HCP}{desired}\n", 1), encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, TypeError, ValueError, yaml.YAMLError) as exc:
        raise SystemExit(f"Cannot toggle incident mode: {exc}") from exc
