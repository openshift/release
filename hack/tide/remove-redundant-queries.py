#!/usr/bin/env python3
"""Remove Tide queries whose matching PRs are contained in another query.

Requires ruamel.yaml. See README.md for usage and containment semantics.
"""

import argparse
import copy
from dataclasses import dataclass
from pathlib import Path
import sys

from ruamel.yaml import YAML


LIST_FIELDS = (
    "orgs", "repos", "excludedRepos", "includedBranches", "excludedBranches",
    "labels", "missingLabels",
)
FIELDS = LIST_FIELDS + ("author", "milestone", "reviewApprovedRequired")


@dataclass
class Query:
    path: Path
    index: int
    line: int
    value: dict

    @property
    def location(self):
        return f"{self.path}:{self.line} (query {self.index + 1})"


def validate(q):
    """Fail closed for unsupported fields or malformed queries."""
    if not isinstance(q, dict) or set(q) - set(FIELDS):
        raise ValueError(f"unsupported query fields: {q}")
    for field in LIST_FIELDS:
        if not isinstance(q.get(field, []), list) or any(
            not isinstance(v, str) for v in q.get(field, [])
        ):
            raise ValueError(f"{field} must be a list of strings")
    for field in ("author", "milestone"):
        if not isinstance(q.get(field, ""), str):
            raise ValueError(f"{field} must be a string")
    if not isinstance(q.get("reviewApprovedRequired", False), bool):
        raise ValueError("reviewApprovedRequired must be a boolean")
    if not q.get("orgs") and not q.get("repos"):
        raise ValueError("query has no repository scope")
    if any("/" in o or not o for o in q.get("orgs", [])) or any(
        len(r.split("/")) != 2 or not all(r.split("/"))
        for field in ("repos", "excludedRepos") for r in q.get(field, [])
    ):
        raise ValueError("invalid organization or repository")


def repo_matches(q, repo):
    org = repo.split("/", 1)[0]
    return (org in q.get("orgs", []) or repo in q.get("repos", [])) and (
        repo not in q.get("excludedRepos", [])
    )


def scope_subset(strong, weak):
    # Explicit repositories plus a representative unnamed repo in every org
    # form a complete partition: membership is constant within each class.
    repos = {r for q in (strong, weak) for f in ("repos", "excludedRepos")
             for r in q.get(f, [])}
    orgs = {o for q in (strong, weak) for o in q.get("orgs", [])}
    orgs.update(r.split("/", 1)[0] for r in repos)
    for org in orgs:
        representative = org + "/__other__"
        while representative in repos:
            representative += "_"
        repos.add(representative)
    return all(not repo_matches(strong, r) or repo_matches(weak, r) for r in repos)


def branches_subset(strong, weak):
    si, se = set(strong.get("includedBranches", [])), set(strong.get("excludedBranches", []))
    wi, we = set(weak.get("includedBranches", [])), set(weak.get("excludedBranches", []))
    if si:
        return all((not wi or b in wi) and b not in we for b in si - se)
    return not wi and we <= se


def clauses(q):
    # Each labels entry is an AND clause; commas within it mean OR.
    absent = set(q.get("missingLabels", []))
    return [set(label.split(",")) - absent for label in q.get("labels", [])]


def covers(weak, strong):
    """Every PR matching strong must also match weak."""
    # Most pairs have disjoint repository scopes. Reject them before building
    # the complete repository partition.
    wo, so = set(weak.get("orgs", [])), set(strong.get("orgs", []))
    wr, sr = set(weak.get("repos", [])), set(strong.get("repos", []))
    if so - wo or any(r not in wr and r.split("/", 1)[0] not in wo for r in sr):
        return False
    if not scope_subset(strong, weak) or not branches_subset(strong, weak):
        return False
    if not set(weak.get("missingLabels", [])) <= set(strong.get("missingLabels", [])):
        return False
    sc = clauses(strong)
    if any(not c for c in sc):
        return False  # Contradictory criteria deserve separate investigation.
    if not all(any(s <= w for s in sc) for w in clauses(weak)):
        return False
    for field in ("author", "milestone"):
        if weak.get(field) and weak[field] != strong.get(field):
            return False
    return not weak.get("reviewApprovedRequired", False) or strong.get("reviewApprovedRequired", False)


