#!/usr/bin/env python3
"""Extract shipped shell/python fragments from the hypershift-conformance chain.

The capture helper lives inside the chain's inline `commands` block, so the
tests run the shipped text itself instead of a copy that could drift.

Usage: extract.py <chain.yaml> {commands|function|gate|program}
"""
import sys

BLOCK_INDENT = 6
COMMANDS_MARKER = "    commands: |-"
FUNC_BEGIN = "# >>> BEGIN aws-failure-diagnostics"
FUNC_END = "# <<< END aws-failure-diagnostics"
PROGRAM_BEGIN = "<<'AWS_FAILURE_DIAGNOSTICS_PY'"
PROGRAM_END = "AWS_FAILURE_DIAGNOSTICS_PY"
GATE_BEGIN = "# Gated, best-effort AWS failure context capture."
GATE_END = "exit ${exit_code}"


def commands(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    try:
        start = lines.index(COMMANDS_MARKER) + 1
    except ValueError:
        sys.exit("commands block not found")
    out = []
    for line in lines[start:]:
        if not line.strip():
            out.append("")
            continue
        if len(line) - len(line.lstrip(" ")) < BLOCK_INDENT:
            break
        out.append(line[BLOCK_INDENT:])
    return "\n".join(out).rstrip("\n") + "\n"


def slice_between(text, begin, end, include=True):
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if begin in l), None)
    if start is None:
        sys.exit(f"begin marker {begin!r} not found")
    stop = next(
        (i for i, l in enumerate(lines[start + 1:], start + 1) if l.strip() == end),
        None,
    )
    if stop is None:
        sys.exit(f"end marker {end!r} not found")
    chunk = lines[start:stop + 1] if include else lines[start + 1:stop]
    return "\n".join(chunk) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, what = sys.argv[1], sys.argv[2]
    body = commands(path)
    if what == "commands":
        sys.stdout.write(body)
    elif what == "function":
        sys.stdout.write(slice_between(body, FUNC_BEGIN, FUNC_END))
    elif what == "gate":
        sys.stdout.write(slice_between(body, GATE_BEGIN, GATE_END))
    elif what == "program":
        sys.stdout.write(
            slice_between(body, PROGRAM_BEGIN, PROGRAM_END, include=False)
        )
    else:
        sys.exit(f"unknown selector {what!r}")


if __name__ == "__main__":
    main()
