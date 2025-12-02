#!/usr/bin/env python3
"""Validate GitHub label descriptions don't exceed 100 characters."""

import sys
import yaml

MAX_LENGTH = 100
LABELS_FILE = "core-services/prow/02_config/_labels.yaml"

def main():
    with open(LABELS_FILE, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    errors = []

    # Check default labels
    for label in data.get("default", {}).get("labels", []):
        desc = label.get("description", "")
        if len(desc) > MAX_LENGTH:
            errors.append(f"default/{label['name']}: {len(desc)} chars - {desc}")

    # Check repo-specific labels
    for repo, config in data.get("repos", {}).items():
        for label in config.get("labels", []):
            desc = label.get("description", "")
            if len(desc) > MAX_LENGTH:
                errors.append(f"{repo}/{label['name']}: {len(desc)} chars - {desc}")

    if errors:
        print(f"Labels with descriptions exceeding {MAX_LENGTH} characters:")
        for err in errors:
            print(f"  {err}")
        sys.exit(1)

    print("All label descriptions are within limits.")

if __name__ == "__main__":
    main()