def evidence(strong, weak):
    print(f"\n### Remove {strong.location}\n\nCovered by retained {weak.location}.")
    print("Every PR matching the removed query also matches the retained query.\n")
    print("| Criterion | Retained (broader) | Removed (narrower) |\n| --- | --- | --- |")
    for field in FIELDS:
        default = [] if field in LIST_FIELDS else False if field == "reviewApprovedRequired" else ""
        a, b = weak.value.get(field, default), strong.value.get(field, default)
        if not a and not b:
            continue
        def render(value):
            return str(value).replace("|", "\\|").replace("\n", " ") if value else "— (no restriction)"
        print(f"| {field} | {render(a)} | {render(b)} |")
    extra_clauses = [sorted(c) for c in clauses(strong.value) if c not in clauses(weak.value)]
    extra_absent = sorted(set(strong.value.get("missingLabels", [])) - set(weak.value.get("missingLabels", [])))
    print(f"\nAdditional label clauses: {extra_clauses or 'none'}; additional forbidden labels: {extra_absent or 'none'}.")
    if covers(strong.value, weak.value):
        print("The queries are equivalent; keep the first in sorted file/query order.")


def remove_blocks(text, indexes, yaml):
    """Use ruamel source marks to delete blocks without reformatting survivors."""
    node = yaml.compose(text)
    def child(mapping, key):
        return next(v for k, v in mapping.value if k.value == key)
    sequence = child(child(node, "tide"), "queries")
    if sequence.flow_style:
        raise ValueError("flow-style queries cannot be edited without reformatting")
    lines = text.splitlines(keepends=True)
    spans = []
    for i in indexes:
        item = sequence.value[i]
        start = item.start_mark.line
        end = item.end_mark.line + (
            item.end_mark.index == len(text) and bool(item.end_mark.column)
        )
        # Keep trailing comments/blank lines, including comments for the next item.
        while end > start and (not lines[end - 1].strip() or lines[end - 1].lstrip().startswith("#")):
            end -= 1
        spans.append((start, end))
    for start, end in sorted(spans, reverse=True):
        del lines[start:end]
    if len(indexes) == len(sequence.value):
        # Preserve the key as an empty list rather than changing its type to null.
        key_line = sequence.start_mark.line - 1
        if "queries:" not in lines[key_line]:
            raise ValueError("unsupported queries layout")
        lines[key_line] = lines[key_line].replace("queries:", "queries: []", 1)
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-dir", type=Path, default=Path(__file__).resolve().parents[2] / "core-services/prow/02_config")
    parser.add_argument("--dry-run", action="store_true", help="report evidence without editing files")
    args = parser.parse_args()
    if not args.config_dir.is_dir():
        parser.error(f"not a directory: {args.config_dir}")
    yaml = YAML()
    documents, queries = {}, []
    for path in sorted(args.config_dir.rglob("*")):
        if path.suffix not in (".yaml", ".yml") or not path.is_file():
            continue
        text = path.read_bytes().decode("utf-8")
        document = yaml.load(text)
        items = (document or {}).get("tide", {}).get("queries", []) or []
        if not items:
            continue
        documents[path] = (text, document)
        for index, item in enumerate(items):
            validate(item)
            queries.append(Query(path, index, item.lc.line + 1, item))
    # Index repository scope so unrelated repos never need pairwise comparison.
    by_org, by_repo = {}, {}
    for i, q in enumerate(queries):
        for org in q.value.get("orgs", []):
            by_org.setdefault(org, set()).add(i)
        for repo in q.value.get("repos", []):
            by_repo.setdefault(repo, set()).add(i)
    survivors = []
    for i, q in enumerate(queries):
        scopes = [by_org[o] for o in q.value.get("orgs", [])]
        scopes.extend(by_repo.get(r, set()) | by_org.get(r.split("/", 1)[0], set())
                      for r in q.value.get("repos", []))
        candidates = set.intersection(*scopes) - {i}
        # Strict containment is transitive. Equivalent queries retain the first.
        if not any(covers(queries[j].value, q.value) and (
            not covers(q.value, queries[j].value) or j < i
        ) for j in sorted(candidates)):
            survivors.append(q)
    retained = {id(q) for q in survivors}
    removed = [q for q in queries if id(q) not in retained]
    edits = {}
    print("# Redundant Tide queries")
    for q in removed:
        witness = next(s for s in survivors if covers(s.value, q.value))
        evidence(q, witness)
        edits.setdefault(q.path, []).append(q.index)
    # Prepare and validate every edit before writing any file.
    outputs = {}
    for path, indexes in edits.items():
        text, document = documents[path]
        expected = copy.deepcopy(document)
        for index in sorted(indexes, reverse=True):
            del expected["tide"]["queries"][index]
        result = remove_blocks(text, indexes, yaml)
        if yaml.load(result) != expected:
            raise ValueError(f"edit changed content beyond the removed queries: {path}")
        outputs[path] = result
    if not args.dry_run:
        for path, result in outputs.items():
            path.write_bytes(result.encode("utf-8"))
    print(f"\n{'Would remove' if args.dry_run else 'Removed'} {len(removed)} of {len(queries)} queries in {len(edits)} files; retained {len(survivors)}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(str(error))
