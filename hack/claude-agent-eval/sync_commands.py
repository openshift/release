#!/usr/bin/env python3
"""Embed the testable manifest runner into the Prow-distributed shell script."""

import argparse
from pathlib import Path


HERE = Path(__file__).resolve().parent
COMMANDS = HERE.parents[1] / (
    "ci-operator/step-registry/openshift/claude/agent-eval/"
    "openshift-claude-agent-eval-commands.sh")
BEGIN = "# BEGIN GENERATED MANIFEST RUNNER\n"
END = "# END GENERATED MANIFEST RUNNER\n"


def generated_block():
    source = (HERE / "manifest_runner.py").read_text(encoding="utf-8")
    return (BEGIN
            + "# Edit hack/claude-agent-eval/manifest_runner.py, then run sync_commands.py.\n"
            + 'case "${EVAL_MANIFEST:-false}" in\n'
            + '    true|false) ;;\n'
            + '    *) echo "ERROR: EVAL_MANIFEST must be true or false"; exit 1 ;;\n'
            + 'esac\n'
            + 'if [[ "${EVAL_MANIFEST:-false}" == "true" ]]; then\n'
            + "    export -f write_eval_metrics\n"
            + "    python3 - <<'PY_MANIFEST_RUNNER'\n"
            + source
            + "PY_MANIFEST_RUNNER\n"
            + "    exit $?\n"
            + "fi\n"
            + END)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    original = COMMANDS.read_text(encoding="utf-8")
    prefix, rest = original.split(BEGIN, 1)
    _, suffix = rest.split(END, 1)
    updated = prefix + generated_block() + suffix
    if args.check:
        if original != updated:
            parser.exit(1, "Embedded manifest runner is stale; run python3 hack/claude-agent-eval/sync_commands.py\n")
    else:
        COMMANDS.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main()
