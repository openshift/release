#!/usr/bin/env python3
"""
Migrate slack_reporter configs from .config.prowgen files into per-test
reporter_config fields in ci-operator config YAML files.

This is part of the .config.prowgen deprecation. PR #5149 in ci-tools added
support for per-test reporter_config in ci-operator configs, with .config.prowgen
slack_reporter as fallback. This script performs the migration so the fallback
can eventually be removed.

Usage:
    python3 migrate_slack_to_inline.py [--dry-run]
"""

import argparse
import glob
import os
import re
import sys

from ruamel.yaml import YAML

CONFIG_DIR = "ci-operator/config"

IMAGES_TEST_NAME = "images"


def parse_config_filename(filepath):
    """Extract org, repo, branch, variant from ci-operator config filename.

    Filename format: {org}-{repo}-{branch}.yaml or {org}-{repo}-{branch}__{variant}.yaml
    Path format: ci-operator/config/{org}/{repo}/{filename}
    """
    parts = filepath.split("/")
    org = parts[-3]
    repo = parts[-2]
    basename = os.path.splitext(parts[-1])[0]

    variant = ""
    if "__" in basename:
        name_part, variant = basename.split("__", 1)
    else:
        name_part = basename

    prefix = f"{org}-{repo}-"
    if name_part.startswith(prefix):
        branch = name_part[len(prefix):]
    else:
        branch = name_part

    return org, repo, branch, variant


def construct_full_job_name(prefix, org, repo, branch, test_name, variant):
    """Construct a full prow job name."""
    if variant:
        full_test = f"{variant}-{test_name}"
    else:
        full_test = test_name
    return f"{prefix}-ci-{org}-{repo}-{branch}-{full_test}"


def matches_slack_reporter_per_jobtype(slack_config, test_name, org, repo, branch, variant, job_types):
    """Check which job types match this slack_reporter config.

    Returns a set of matching job type prefixes (e.g., {"pull", "periodic"}).
    Returns empty set if variant is excluded or test name doesn't match.
    """
    excluded_variants = slack_config.get("excluded_variants") or []
    if excluded_variants and variant in excluded_variants:
        return set()

    job_names = slack_config.get("job_names") or []
    job_patterns = slack_config.get("job_name_patterns") or []
    name_matches = False
    if job_names and test_name in job_names:
        name_matches = True
    if not name_matches:
        for pattern in job_patterns:
            if re.search(pattern, test_name):
                name_matches = True
                break
    if not name_matches:
        return set()

    excluded_patterns = slack_config.get("excluded_job_patterns") or []
    matching_types = set()
    for prefix in job_types:
        full_name = construct_full_job_name(prefix, org, repo, branch, test_name, variant)
        excluded = False
        for pattern in excluded_patterns:
            if re.search(pattern, full_name):
                excluded = True
                break
        if not excluded:
            matching_types.add(prefix)

    return matching_types


def get_test_job_types(test):
    """Determine what job types a test generates."""
    has_cron = "cron" in test and test["cron"]
    has_interval = "interval" in test and test["interval"]
    is_periodic = has_cron or has_interval
    is_postsubmit = test.get("postsubmit", False)
    has_presubmit = test.get("presubmit", False)

    types = set()
    if is_periodic:
        types.add("periodic")
        if has_presubmit:
            types.add("pull")
    elif is_postsubmit:
        types.add("branch")
        types.add("pull")
    else:
        types.add("pull")

    return types


def slack_reporter_matches_images(slack_config):
    """Check if a slack_reporter entry could match the 'images' test name."""
    job_names = slack_config.get("job_names") or []
    if IMAGES_TEST_NAME in job_names:
        return True
    for pattern in (slack_config.get("job_name_patterns") or []):
        if re.search(pattern, IMAGES_TEST_NAME):
            return True
    return False


