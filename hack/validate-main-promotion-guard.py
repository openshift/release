#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = REPO_ROOT / "ci-operator" / "config"
PROW_CONFIG_DIR = REPO_ROOT / "core-services" / "prow" / "02_config"
INFRA_PERIODICS = REPO_ROOT / "ci-operator" / "jobs" / "infra-periodics.yaml"
AUTO_CONFIG_BRANCHER_JOB = "periodic-prow-auto-config-brancher"
CURRENT_RELEASE_ARG_RE = re.compile(r"^--current-release=(.+)$")

# Repos whose main/master may promote to a release other than current (e.g. gatekeeper 4.6). cri-o is not listed.
MAIN_PROMOTION_IGNORE = {
    "openshift/gatekeeper",
    "openshift/gatekeeper-operator",
    "openshift-priv/gatekeeper",
    "openshift-priv/gatekeeper-operator",
    "openshift/network.offline_migration_sdn_to_ovnk",
    "openshift-priv/network.offline_migration_sdn_to_ovnk",
    "openshift-pipelines/console-plugin",
    "kubev2v/migration-planner",
    "kubev2v/migration-planner-ui-app",
    "openshift-online/ocm-cluster-service",
}


def get_current_release_from_auto_config_brancher():
    """Read current-release from periodic-prow-auto-config-brancher (same source as config-brancher)."""
    if not INFRA_PERIODICS.is_file():
        return None, None
    try:
        with open(INFRA_PERIODICS, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError):
        return None, None
    periodics = data.get("periodics") or []
    for job in periodics:
        if job.get("name") != AUTO_CONFIG_BRANCHER_JOB:
            continue
        spec = job.get("spec") or {}
        containers = spec.get("containers") or []
        for c in containers:
            for arg in c.get("args") or []:
                m = CURRENT_RELEASE_ARG_RE.match(str(arg).strip())
                if m:
                    return m.group(1).strip(), INFRA_PERIODICS
    return None, None


def _load_prow_tide_queries(org: str, repo: str):
    """Return list of tide queries from _prowconfig.yaml, or None if file missing/unreadable."""
    path = PROW_CONFIG_DIR / org / repo / "_prowconfig.yaml"
    if not path.is_file():
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return None
    return (data.get("tide") or {}).get("queries") or []


def has_current_release_branch_in_prow(org: str, repo: str, current_release: str) -> bool:
    """True if repo has openshift-{current_release} or release-{current_release} in includedBranches (development branch)."""
    queries = _load_prow_tide_queries(org, repo)
    if queries is None or not queries:
        return False
    want = {f"openshift-{current_release}", f"release-{current_release}"}
    for q in queries:
        included = q.get("includedBranches") or []
        if any(str(x).strip() in want for x in included):
            return True
    return False


def load_config():
    allowed, source_file = get_current_release_from_auto_config_brancher()
    if not allowed:
        print(
            f"ERROR: Could not determine current release. Set --current-release in {AUTO_CONFIG_BRANCHER_JOB} in {INFRA_PERIODICS.relative_to(REPO_ROOT)}.",
            file=sys.stderr,
        )
        sys.exit(2)
    allowed_priv = f"{allowed}-priv"
    return allowed, allowed_priv, source_file


def get_promotion_targets(config_path):
    try:
        with open(config_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        return None, str(e)
    promotion = data.get("promotion") or {}
    to_list = promotion.get("to") or []
    result = []
    for entry in to_list:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        if name is None:
            continue
        namespace = entry.get("namespace") or "ocp"
        disabled = entry.get("disabled") is True
        result.append((str(name).strip('"'), namespace, disabled))
    return result, None


def is_promotion_fully_disabled(config_path):
    """True if promotion is absent or all promotion.to entries have disabled: true."""
    try:
        with open(config_path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError):
        return False
    to_list = (data.get("promotion") or {}).get("to") or []
    if not to_list:
        return True
    return all(entry.get("disabled") is True for entry in to_list if isinstance(entry, dict))


def main():
    allowed_ocp, allowed_priv, source_file = load_config()

    violations = []
    release_branch_suffixes = (f"-release-{allowed_ocp}.yaml", f"-openshift-{allowed_ocp}.yaml")

    for org_dir in CONFIG_DIR.iterdir():
        if not org_dir.is_dir():
            continue
        org = org_dir.name
        for root, _dirs, files in os.walk(org_dir):
            try:
                path_rel = Path(root).relative_to(CONFIG_DIR)
                parts = path_rel.parts
                repo = parts[1] if len(parts) >= 2 else ""
            except ValueError:
                continue
            in_scope_prow = has_current_release_branch_in_prow(org, repo, allowed_ocp)
            for f in files:
                if "__" in f:
                    continue
                path = Path(root) / f
                rel_path = path.relative_to(REPO_ROOT)
                if f.endswith("-main.yaml") or f.endswith("-master.yaml"):
                    try:
                        org_repo = str(path_rel)
                    except ValueError:
                        org_repo = ""
                    if org_repo in MAIN_PROMOTION_IGNORE:
                        continue
                    targets, err = get_promotion_targets(path)
                    if err:
                        violations.append((str(rel_path), f"Failed to parse: {err}"))
                        continue
                    for name, namespace, disabled in targets:
                        if disabled:
                            continue
                        if namespace == "ocp" and name != allowed_ocp:
                            violations.append((str(rel_path), f"promotes to {namespace}/{name} (main/master must only promote to {allowed_ocp})"))
                        if namespace == "ocp-private" and name != allowed_priv:
                            violations.append((str(rel_path), f"promotes to {namespace}/{name} (main/master must only promote to {allowed_priv})"))
                    continue
                if in_scope_prow and any(f.endswith(s) for s in release_branch_suffixes):
                    has_main_or_master = any(
                        x.endswith("-main.yaml") or x.endswith("-master.yaml") for x in files
                    )
                    if has_main_or_master and not is_promotion_fully_disabled(path):
                        violations.append((str(rel_path), f"release/openshift-{allowed_ocp} config must have promotion disabled (only main/master promote to {allowed_ocp})"))

    if violations:
        print(f"ERROR: Main/master must promote to current release only; release-{allowed_ocp} configs must have promotion disabled.", file=sys.stderr)
        print(f"      main/master -> ocp/{allowed_ocp}, ocp-private/{allowed_priv}. release-{allowed_ocp} / openshift-{allowed_ocp} -> promotion disabled.", file=sys.stderr)
        rel = source_file.relative_to(REPO_ROOT)
        print(f"      Current release from {rel}. Main/master: all repos in ci-operator/config (same as config-brancher). Release-X disabled: only when _prowconfig has openshift-{allowed_ocp} or release-{allowed_ocp} in includedBranches.", file=sys.stderr)
        print("", file=sys.stderr)
        for path, msg in violations:
            print(f"  {path}: {msg}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
