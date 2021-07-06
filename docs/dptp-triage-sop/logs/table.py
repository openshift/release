#!/usr/bin/env python3

from tabulate import tabulate
import sys
import os
import json

data = {}

with open(sys.argv[1]) as raw:
	data = json.load(raw)

headers = ["time", "level", "component", "message", "file", "func", "fields"]
entries = []

for item in data:
	for field in item:
		if field["field"] == "@message":
			raw_entry = json.loads(field["value"])
			for key in ["kubernetes", "severity", "source_type", "stream"]:
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
largest = [0 for e in headers[:3]]
for entry in entries:
	for i in range(len(entry[:3])):
		if len(entry[i]) > largest[i]:
			largest[i] = len(entry[i])

for item in largest:
	width -= item

truncated_headers = ["time", "level", "component", "message"]
truncated_entries = []
width -= 2 * (len(truncated_headers) - 1)
width -= 7 # for the ellipsis
for entry in entries:
	truncated_entry = []
	for item in entry[:4]:
		if len(item) > width:
			bound = int(width/2)
			truncated_entry.append(item[0:bound] + " ... " + item[-bound:])
		else:
			truncated_entry.append(item)
	truncated_entries.append(truncated_entry)

print(tabulate(truncated_entries, headers=headers))

with open(sys.argv[1] + ".table", "w+") as raw:
	raw.write(tabulate(entries, headers=headers))
	print("Wrote full table to " + sys.argv[1] + ".table")