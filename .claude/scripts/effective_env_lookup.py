#!/usr/bin/env python3
"""Find CI config(s) for a job and resolve effective environment variables."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def repo_root_from_script() -> Path:
    """Return the openshift/release repository root."""
    return Path(__file__).resolve().parents[2]


def job_as_pattern(job_name: str) -> re.Pattern[str]:
    """Build a regex that matches a tests.as field for the given job name."""
    return re.compile(rf"^\s*-?\s*as:\s*{re.escape(job_name)}\s*$", re.MULTILINE)


def parse_versions(raw: str | None) -> list[str]:
    """Parse comma- or space-separated release version filters."""
    if not raw:
        return []
    return [part.strip() for part in re.split(r"[\s,]+", raw) if part.strip()]


def iter_config_files(config_dir: Path, component: str | None) -> list[Path]:
    """List config YAML paths, optionally narrowed by component."""
    if component and "/" in component:
        base = config_dir / component
        if not base.is_dir():
            return []
        return sorted(base.rglob("*.yaml"))
    paths = sorted(config_dir.rglob("*.yaml"))
    if not component:
        return paths
    needle = component.lower()
    return [path for path in paths if needle in str(path).lower()]


def version_matches(path: Path, versions: list[str]) -> bool:
    """Return True when the config filename matches an exact release version."""
    if not versions:
        return True
    name = path.name
    return any(
        f"release-{version}." in name or f"release-{version}__" in name
        for version in versions
    )


def find_configs(
    config_dir: Path,
    job_name: str,
    component: str | None,
    versions: list[str],
    include_priv: bool,
) -> list[Path]:
    """Find ci-operator config files that define the given job."""
    pattern = job_as_pattern(job_name)
    matches: list[Path] = []
    for path in iter_config_files(config_dir, component):
        if not include_priv and "/openshift-priv/" in str(path):
            continue
        if not version_matches(path, versions):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if pattern.search(text):
            matches.append(path)
    return matches


def truncate(value: str, limit: int = 80) -> str:
    """Truncate long values for table output."""
    if len(value) <= limit:
        return value
    return value[: limit - 3] + "..."


def result_signature(data: dict) -> str:
    """Build a stable signature for deduplicating identical resolver output."""
    payload = {
        "workflow": data.get("workflow"),
        "filter": data.get("filter"),
        "env_vars": data.get("env_vars"),
        "overrides": data.get("overrides"),
    }
    return json.dumps(payload, sort_keys=True)


def dedupe_results(results: list[dict]) -> list[dict]:
    """Merge resolver results that differ only by config file path."""
    unique: list[dict] = []
    seen: dict[str, dict] = {}
    for data in results:
        sig = result_signature(data)
        if sig in seen:
            seen[sig]["config_files"].append(data["config_file"])
            continue
        entry = dict(data)
        entry["config_files"] = [data["config_file"]]
        seen[sig] = entry
        unique.append(entry)
    return unique


def format_report(data: dict) -> None:
    """Print a human-readable env var report for one resolver result."""
    configs = data.get("config_files") or [data["config_file"]]
    print(f"## Job: {data['job_name']} ({data['version']})")
    if len(configs) == 1:
        print(f"- **Config**: {configs[0]}")
    else:
        print(f"- **Configs** ({len(configs)} identical):")
        for path in configs:
            print(f"  - {path}")
    print(f"- **Workflow**: {data.get('workflow') or '(none)'}")
    filt = data.get("filter")
    print(
        f"- **Variables**: {data['filtered_count']} shown / {data['total_count']} total"
        + (f" (filter: {filt!r})" if filt else "")
    )
    overrides = data.get("overrides") or []
    if overrides:
        print(f"- **Overrides**: {len(overrides)}")
    print()
    if data["filtered_count"] == 0:
        print("_No environment variables matched the filter._\n")
        return
    print("| Variable | Value | Source |")
    print("|----------|-------|--------|")
    for var in data.get("env_vars") or []:
        mark = "⚠️ " if var.get("is_overridden") else ""
        print(
            f"| {mark}{var['name']} | {truncate(str(var['value']))} | {var['source']} |"
        )
    if overrides:
        print("\n### Key overrides\n")
        print("| Variable | Value | Source | Default |")
        print("|----------|-------|--------|---------|")
        for var in overrides:
            print(
                f"| {var['name']} | {truncate(str(var['value']))} | {var['source']} | "
                f"{truncate(str(var.get('default_value') or ''))} |"
            )
    print()


def non_negative_int(value: str) -> int:
    """Argparse type that rejects negative integers."""
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


def run_resolver(
    script: Path,
    config_file: Path,
    job_name: str,
    filter_str: str | None,
    repo_root: Path,
    timeout: float | None = 60,
) -> dict:
    """Run effective_env.py for one config file and parse JSON output."""
    cmd = [
        sys.executable,
        str(script),
        str(config_file),
        job_name,
        "--repo-root",
        str(repo_root),
    ]
    if filter_str:
        cmd.extend(["--filter", filter_str])
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"resolver exited with status {proc.returncode}")
    return json.loads(proc.stdout)


def resolve_all(
    resolver_script: Path,
    configs: list[Path],
    job_name: str,
    filter_str: str | None,
    repo_root: Path,
) -> tuple[list[dict], int]:
    """Resolve env vars for each matching config file."""
    results: list[dict] = []
    exit_code = 0
    for config_file in configs:
        try:
            results.append(
                run_resolver(resolver_script, config_file, job_name, filter_str, repo_root)
            )
        except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
            rel = config_file.relative_to(repo_root)
            print(f"error: {rel}: {exc}", file=sys.stderr)
            exit_code = 1
    return results, exit_code


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Resolve effective environment variables for a CI job by name.",
    )
    parser.add_argument("job_name", help="Job name (ci-operator tests.as value)")
    parser.add_argument(
        "--component",
        help="Narrow search, e.g. hypershift or openshift/hypershift",
    )
    parser.add_argument(
        "--version",
        help="Release version filter, e.g. 4.21 or '4.21,4.20'",
    )
    parser.add_argument(
        "--filter",
        help="Case-insensitive env var name filter",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print a single JSON document with all resolved configs",
    )
    parser.add_argument(
        "--include-priv",
        action="store_true",
        help="Include openshift-priv configs (excluded by default)",
    )
    parser.add_argument(
        "--max-configs",
        type=non_negative_int,
        default=3,
        help="Max config files to resolve when multiple match (default: 3)",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repository root (default: auto-detect)",
    )
    return parser.parse_args()


def main() -> int:
    """CLI entrypoint."""
    args = parse_args()
    repo_root = args.repo_root or repo_root_from_script()
    config_dir = repo_root / "ci-operator" / "config"
    resolver_script = repo_root / ".claude" / "scripts" / "effective_env.py"
    if not resolver_script.is_file():
        print(f"error: missing {resolver_script}", file=sys.stderr)
        return 1

    configs = find_configs(
        config_dir,
        args.job_name,
        args.component,
        parse_versions(args.version),
        args.include_priv,
    )
    if not configs:
        hint = " (try --include-priv)" if not args.include_priv else ""
        print(f"error: no config defines job {args.job_name!r}{hint}", file=sys.stderr)
        return 1

    if len(configs) > args.max_configs:
        print(
            f"error: {len(configs)} configs match; narrow with --component or --version "
            f"or raise --max-configs (first {args.max_configs} paths):",
            file=sys.stderr,
        )
        for path in configs[: args.max_configs]:
            print(f"  {path.relative_to(repo_root)}", file=sys.stderr)
        return 1

    results, exit_code = resolve_all(
        resolver_script,
        configs[: args.max_configs],
        args.job_name,
        args.filter,
        repo_root,
    )
    if not results:
        return exit_code or 1

    unique = dedupe_results(results)
    if args.json:
        print(
            json.dumps(
                {
                    "job_name": args.job_name,
                    "match_count": len(unique),
                    "results": unique,
                },
                indent=2,
            )
        )
    else:
        for data in unique:
            format_report(data)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
