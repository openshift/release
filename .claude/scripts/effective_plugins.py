#!/usr/bin/env python3
"""Resolve effective Prow plugins for an org or org/repo.

Parses the fragment hierarchy under core-services/prow/02_config/ and
prints, as JSON, which plugins and external_plugins are enabled for the
given target and which config level (global/org/repo) is responsible.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

CONFIG_ROOT = Path("core-services/prow/02_config")

# Known irregular mappings between a plugin's name (as it appears in a
# `plugins:` enablement list) and the key it is configured under in the
# global _plugins.yaml behavioral-settings file. Anything not listed here
# is looked up by normalizing hyphens to underscores.
SETTINGS_KEY_ALIASES = {
    "config-updater": "config_updater",
    "owners-label": "owners",
    "verify-owners": "owners",
    "require-matching-label": "require_matching_label",
    "release-note": "release_note",
    "project-manager": "project_manager",
    "branchcleaner": "branch_cleaner",
}


def load_yaml(path: Path):
    if not path.exists():
        return None
    with open(path) as f:
        return yaml.safe_load(f) or {}


def find_repo_root(start: Path) -> Path:
    cur = start.resolve()
    for _ in range(20):
        if (cur / CONFIG_ROOT).is_dir():
            return cur
        if cur.parent == cur:
            break
        cur = cur.parent
    raise SystemExit(f"error: could not locate {CONFIG_ROOT} above {start}")


def rel(repo_root: Path, path: Path) -> str:
    return str(path.relative_to(repo_root))


def settings_key_for(plugin_name: str) -> str:
    return SETTINGS_KEY_ALIASES.get(plugin_name, plugin_name.replace("-", "_"))


def build_org_summary(org_cfg: dict, org: str, org_file_rel: str | None) -> dict:
    org_plugins_block = (org_cfg.get("plugins") or {}).get(org, {})
    org_ext = (org_cfg.get("external_plugins") or {}).get(org, [])
    return {
        "org": org,
        "source_file": org_file_rel,
        "excluded_repos": sorted(org_plugins_block.get("excluded_repos", [])),
        "default_plugins": sorted(org_plugins_block.get("plugins", [])),
        "default_external_plugins": sorted(p.get("name") for p in org_ext),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="org or org/repo, e.g. openshift or openshift/hypershift")
    parser.add_argument("--repo-root", default=".", help="repo root override (default: auto-detect)")
    args = parser.parse_args()

    repo_root = find_repo_root(Path(args.repo_root))
    config_root = repo_root / CONFIG_ROOT

    if "/" in args.target:
        org, repo = args.target.split("/", 1)
    else:
        org, repo = args.target, None

    global_file = config_root / "_plugins.yaml"
    org_file = config_root / org / "_pluginconfig.yaml"
    repo_file = config_root / org / repo / "_pluginconfig.yaml" if repo else None

    global_cfg = load_yaml(global_file) or {}
    org_cfg = load_yaml(org_file)
    repo_cfg = load_yaml(repo_file) if repo_file else None

    warnings: list[str] = []

    result = {
        "target": args.target,
        "org": org,
        "repo": repo,
        "sources": {
            "global": rel(repo_root, global_file) if global_file.exists() else None,
            "org": rel(repo_root, org_file) if org_cfg is not None else None,
            "repo": rel(repo_root, repo_file) if repo_cfg is not None else None,
        },
    }

    if org_cfg is None:
        warnings.append(f"no org-level plugin config found at {org_file}")
        org_cfg = {}

    if repo is None:
        result["org_summary"] = build_org_summary(org_cfg, org, result["sources"]["org"])
        result["warnings"] = warnings
        print(json.dumps(result, indent=2))
        return

    key = f"{org}/{repo}"

    org_plugins_block = (org_cfg.get("plugins") or {}).get(org, {})
    org_plugin_list = org_plugins_block.get("plugins", [])
    excluded_repos = org_plugins_block.get("excluded_repos", [])
    org_ext = (org_cfg.get("external_plugins") or {}).get(org, [])

    if repo_cfg is None:
        warnings.append(f"no repo-level plugin config found at {repo_file}")
        repo_cfg = {}

    repo_plugins_block = (repo_cfg.get("plugins") or {}).get(key, {})
    repo_plugin_list = repo_plugins_block.get("plugins", [])
    repo_ext = (repo_cfg.get("external_plugins") or {}).get(key, [])

    is_excluded = repo in excluded_repos

    plugin_sources: dict[str, dict] = {}

    if is_excluded:
        for p in repo_plugin_list:
            plugin_sources[p] = {
                "source_level": "repo",
                "source_file": result["sources"]["repo"],
                "note": (
                    f"org '{org}' excludes this repo from its default plugin list; "
                    "repo config defines the full plugin set on its own"
                ),
            }
        if not repo_plugin_list:
            warnings.append(
                f"repo '{repo}' is excluded from org '{org}' defaults but has no "
                "repo-level plugin list — it may have no plugins enabled, or the "
                "repo-level fragment is missing/misconfigured"
            )
    else:
        for p in org_plugin_list:
            plugin_sources[p] = {
                "source_level": "org",
                "source_file": result["sources"]["org"],
                "note": f"inherited from org '{org}' default plugin list",
            }
        for p in repo_plugin_list:
            if p in plugin_sources:
                warnings.append(f"plugin '{p}' listed at both org and repo level (redundant)")
            plugin_sources[p] = {
                "source_level": "repo",
                "source_file": result["sources"]["repo"],
                "note": f"added specifically for '{key}' on top of org defaults",
            }

    for name, info in plugin_sources.items():
        info["has_global_behavior_settings"] = settings_key_for(name) in global_cfg

    # external_plugins always cascade (union of org key + org/repo key); no
    # excluded_repos concept applies to them.
    ext_sources: dict[str, dict] = {}
    for p in org_ext:
        name = p.get("name")
        ext_sources[name] = {
            "source_level": "org",
            "source_file": result["sources"]["org"],
            "endpoint": p.get("endpoint"),
            "events": p.get("events", []),
        }
    for p in repo_ext:
        name = p.get("name")
        if name in ext_sources:
            warnings.append(
                f"external plugin '{name}' configured at both org and repo level "
                "— invalid per Prow validation (duplicate plugin name across levels)"
            )
        ext_sources[name] = {
            "source_level": "repo",
            "source_file": result["sources"]["repo"],
            "endpoint": p.get("endpoint"),
            "events": p.get("events", []),
        }

    result["excluded_from_org_defaults"] = is_excluded
    result["enabled_plugins"] = dict(sorted(plugin_sources.items()))
    result["enabled_external_plugins"] = dict(sorted(ext_sources.items()))
    result["warnings"] = warnings

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
