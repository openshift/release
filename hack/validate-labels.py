#!/usr/bin/env python3
"""Validate GitHub label configuration."""

import sys
import yaml

MAX_LENGTH = 100
LABELS_FILE = "core-services/prow/02_config/_labels.yaml"

def label_names(labels):
    return {label["name"] for label in labels}

def main():
    with open(LABELS_FILE, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    errors = []

    default_labels = data.get("default", {}).get("labels", [])
    default_names = label_names(default_labels)

    # Check default labels
    for label in default_labels:
        desc = label.get("description", "")
        if len(desc) > MAX_LENGTH:
            errors.append(f"default/{label['name']}: description is {len(desc)} chars (max {MAX_LENGTH})")

    # Check org-level labels
    for org, config in data.get("orgs", {}).items():
        org_labels = config.get("labels", [])
        for label in org_labels:
            name = label["name"]
            desc = label.get("description", "")
            if len(desc) > MAX_LENGTH:
                errors.append(f"orgs/{org}/{name}: description is {len(desc)} chars (max {MAX_LENGTH})")
            if name in default_names:
                errors.append(f"orgs/{org}/{name}: duplicates default label")

    # Check repo-specific labels
    for repo, config in data.get("repos", {}).items():
        org = repo.split("/")[0] if "/" in repo else None
        org_names = label_names(data.get("orgs", {}).get(org, {}).get("labels", [])) if org else set()

        for label in config.get("labels", []):
            name = label["name"]
            desc = label.get("description", "")
            if len(desc) > MAX_LENGTH:
                errors.append(f"repos/{repo}/{name}: description is {len(desc)} chars (max {MAX_LENGTH})")
            if name in default_names:
                errors.append(f"repos/{repo}/{name}: duplicates default label")
            if name in org_names:
                errors.append(f"repos/{repo}/{name}: duplicates org-level label from {org}")

    if errors:
        print("Label validation errors:")
        for err in errors:
            print(f"  {err}")
        sys.exit(1)

    print("All labels are valid.")

if __name__ == "__main__":
    main()
