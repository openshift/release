#!/usr/bin/env python3
"""Generate clusters/gitops/apps/appset-*.yaml from hack/generators/gitops/applicationsets.yaml."""

import argparse
import pathlib
import sys

import yaml

CONFIG = pathlib.Path("hack/generators/gitops/applicationsets.yaml")
OUT_DIR = pathlib.Path("clusters/gitops/apps")
LABEL = "ci.openshift.io/gitops-managed"


class Quoted(str):
    pass


def _quoted(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="'")


yaml.SafeDumper.add_representer(Quoted, _quoted)


class UniqueKeyLoader(yaml.SafeLoader):  # pylint: disable=too-many-ancestors
    pass


def _construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key: {key!r}", key_node.start_mark
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def build(entry):
    metadata = {
        "labels": {LABEL: Quoted("true")},
        "name": entry["name"],
        "namespace": "openshift-gitops",
    }
    metadata.update(entry.get("metadata") or {})
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "metadata": metadata,
        "spec": entry["spec"],
    }


def output_path(root, filename):
    if pathlib.Path(filename).name != filename:
        raise SystemExit(f"filename must be a basename: {filename!r}")
    out_dir = (root / OUT_DIR).resolve()
    path = (out_dir / filename).resolve()
    if path.parent != out_dir:
        raise SystemExit(f"filename escapes {OUT_DIR}: {filename!r}")
    return path


def load_config(root):
    cfg = yaml.load((root / CONFIG).read_text(), Loader=UniqueKeyLoader)
    entries = cfg.get("applicationsets") or []
    if not entries:
        raise SystemExit(f"no applicationsets in {CONFIG}")
    return entries


def generate(root):
    (root / OUT_DIR).mkdir(parents=True, exist_ok=True)
    written = []
    for entry in load_config(root):
        path = output_path(root, entry["filename"])
        path.write_text(
            yaml.dump(build(entry), Dumper=yaml.SafeDumper, default_flow_style=False, sort_keys=False, width=120)
        )
        written.append(path)
    return written


def normalize(doc):
    return yaml.safe_load(yaml.dump(doc, Dumper=yaml.SafeDumper, sort_keys=True))


def verify(root):
    errors = []
    entries = load_config(root)
    expected = {entry["filename"] for entry in entries}
    actual = {p.name for p in (root / OUT_DIR).glob("appset-*.yaml")}
    for extra in sorted(actual - expected):
        errors.append(f"unexpected {OUT_DIR / extra} (remove file or add it to applicationsets.yaml)")
    for entry in entries:
        path = output_path(root, entry["filename"])
        if not path.is_file():
            errors.append(f"missing {path.relative_to(root)}")
            continue
        want = normalize(build(entry))
        got = normalize(yaml.safe_load(path.read_text()))
        if want != got:
            errors.append(f"stale {path.relative_to(root)} (update applicationsets.yaml or run make gitops-applicationsets)")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo_root", nargs="?", default=".")
    parser.add_argument("--verify", action="store_true", help="fail if generated output does not match config")
    args = parser.parse_args(argv)
    root = pathlib.Path(args.repo_root).resolve()
    if args.verify:
        errors = verify(root)
        if errors:
            print("ERROR: ApplicationSet manifests do not match hack/generators/gitops/applicationsets.yaml", file=sys.stderr)
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            print("ERROR: edit applicationsets.yaml then: make gitops-applicationsets", file=sys.stderr)
            return 1
        print("GitOps ApplicationSet check: PASS")
        return 0
    for path in generate(root):
        print(f"wrote {path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
