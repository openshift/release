#!/usr/bin/env python3
import json
import os
import sys

from tabulate import tabulate

headers = ["time", "level", "component", "message", "file", "func", "fields"]
truncated_headers = ["time", "level", "component", "message"]
ignored_fields = ["kubernetes", "severity", "source_type", "stream"]

output_file = sys.argv[1] + ".table"
output = open(output_file, "w+")
truncated_output = sys.stdout
data = json.load(open(sys.argv[1]))
entries = []

for item in data:
	for field in item:
		if field["field"] == "@message":
			raw_entry = json.loads(field["value"])
			for key in ignored_fields:
				raw_entry.pop(key, None)

			entry = [
				raw_entry.pop("time", ""),
				raw_entry.pop("level", ""),
				raw_entry.pop("component", ""),
			]
			
			message = "msg=" + raw_entry.pop("msg", "")
			if "error" in raw_entry:
				message += ", error=" + raw_entry.pop("error", "")
			entry.append(message)

			entry.append(raw_entry.pop("file", ""))
			entry.append(raw_entry.pop("func", ""))

			fields = []
			for key, value in sorted(raw_entry.items()):
				fields.append("{}={}".format(key, value))
			entry.append(",".join(fields))
			entries.append(entry)

width = os.get_terminal_size().columns
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
			bound = int(width/2)
			truncated_entry.append(item[0:bound] + " ... " + item[-bound:])
		else:
			truncated_entry.append(item)
	truncated_entries.append(truncated_entry)

output.write(tabulate(entries, headers=headers))
truncated_output.write(tabulate(truncated_entries, headers=headers))
truncated_output.write(f"\n\nWrote full table to {output_file}\n")
