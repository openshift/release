#!/usr/bin/env python3
"""Render one immutable workload image for either OCPSTRAT-2100 case."""

import argparse
import datetime
import json
import re
import subprocess
from pathlib import Path
from string import Template


ROOT = Path(__file__).resolve().parents[1]
NODE_LABEL = "verification.hypershift.openshift.io/ocpstrat-2100-run"
BASE_FILES = ("namespace.yaml", "service.yaml", "deployment.yaml")
TC_012_FILES = ("tc-012-pdb.yaml", "tc-012-probes.yaml")
RUN_ID_RE = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,18}[a-z0-9])?")
IMAGE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}")


def git_output(*args):
    try:
        return subprocess.check_output(
            ("git", "-C", str(ROOT), *args), stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, choices=("tc-012", "tc-014"))
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--image", required=True, help="immutable image@sha256:digest reference")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    if not RUN_ID_RE.fullmatch(args.run_id):
        parser.error("--run-id must be 1-20 lowercase letters, digits, or internal hyphens")
    if not IMAGE_RE.fullmatch(args.image):
        parser.error("--image must be an image name followed by @sha256: and 64 lowercase hex digits")

    namespace = f"ocpstrat-2100-{args.case}-{args.run_id}"
    replicas = 4 if args.case == "tc-012" else 3
    values = {
        "NAMESPACE": namespace,
        "RUN_ID": args.run_id,
        "IMAGE": args.image,
        "REPLICAS": str(replicas),
    }
    output_dir = args.output_dir.resolve()
    if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        parser.error("--output-dir must be new or empty")
    output_dir.mkdir(parents=True, exist_ok=True)

    files = BASE_FILES + (TC_012_FILES if args.case == "tc-012" else ())
    for name in files:
        source = (ROOT / "manifests" / name).read_text(encoding="utf-8")
        (output_dir / name).write_text(Template(source).substitute(values), encoding="utf-8")

    metadata = {
        "case": args.case,
        "namespace": namespace,
        "runID": args.run_id,
        "nodeLabel": f"{NODE_LABEL}={args.run_id}",
        "replicas": replicas,
        "image": args.image,
        "sourceCommit": git_output("rev-parse", "HEAD"),
        "sourceDirty": bool(git_output("status", "--porcelain", "--", str(ROOT))),
        "renderedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    (output_dir / "run-metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    print(f"namespace={namespace}")
    print(f"node_label={metadata['nodeLabel']}")
    print(f"replicas={replicas}")
    print(f"output_dir={output_dir}")


if __name__ == "__main__":
    main()
