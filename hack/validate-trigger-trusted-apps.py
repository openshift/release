#!/usr/bin/env python3

import argparse
import os
import sys

import yaml


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Validate that each trigger entry defines trusted_apps and contains "
            "the required GitHub app."
        )
    )
    parser.add_argument(
        "--config-dir",
        default="./core-services/prow/02_config",
        help="Path to prow plugin config directory",
    )
    parser.add_argument(
        "--required-trusted-app",
        default="openshift-merge-bot",
        help="App that must exist in every trigger.trusted_apps",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help=(
            "Auto-fix trigger config by adding missing trusted_apps and creating "
            "repo-level trigger entries when no matching entry exists."
        ),
    )
    return parser.parse_args()


def yaml_files(config_dir):
    for root, _, files in os.walk(config_dir):
        for filename in files:
            if filename.endswith(".yaml"):
                yield os.path.join(root, filename)


def _trigger_has_app(trigger, required_app):
    """Return True if the trigger entry has required_app in trusted_apps."""
    apps = trigger.get("trusted_apps")
    return isinstance(apps, list) and required_app in apps


def _effective_trigger(trigger_entries, org_repo):
    """Mirror Prow TriggerFor: prefer org/repo match, then org-only match.

    Returns the first matching trigger entry (Prow uses first-match semantics)
    or None if nothing matches.
    """
    if "/" in org_repo:
        org = org_repo.split("/", 1)[0]
    else:
        org = org_repo

    for entry in trigger_entries:
        repos = entry.get("repos")
        if isinstance(repos, list) and org_repo in repos:
            return entry

    if "/" in org_repo:
        for entry in trigger_entries:
            repos = entry.get("repos")
            if isinstance(repos, list) and org in repos:
                return entry

    return None


def _collect_trigger_plugin_targets(plugins):
    """Collect plugin keys that require trigger coverage."""
    trigger_plugin_targets = set()
    trigger_enabled_orgs = set()
    if not isinstance(plugins, dict):
        return trigger_plugin_targets

    for org_repo, plugin_cfg in plugins.items():
        if not isinstance(org_repo, str):
            continue
        if not isinstance(plugin_cfg, dict):
            continue
        plugin_list = plugin_cfg.get("plugins")
        if not isinstance(plugin_list, list):
            continue
        if "trigger" in plugin_list:
            trigger_plugin_targets.add(org_repo)
            if "/" not in org_repo:
                trigger_enabled_orgs.add(org_repo)

    for org_repo in plugins:
        if not isinstance(org_repo, str) or "/" not in org_repo:
            continue
        org, _ = org_repo.split("/", 1)
        if org in trigger_enabled_orgs:
            trigger_plugin_targets.add(org_repo)

    return trigger_plugin_targets


def _ensure_trigger_has_app(trigger, required_app, location):
    trusted_apps = trigger.get("trusted_apps")
    if trusted_apps is None:
        trigger["trusted_apps"] = [required_app]
        return True, None
    if not isinstance(trusted_apps, list):
        return (
            False,
            f"{location}: trusted_apps exists but is not a list",
        )
    if required_app not in trusted_apps:
        trusted_apps.append(required_app)
        return True, None
    return False, None


def fix_file(path, required_app):
    """Apply in-place auto-fixes for missing trigger trusted app configuration."""
    try:
        with open(path, encoding="utf-8") as file_handle:
            original_content = file_handle.read()
    except OSError as exc:
        return False, [f"{path}: failed to read file: {exc}"]

    try:
        documents = list(yaml.safe_load_all(original_content))
    except yaml.YAMLError as exc:
        return False, [f"{path}: failed to parse YAML: {exc}"]

    changed = False
    failures = []
    for doc_idx, document in enumerate(documents):
        if not isinstance(document, dict):
            continue

        trigger_plugin_targets = _collect_trigger_plugin_targets(document.get("plugins"))
        if not trigger_plugin_targets:
            continue

        triggers = document.get("triggers")
        if triggers is None:
            triggers = []
            document["triggers"] = triggers
            changed = True
        elif not isinstance(triggers, list):
            failures.append(
                f"{path}: doc {doc_idx + 1}: triggers exists but is not a list"
            )
            continue

        trigger_entries = []
        for trigger_idx, trigger in enumerate(triggers):
            if not isinstance(trigger, dict):
                continue
            trigger_entries.append(trigger)
            trigger_changed, trigger_failure = _ensure_trigger_has_app(
                trigger,
                required_app,
                f"{path}: doc {doc_idx + 1}, trigger {trigger_idx + 1}",
            )
            if trigger_failure:
                failures.append(trigger_failure)
            changed = trigger_changed or changed

        for org_repo in sorted(trigger_plugin_targets):
            effective = _effective_trigger(trigger_entries, org_repo)
            if effective is not None:
                trigger_changed, trigger_failure = _ensure_trigger_has_app(
                    effective,
                    required_app,
                    f"{path}: doc {doc_idx + 1}, effective trigger for plugins[{org_repo}]",
                )
                if trigger_failure:
                    failures.append(trigger_failure)
                changed = trigger_changed or changed
                continue

            new_entry = {"repos": [org_repo], "trusted_apps": [required_app]}
            triggers.append(new_entry)
            trigger_entries.append(new_entry)
            changed = True

    if failures:
        return False, failures

    if not changed:
        return False, []

    try:
        rendered = yaml.safe_dump_all(
            documents, sort_keys=False, default_flow_style=False
        )
        with open(path, "w", encoding="utf-8") as file_handle:
            file_handle.write(rendered)
    except OSError as exc:
        return False, [f"{path}: failed to write file: {exc}"]

    return True, []


