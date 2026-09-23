#!/usr/bin/env python3
"""Search OpenShift CI step-registry steps, workflows, and chains."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

try:
    import yaml
except ImportError:
    print("error: PyYAML required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

REF_LINE = re.compile(r"^\s*-\s+ref:\s+(\S+)\s*$", re.MULTILINE)
CHAIN_LINE = re.compile(r"^\s*-\s+chain:\s+(\S+)\s*$", re.MULTILINE)
WORKFLOW_LINE = re.compile(r"^\s*workflow:\s+(\S+)\s*$", re.MULTILINE)


@dataclass
class Component:
    """Step-registry component metadata loaded from a registry YAML file."""

    name: str
    kind: str
    path: Path
    documentation: str


@dataclass
class ReferenceIndex:
    """Precomputed map of component names to YAML files that reference them."""

    steps: dict[str, list[str]] = field(default_factory=dict)
    chains: dict[str, list[str]] = field(default_factory=dict)
    workflows: dict[str, list[str]] = field(default_factory=dict)


def repo_root_from_script() -> Path:
    """Return the openshift/release repository root."""
    return Path(__file__).resolve().parents[2]


def kind_from_filename(name: str) -> str | None:
    """Map a registry filename suffix to a component kind."""
    if name.endswith("-ref.yaml"):
        return "step"
    if name.endswith("-workflow.yaml"):
        return "workflow"
    if name.endswith("-chain.yaml"):
        return "chain"
    return None


def load_component(path: Path) -> Component | None:
    """Load one registry component from YAML, or None if the file is invalid."""
    kind = kind_from_filename(path.name)
    if kind is None:
        return None
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError:
        return None
    if not isinstance(data, dict) or len(data) != 1:
        return None
    key = next(iter(data))
    body = data[key]
    if not isinstance(body, dict):
        return None
    name = body.get("as")
    if not name:
        return None
    doc = body.get("documentation", "") or ""
    if isinstance(doc, list):
        doc = "\n".join(str(x) for x in doc)
    return Component(str(name), kind, path, str(doc).strip())


def discover_components(registry_dir: Path) -> list[Component]:
    """Discover all step, workflow, and chain components under the registry."""
    components: list[Component] = []
    seen: set[Path] = set()
    for suffix in ("-ref.yaml", "-workflow.yaml", "-chain.yaml"):
        for path in registry_dir.rglob(f"*{suffix}"):
            if path in seen:
                continue
            seen.add(path)
            comp = load_component(path)
            if comp is not None:
                components.append(comp)
    return components


def read_yaml_corpus(base: Path) -> dict[str, str]:
    """Read all YAML files under base into a path->content map."""
    corpus: dict[str, str] = {}
    for path in base.rglob("*.yaml"):
        try:
            corpus[str(path)] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
    return corpus


def build_reference_index(*corpora: dict[str, str]) -> ReferenceIndex:
    """Index ref, chain, and workflow references across YAML corpora."""
    index = ReferenceIndex()
    for corpus in corpora:
        for path_str, text in corpus.items():
            for match in REF_LINE.finditer(text):
                index.steps.setdefault(match.group(1), []).append(path_str)
            for match in CHAIN_LINE.finditer(text):
                index.chains.setdefault(match.group(1), []).append(path_str)
            for match in WORKFLOW_LINE.finditer(text):
                index.workflows.setdefault(match.group(1), []).append(path_str)
    return index


def tokenize(query: str) -> list[str]:
    """Split a query into lowercase whitespace-delimited tokens."""
    return [t for t in query.lower().split() if t]


def exact_name_match(components: Iterable[Component], query: str, kind: str) -> Component | None:
    """Return a component whose as-name exactly matches the query."""
    name = query.lower().strip()
    if not name or " " in name:
        return None
    for comp in components:
        if kind != "all" and comp.kind != kind:
            continue
        if comp.name.lower() == name:
            return comp
    return None


def contains_token(text: str, token: str) -> bool:
    """Return True when token appears as a standalone word in text."""
    return bool(re.search(rf"(?<![a-z0-9-]){re.escape(token)}(?![a-z0-9-])", text))


def score_component(comp: Component, tokens: list[str], repo_root: Path) -> int:
    """Score how many query tokens match the component name or repo-relative path."""
    rel_path = str(comp.path.relative_to(repo_root)).lower()
    name_path = " ".join([comp.name.lower(), rel_path])
    doc = comp.documentation.lower()
    score = 0
    for token in tokens:
        if token in name_path or contains_token(doc, token):
            score += 1
    return score


def filter_components(
    components: Iterable[Component],
    query: str,
    kind: str,
    limit: int,
    repo_root: Path,
) -> list[Component]:
    """Return registry components matching the query, up to limit."""
    exact = exact_name_match(components, query, kind)
    if exact is not None:
        return [exact]
    tokens = tokenize(query)
    if not tokens:
        return []
    scored: list[tuple[int, Component]] = []
    for comp in components:
        if kind != "all" and comp.kind != kind:
            continue
        score = score_component(comp, tokens, repo_root)
        if score == len(tokens):
            scored.append((score, comp))
    scored.sort(key=lambda item: (-item[0], item[1].name))
    return [comp for _, comp in scored[:limit]]


def impact_label(count: int) -> str:
    """Map reverse-dependency count to an impact label."""
    if count >= 100:
        return "HIGH"
    if count >= 10:
        return "MEDIUM"
    if count >= 1:
        return "LOW"
    return "NONE"


def lookup_references(index: ReferenceIndex, comp: Component) -> list[str]:
    """Return all indexed paths that reference the component."""
    if comp.kind == "step":
        paths = index.steps.get(comp.name, [])
    elif comp.kind == "chain":
        paths = index.chains.get(comp.name, [])
    else:
        paths = index.workflows.get(comp.name, [])
    return list(dict.fromkeys(paths))


def lookup_config_usage(
    index: ReferenceIndex,
    comp: Component,
    config_dir: Path,
    limit: int = 3,
) -> tuple[int, list[str]]:
    """Return config-only reference count and sample paths for a component."""
    all_paths = lookup_references(index, comp)
    config_root = str(config_dir.resolve())
    config_paths = [path for path in all_paths if path.startswith(config_root)]
    return len(config_paths), config_paths[:limit]


def lookup_reverse_deps(
    index: ReferenceIndex,
    comp: Component,
    registry_dir: Path,
    config_dir: Path,
) -> list[str]:
    """Return indexed paths that reference the component in registry and/or config."""
    paths = lookup_references(index, comp)
    registry_root = str(registry_dir.resolve())
    config_root = str(config_dir.resolve())
    if comp.kind == "workflow":
        return [path for path in paths if path.startswith(config_root)]
    return [
        path
        for path in paths
        if path.startswith(registry_root) or path.startswith(config_root)
    ]


def usage_hint(comp: Component) -> str:
    """Return the ci-operator reference syntax for a component."""
    if comp.kind == "step":
        return f"ref: {comp.name}"
    if comp.kind == "chain":
        return f"chain: {comp.name}"
    return f"workflow: {comp.name}"


def truncate(text: str, max_len: int = 240) -> str:
    """Collapse whitespace and truncate long text for display."""
    text = " ".join(text.split())
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def non_negative_int(value: str) -> int:
    """Argparse type that rejects negative integers."""
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


def render_results(
    matches: list[Component],
    *,
    show_usage: bool,
    show_reverse_deps: bool,
    index: ReferenceIndex,
    registry_dir: Path,
    config_dir: Path,
    reverse_limit: int,
    repo_root: Path,
) -> None:
    """Print human-readable search results."""
    if not matches:
        print("No matching step-registry components found.")
        return
    print(f"Found {len(matches)} matching component(s):\n")
    for comp in matches:
        rel = comp.path.relative_to(repo_root)
        print(f"### {comp.name} (type: {comp.kind})")
        print(f"**File**: `{rel}`")
        if comp.documentation:
            print(f"**Description**: {truncate(comp.documentation)}")
        print(f"**Usage**: `{usage_hint(comp)}`")
        if show_usage:
            total, examples = lookup_config_usage(index, comp, config_dir)
            if total:
                print(f"**Config usage**: {total} config file(s); showing {len(examples)}")
            else:
                print("**Config usage**: 0 direct config references (may be used via workflows/chains)")
            for path in examples:
                print(f"- `{Path(path).relative_to(repo_root)}`")
        if show_reverse_deps:
            deps = lookup_reverse_deps(index, comp, registry_dir, config_dir)
            level = impact_label(len(deps))
            print(f"**Reverse deps**: {len(deps)} ({level} impact)")
            for path in deps[:reverse_limit]:
                print(f"- `{Path(path).relative_to(repo_root)}`")
            if len(deps) > reverse_limit:
                print(f"- ... and {len(deps) - reverse_limit} more")
        print()


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Search step-registry steps, workflows, and chains.",
    )
    parser.add_argument("query", help="Search keywords (all tokens must match)")
    parser.add_argument(
        "--type",
        choices=("all", "step", "workflow", "chain"),
        default="all",
        help="Component type filter (default: all)",
    )
    parser.add_argument(
        "--limit",
        type=non_negative_int,
        default=10,
        help="Maximum results (default: 10)",
    )
    parser.add_argument(
        "--show-usage",
        action="store_true",
        help="Show example ci-operator config references",
    )
    parser.add_argument(
        "--no-reverse-deps",
        action="store_true",
        help="Skip reverse dependency scan (faster)",
    )
    parser.add_argument(
        "--reverse-limit",
        type=non_negative_int,
        default=8,
        help="Max reverse dependency paths per result (default: 8)",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repository root (default: auto-detect from script location)",
    )
    return parser.parse_args()


def main() -> int:
    """CLI entrypoint."""
    args = parse_args()
    repo_root = args.repo_root or repo_root_from_script()
    registry_dir = repo_root / "ci-operator" / "step-registry"
    config_dir = repo_root / "ci-operator" / "config"
    if not registry_dir.is_dir():
        print(f"error: step-registry not found at {registry_dir}", file=sys.stderr)
        return 1
    components = discover_components(registry_dir)
    matches = filter_components(components, args.query, args.type, args.limit, repo_root)

    index = ReferenceIndex()
    if args.show_usage or not args.no_reverse_deps:
        index = build_reference_index(
            read_yaml_corpus(config_dir),
            read_yaml_corpus(registry_dir),
        )

    render_results(
        matches,
        show_usage=args.show_usage,
        show_reverse_deps=not args.no_reverse_deps,
        index=index,
        registry_dir=registry_dir,
        config_dir=config_dir,
        reverse_limit=args.reverse_limit,
        repo_root=repo_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
