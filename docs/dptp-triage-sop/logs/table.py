#!/usr/bin/env python3
import itertools
import json
import os
import sys

from tabulate import tabulate

headers = ["time", "level", "message", "file", "func", "fields"]
truncated_headers = ["time", "level", "message"]
ignored_fields = ["structured.component", "kubernetes", "severity", "source_type", "stream"]
term_width = os.get_terminal_size().columns

output_file = sys.argv[1] + ".table"
output = open(output_file, "w+")
truncated_output = sys.stdout
write_both = lambda x: output.write(x) + truncated_output.write(x)

data = json.load(open(sys.argv[1]))
data = itertools.chain(*data)
data = filter(lambda x: x["field"] == "@message", data)
data = map(lambda x: json.loads(x["value"]), data)


def key(x):
    if "structured" in x:
        return x["structured"].get("component", "unknown")
    return "unknown"

data = sorted(data, key=key)
data = itertools.groupby(data, key)
for component, fields in data:
    entries = []
    for raw_entry in fields:
        for key in ignored_fields:
            raw_entry.pop(key, None)
        entry = []
        entry.append(raw_entry.pop("time", ""))
        entry.append(raw_entry.pop("level", ""))
        structured = raw_entry.pop("structured", "")
        if isinstance(structured, dict):
            message = "msg=" + structured.pop("msg", "")
            if "error" in structured:
                message += ", error=" + structured.pop("error", "")
            entry.append(message)
            entry.append(structured.pop("file", ""))
            entry.append(structured.pop("func", ""))
        fields = []
        for key, value in sorted(raw_entry.items()):
            fields.append("{}={}".format(key, value))
        entry.append(",".join(fields))
        entries.append(entry)
    width = term_width
    largest = [0] * (len(truncated_headers) - 1)
    for entry in entries:
        for i in range(len(largest)):
            if len(entry[i]) > largest[i]:
                largest[i] = len(entry[i])

    for item in largest:
        width -= item

    truncated_entries = []
    width -= 2 * (len(truncated_headers) - 1)
    width -= len("  ...  ")
    for entry in entries:
        truncated_entry = []
        for item in entry[:len(truncated_headers)]:
            if len(item) > width:
                bound = int(width / 2)
                truncated_entry.append(item[0:bound] + " ... " + item[-bound:])
            else:
                truncated_entry.append(item)
        truncated_entries.append(truncated_entry)

    write_both("{}\n{}\n\n".format(component, '-' * len(component)))
    output.write(tabulate(entries, headers=headers))
    truncated_output.write(tabulate(truncated_entries, headers=headers))
    write_both("\n\n\n")

truncated_output.write(f"Wrote full table to {output_file}\n")