def validate_file(path, required_app):
    failures = []
    try:
        with open(path, encoding="utf-8") as file_handle:
            documents = list(yaml.safe_load_all(file_handle))
    except (OSError, yaml.YAMLError) as exc:
        failures.append(f"{path}: failed to parse YAML: {exc}")
        return failures

    for doc_idx, document in enumerate(documents):
        if not isinstance(document, dict):
            continue
        plugins = document.get("plugins")
        triggers = document.get("triggers")

        # Collect org/repo keys that require trigger config coverage.
        # Rules:
        # 1) Any plugins.<org/repo> that explicitly enables trigger.
        # 2) If plugins.<org> enables trigger, then every repo-level plugins key
        #    under that org also requires trigger config coverage, even if that
        #    repo-level key does not list trigger itself.
        trigger_plugin_targets = _collect_trigger_plugin_targets(plugins)

        trigger_entries = []
        if isinstance(triggers, list):
            for trigger_idx, trigger in enumerate(triggers):
                if not isinstance(trigger, dict):
                    failures.append(
                        f"{path}: doc {doc_idx + 1}, trigger {trigger_idx + 1}: "
                        "trigger entry is not a map"
                    )
                    continue

                trigger_entries.append(trigger)

                trusted_apps = trigger.get("trusted_apps")
                if not isinstance(trusted_apps, list) or len(trusted_apps) == 0:
                    failures.append(
                        f"{path}: doc {doc_idx + 1}, trigger {trigger_idx + 1}: "
                        "missing or empty trusted_apps"
                    )
                    continue
                if required_app not in trusted_apps:
                    failures.append(
                        f"{path}: doc {doc_idx + 1}, trigger {trigger_idx + 1}: "
                        f"trusted_apps does not contain {required_app}"
                    )

        # For every repo/org with trigger plugin, require a matching trigger
        # config (using Prow's TriggerFor resolution: repo-level first, then
        # org-level fallback, first-match wins) with the required trusted app.
        for org_repo in sorted(trigger_plugin_targets):
            effective = _effective_trigger(trigger_entries, org_repo)

            if effective is None:
                failures.append(
                    f"{path}: doc {doc_idx + 1}, plugins[{org_repo}] enables trigger "
                    "but no matching triggers.repos entry exists"
                )
                continue

            if not _trigger_has_app(effective, required_app):
                failures.append(
                    f"{path}: doc {doc_idx + 1}, plugins[{org_repo}] enables trigger "
                    f"but effective triggers entry lacks {required_app} in trusted_apps"
                )

    return failures


def main():
    args = parse_args()
    failures = []
    fixed_files = []

    if args.fix:
        for path in sorted(yaml_files(args.config_dir)):
            changed, fix_failures = fix_file(path, args.required_trusted_app)
            failures.extend(fix_failures)
            if changed:
                fixed_files.append(path)

    if failures:
        print(
            f"Failed to auto-fix: {len(failures)} file parsing/writing issue(s) found.",
            file=sys.stderr,
        )
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    for path in sorted(yaml_files(args.config_dir)):
        failures.extend(validate_file(path, args.required_trusted_app))

    if args.fix and fixed_files:
        print(
            f"Auto-fix updated {len(fixed_files)} file(s): {', '.join(fixed_files)}",
            file=sys.stderr,
        )

    if failures:
        print(
            f"Validation failed: {len(failures)} trigger configuration issue(s) found.",
            file=sys.stderr,
        )
        for failure in failures:
            print(failure, file=sys.stderr)
        print("", file=sys.stderr)
        print("How to fix:", file=sys.stderr)
        print(
            "- For every plugins.<org/repo> that enables trigger, add (or update) a matching triggers entry:",
            file=sys.stderr,
        )
        print(
            "- If plugins.<org> enables trigger, every plugins.<org/repo> key under that org must also have matching triggers coverage.",
            file=sys.stderr,
        )
        print(
            "- An org-level triggers entry (repos: [<org>]) covers repos that do not have their own repo-level entry.",
            file=sys.stderr,
        )
        print("  triggers:", file=sys.stderr)
        print("  - repos:", file=sys.stderr)
        print("    - <org> on org level or <org/repo> on repo level", file=sys.stderr)
        print("    trusted_apps:", file=sys.stderr)
        print(f"    - {args.required_trusted_app}", file=sys.stderr)
        print(
            "- Ensure every existing triggers item has trusted_apps and includes the required app.",
            file=sys.stderr,
        )
        return 1

    print(
        f"Validation passed: all trigger trusted_apps include {args.required_trusted_app}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
