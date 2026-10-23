#!/usr/bin/env python3
"""Remove exact duplicate Tide queries, keeping the first occurrence.

Requires ruamel.yaml (python3 -m pip install ruamel.yaml).
By default, scan core-services/prow/02_config. Optional paths select individual
YAML files or directories to search for _prowconfig.yaml files.
Only identical query mappings are removed: list order and all fields matter.
"""

import argparse
from pathlib import Path

from ruamel.yaml import YAML


DEFAULT_CONFIG_DIR = Path(__file__).resolve().parents[2] / "core-services/prow/02_config"


def cleanup(path, dry_run=False):
    """Return the number of duplicate queries found, optionally removing them."""
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    yaml.indent(mapping=2, sequence=2, offset=0)
    with path.open(encoding="utf-8") as stream:
        config = yaml.load(stream)

    if not isinstance(config, dict) or not isinstance(config.get("tide"), dict):
        return 0
    queries = config["tide"].get("queries", [])
    if not isinstance(queries, list):
        raise ValueError(f"{path}: tide.queries must be a list")

    unique = []
    duplicates = []
    for index, query in enumerate(queries):
        if not isinstance(query, dict):
            raise ValueError(f"{path}: tide.queries[{index}] must be a mapping")
        if query in unique:
            duplicates.append(index)
        else:
            unique.append(query)

    if duplicates and not dry_run:
        # Edit the round-trip sequence in place to retain surviving comments.
        for index in reversed(duplicates):
            del queries[index]
        with path.open("w", encoding="utf-8") as stream:
            yaml.dump(config, stream)
    return len(duplicates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths", nargs="*", type=Path, default=[DEFAULT_CONFIG_DIR],
        help="YAML files or directories (default: core-services/prow/02_config)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="report duplicates without changing files",
    )
    args = parser.parse_args()

    files = set()
    for path in args.paths:
        if path.is_dir():
            files.update(p.resolve() for p in path.rglob("_prowconfig.yaml"))
        elif path.is_file():
            files.add(path.resolve())
        else:
            parser.error(f"path does not exist: {path}")

    total = 0
    changed = 0
    for path in sorted(files):
        count = cleanup(path, dry_run=args.dry_run)
        if count:
            action = "Would remove" if args.dry_run else "Removed"
            print(f"{path}: {action} {count} duplicate queries")
            total += count
            changed += 1
    action = "Would remove" if args.dry_run else "Removed"
    print(f"{action} {total} duplicate queries across {changed} files.")


if __name__ == "__main__":
    main()
