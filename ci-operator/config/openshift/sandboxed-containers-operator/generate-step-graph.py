#!/usr/bin/env python3
"""Regenerate the Mermaid step graph from the numbered steps in CONTRIBUTING.md."""

import argparse
import re
from pathlib import Path


PHASES = ("Pre", "Test", "Post")
BEGIN = "<!-- BEGIN GENERATED WORKFLOW GRAPH -->"
END = "<!-- END GENERATED WORKFLOW GRAPH -->"


def label(text):
    """Strip inline code delimiters and escape Mermaid label syntax."""
    text = text.replace("`", "").removesuffix(".")
    return re.sub(r'["#&<>|]', lambda match: f"#{ord(match[0])};", text)


def render(markdown):
    steps = {}
    phase = None
    for line in markdown.splitlines():
        if heading := re.match(r"#{2,3} (.+)$", line):
            phase = heading[1].removesuffix(" phase")
            if heading[1] != f"{phase} phase" or phase not in PHASES:
                phase = None
            elif phase in steps:
                raise ValueError(f"Duplicate {phase} phase")
            else:
                steps[phase] = []
        if phase is None:
            continue
        if match := re.fullmatch(r"\d+\. \*\*(.+?)\*\*.*", line):
            steps[phase].append((match[1], None))
        elif re.match(r"\d+\. ", line):
            raise ValueError(f"Expected a bold step title: {line}")
        elif match := re.fullmatch(r" {3,}- Run only if (.+)", line):
            if not steps[phase] or steps[phase][-1][1] is not None:
                raise ValueError(f"Expected one condition per step: {line}")
            steps[phase][-1] = (steps[phase][-1][0], match[1])

    if tuple(steps) != PHASES or not all(steps.values()):
        raise ValueError("Expected nonempty Pre, Test, and Post phases in that order")

    lines = ["```mermaid", "flowchart TD"]
    entries = {}
    for phase, phase_steps in steps.items():
        prefix = phase.lower()
        entries[phase] = []
        lines.append(f'    subgraph {prefix}["{phase}"]')
        for index, (title, condition) in enumerate(phase_steps, 1):
            node = f"{prefix}_{index}"
            entry = node
            if condition:
                entry = f"{node}_condition"
                lines.append(f'        {entry}{{"{label(condition)}?"}}')
                lines.append(f"        {entry} -->|Yes| {node}")
            lines.append(f'        {node}["{label(title)}"]')
            entries[phase].append((entry, node))
        lines.append("    end")

    lines.extend(['    pre_result{"Pre phase passed?"}', '    done(["End"])'])
    next_entry = {"Pre": "pre_result", "Test": entries["Post"][0][0], "Post": "done"}
    for phase, phase_entries in entries.items():
        targets = [entry for entry, _ in phase_entries[1:]] + [next_entry[phase]]
        for (entry, node), target in zip(phase_entries, targets):
            lines.append(f"    {node} --> {target}")
            if entry != node:
                lines.append(f"    {entry} -->|No| {target}")
    lines.extend([
        f'    pre_result -->|Yes| {entries["Test"][0][0]}',
        f'    pre_result -->|No| {entries["Post"][0][0]}',
        "```",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the embedded graph is stale")
    args = parser.parse_args()

    path = Path(__file__).with_name("CONTRIBUTING.md")
    markdown = path.read_text(encoding="utf-8")
    pattern = re.compile(rf"^{re.escape(BEGIN)}\n.*?^{re.escape(END)}$", re.M | re.S)
    blocks = list(pattern.finditer(markdown))
    if len(blocks) != 1 or markdown.count(BEGIN) != 1 or markdown.count(END) != 1:
        parser.exit(1, "Expected exactly one marked workflow graph block\n")
    block = blocks[0]
    try:
        graph = render(markdown[:block.start()] + markdown[block.end():])
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    updated = markdown[:block.start()] + f"{BEGIN}\n\n{graph}\n\n{END}" + markdown[block.end():]
    if updated != markdown:
        if args.check:
            parser.exit(1, "Workflow graph is stale; rerun generate-step-graph.py\n")
        path.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main()