def build_reporter_config(slack_config, needs_report_presubmit=False):
    """Build a reporter_config dict for a ci-operator test.

    Always includes job_states_to_report and report_template exactly as they
    appear in the source config to avoid ordering or default-fill-in diffs.
    """
    config = {"channel": slack_config["channel"]}

    states = slack_config.get("job_states_to_report", [])
    if states:
        config["job_states_to_report"] = list(states)

    template = slack_config.get("report_template", "")
    if template:
        config["report_template"] = template

    if needs_report_presubmit:
        config["report_presubmit"] = True

    return config


def process_config_dir(repo_dir, slack_reporters, dry_run=False):
    """Process all ci-operator config files in a repo directory against slack reporters.

    Returns (modified_count, warnings).
    """
    config_files = sorted(glob.glob(os.path.join(repo_dir, "*.yaml")))
    if not config_files:
        return 0, []

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096

    images_slack_configs = [s for s in slack_reporters if slack_reporter_matches_images(s)]
    test_slack_configs = [s for s in slack_reporters if not slack_reporter_matches_images(s)]

    modified_count = 0
    warnings = []

    for config_path in config_files:
        org, repo, branch, variant = parse_config_filename(config_path)

        with open(config_path) as f:
            config = yaml.load(f)

        if not config:
            continue

        file_modified = False

        if config.get("images") and images_slack_configs and not config["images"].get("reporter_config"):
            reporter = build_reporter_config(images_slack_configs[0])
            config["images"]["reporter_config"] = reporter
            file_modified = True

        if "tests" not in config:
            if file_modified:
                modified_count += 1
                if not dry_run:
                    with open(config_path, "w") as f:
                        yaml.dump(config, f)
            continue

        for test in config["tests"]:
            test_name = test.get("as", "")
            if not test_name:
                continue

            if test.get("reporter_config"):
                continue

            job_types = get_test_job_types(test)

            for slack_config in test_slack_configs:
                matching_types = matches_slack_reporter_per_jobtype(
                    slack_config, test_name, org, repo, branch, variant, job_types
                )

                if not matching_types:
                    continue

                is_periodic_with_presubmit = (
                    "periodic" in job_types and "pull" in job_types
                )

                if matching_types == job_types:
                    needs_report_presubmit = is_periodic_with_presubmit
                    reporter = build_reporter_config(slack_config, needs_report_presubmit)
                    test["reporter_config"] = reporter
                    file_modified = True
                elif is_periodic_with_presubmit:
                    if "periodic" in matching_types and "pull" not in matching_types:
                        reporter = build_reporter_config(slack_config, needs_report_presubmit=False)
                        test["reporter_config"] = reporter
                        file_modified = True
                    elif "pull" in matching_types and "periodic" not in matching_types:
                        warnings.append(
                            f"  WARNING: {config_path} test '{test_name}': "
                            f"slack only for presubmit of periodic+presubmit test, cannot represent in new format"
                        )
                else:
                    if len(job_types) > 1 and matching_types != job_types:
                        warnings.append(
                            f"  WARNING: {config_path} test '{test_name}': "
                            f"partial job type match {matching_types} vs {job_types}, adding config anyway"
                        )
                    reporter = build_reporter_config(slack_config)
                    test["reporter_config"] = reporter
                    file_modified = True

                break

        if file_modified:
            modified_count += 1
            if not dry_run:
                with open(config_path, "w") as f:
                    yaml.dump(config, f)

    return modified_count, warnings


def remove_slack_reporter(prowgen_path, prowgen_data, dry_run=False):
    """Remove migrated slack_reporter entries from .config.prowgen.

    Deletes the file if nothing remains.
    """
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096

    del prowgen_data["slack_reporter"]

    remaining_keys = [k for k in prowgen_data if prowgen_data[k]]
    if not remaining_keys:
        if not dry_run:
            os.remove(prowgen_path)
        return "deleted"
    else:
        if not dry_run:
            with open(prowgen_path, "w") as f:
                yaml.dump(prowgen_data, f)
        reasons = list(remaining_keys)
        return f"kept ({', '.join(reasons)})"


