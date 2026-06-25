#!/usr/bin/env python3
"""Scaffold a new step-registry ref step (ref YAML + commands.sh)."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
SUBDIR_RE = re.compile(r"^[a-z0-9][a-z0-9/-]*$")


def repo_root_from_script() -> Path:
    """Return the openshift/release repository root."""
    return Path(__file__).resolve().parents[2]


def render_ref_yaml(
    name: str,
    from_alias: str,
    documentation: str,
    image_namespace: str | None,
    image_name: str | None,
    image_tag: str | None,
) -> str:
    """Render the ref YAML body for a new step."""
    doc = documentation or f"TODO: document what the {name} step does."
    if image_namespace and image_name and image_tag:
        from_block = (
            f"  from_image:\n"
            f"    namespace: {image_namespace}\n"
            f"    name: {image_name}\n"
            f"    tag: {image_tag}"
        )
    else:
        from_block = f"  from: {from_alias}"
    return f"""ref:
  as: {name}
{from_block}
  commands: {name}-commands.sh
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
  documentation: |-
    {doc}
"""


def render_commands_sh(name: str) -> str:
    """Render the commands shell script body for a new step."""
    return f"""#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# TODO: implement {name} step logic.
"""


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Scaffold step-registry ref YAML and commands script.",
    )
    parser.add_argument(
        "--name",
        required=True,
        help="Step ref name (as: field), e.g. mycomponent-do-thing",
    )
    parser.add_argument(
        "--subdir",
        required=True,
        help="Directory under ci-operator/step-registry/, e.g. myorg/do/thing",
    )
    parser.add_argument(
        "--from",
        dest="from_alias",
        default="cli",
        help="ci-operator base image alias when not using --from-image-* (default: cli)",
    )
    parser.add_argument(
        "--from-image-namespace",
        help="ImageStream namespace for from_image block",
    )
    parser.add_argument(
        "--from-image-name",
        help="ImageStream name for from_image block",
    )
    parser.add_argument(
        "--from-image-tag",
        help="ImageStream tag for from_image block",
    )
    parser.add_argument(
        "--documentation",
        default="",
        help="One-line documentation for the ref YAML",
    )
    parser.add_argument(
        "--preview",
        action="store_true",
        help="Print generated file bodies to stderr during dry-run",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Create files (default: dry-run)",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repository root (default: auto-detect)",
    )
    return parser.parse_args()


def validate(name: str, subdir: str, args: argparse.Namespace) -> None:
    """Validate CLI inputs before scaffolding files."""
    if not NAME_RE.match(name):
        raise ValueError(f"invalid --name {name!r}; use lowercase letters, digits, hyphens")
    if name.endswith("-step"):
        raise ValueError(
            f"invalid --name {name!r}; do not use a '-step' suffix (ci-tools rejects matching commands paths)"
        )
    if not SUBDIR_RE.match(subdir):
        raise ValueError(f"invalid --subdir {subdir!r}")
    if subdir.endswith("/"):
        raise ValueError("--subdir must not end with /")
    image_fields = (args.from_image_namespace, args.from_image_name, args.from_image_tag)
    if any(image_fields) and not all(image_fields):
        raise ValueError("set all of --from-image-namespace, --from-image-name, and --from-image-tag together")


def main() -> int:
    """CLI entrypoint."""
    args = parse_args()
    try:
        validate(args.name, args.subdir, args)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    repo_root = args.repo_root or repo_root_from_script()
    step_dir = repo_root / "ci-operator" / "step-registry" / args.subdir
    ref_path = step_dir / f"{args.name}-ref.yaml"
    cmd_path = step_dir / f"{args.name}-commands.sh"
    ref_body = render_ref_yaml(
        args.name,
        args.from_alias,
        args.documentation,
        args.from_image_namespace,
        args.from_image_name,
        args.from_image_tag,
    )
    cmd_body = render_commands_sh(args.name)

    if ref_path.exists() or cmd_path.exists():
        print("error: target files already exist:", file=sys.stderr)
        for path in (ref_path, cmd_path):
            if path.exists():
                print(f"  {path.relative_to(repo_root)}", file=sys.stderr)
        return 1

    rel_ref = ref_path.relative_to(repo_root)
    rel_cmd = cmd_path.relative_to(repo_root)
    print(f"ref:      {rel_ref}", file=sys.stderr)
    print(f"commands: {rel_cmd}", file=sys.stderr)

    if args.preview:
        print("\n--- ref yaml ---", file=sys.stderr)
        print(ref_body, end="", file=sys.stderr)
        print("--- commands.sh ---", file=sys.stderr)
        print(cmd_body, end="", file=sys.stderr)

    if not args.write:
        print("(dry run — pass --write to create files)", file=sys.stderr)
        return 0

    step_dir.mkdir(parents=True, exist_ok=True)
    ref_path.write_text(ref_body, encoding="utf-8")
    cmd_path.write_text(cmd_body, encoding="utf-8")
    cmd_path.chmod(0o755)
    print(f"\nCreated {rel_ref} and {rel_cmd}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