def main():
    parser = argparse.ArgumentParser(description="Migrate slack_reporter from .config.prowgen to inline reporter_config")
    parser.add_argument("--dry-run", action="store_true", help="Don't modify files, just report what would change")
    args = parser.parse_args()

    if not os.path.isdir(CONFIG_DIR):
        print(f"ERROR: {CONFIG_DIR} not found. Run from the release repo root.", file=sys.stderr)
        sys.exit(1)

    yaml = YAML()

    # Find all org-level .config.prowgen files with slack_reporter
    org_level_files = sorted(glob.glob(os.path.join(CONFIG_DIR, "*/.config.prowgen")))
    org_slack_configs = {}
    for org_prowgen_path in org_level_files:
        with open(org_prowgen_path) as f:
            data = yaml.load(f)
        if data and data.get("slack_reporter"):
            org_dir = os.path.dirname(org_prowgen_path)
            org_name = os.path.basename(org_dir)
            org_slack_configs[org_name] = {
                "path": org_prowgen_path,
                "data": data,
                "reporters": list(data["slack_reporter"]),
            }

    total_modified = 0
    total_prowgen_removed = 0
    total_prowgen_updated = 0

    # Process org-level configs: apply to all repos under the org
    for org_name, org_info in sorted(org_slack_configs.items()):
        print(f"\n=== Org-level: {org_name} ===")
        org_dir = os.path.join(CONFIG_DIR, org_name)
        repo_dirs = sorted([
            d for d in glob.glob(os.path.join(org_dir, "*"))
            if os.path.isdir(d)
        ])

        for repo_dir in repo_dirs:
            repo_name = os.path.basename(repo_dir)
            modified, warnings = process_config_dir(
                repo_dir, org_info["reporters"], dry_run=args.dry_run
            )
            for w in warnings:
                print(w)
            if modified:
                print(f"  {org_name}/{repo_name}: modified {modified} config files")
                total_modified += modified

        result = remove_slack_reporter(org_info["path"], org_info["data"], dry_run=args.dry_run)
        print(f"  .config.prowgen: {result}")
        if result == "deleted":
            total_prowgen_removed += 1
        else:
            total_prowgen_updated += 1

    # Process repo-level configs
    prowgen_files = sorted(glob.glob(os.path.join(CONFIG_DIR, "*/*/.config.prowgen")))
    for prowgen_path in prowgen_files:
        with open(prowgen_path) as f:
            data = yaml.load(f)

        if not data or not data.get("slack_reporter"):
            continue

        repo_dir = os.path.dirname(prowgen_path)
        rel_path = os.path.relpath(repo_dir, CONFIG_DIR)
        org_name = rel_path.split("/")[0]

        # Skip repos under orgs that already have org-level slack config
        if org_name in org_slack_configs:
            continue

        slack_reporters = list(data["slack_reporter"])
        print(f"\n--- {rel_path} ({len(slack_reporters)} reporter(s)) ---")

        modified, warnings = process_config_dir(
            repo_dir, slack_reporters, dry_run=args.dry_run
        )
        for w in warnings:
            print(w)
        total_modified += modified
        print(f"  Modified {modified} config files")

        result = remove_slack_reporter(prowgen_path, data, dry_run=args.dry_run)
        print(f"  .config.prowgen: {result}")
        if result == "deleted":
            total_prowgen_removed += 1
        else:
            total_prowgen_updated += 1

    print(f"\n{'DRY RUN ' if args.dry_run else ''}SUMMARY:")
    print(f"  Config files modified: {total_modified}")
    print(f"  .config.prowgen files deleted: {total_prowgen_removed}")
    print(f"  .config.prowgen files updated (kept other config): {total_prowgen_updated}")


if __name__ == "__main__":
    main()
