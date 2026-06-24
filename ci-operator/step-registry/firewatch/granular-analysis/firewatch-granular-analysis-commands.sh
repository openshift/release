#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

artifact_dir="${ARTIFACT_DIR}"
if [ -n "${FIREWATCH_GRANULAR_ARTIFACT_SUBDIR:-}" ]; then
    artifact_dir="${ARTIFACT_DIR}/${FIREWATCH_GRANULAR_ARTIFACT_SUBDIR}"
fi

output_dir="${SHARED_DIR}"
labels_file="${output_dir}/firewatch-additional-labels"
json_report="${output_dir}/firewatch-granular-data.json"

mapfile -t xml_files < <(find "${artifact_dir}" -name '*.xml' -path '*/junit/*' 2>/dev/null; find "${artifact_dir}" -maxdepth 1 -name '*.xml' 2>/dev/null)

if [ ${#xml_files[@]} -eq 0 ]; then
    echo '{"failure_count":0,"operators":[]}' > "${json_report}"
    echo "No JUnit XML files found; wrote zero-failure report."
    exit 0
fi

exit_code=0
python3 << 'EXTRACT_LABELS' || exit_code=$?
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

OPERATOR_CAP = 5
COMPONENT_CAP = 3
LOCATION_CAP = 3

OPERATOR_RE = re.compile(r'[\w.-]+-operator\b', re.IGNORECASE)
LOCATION_RE = re.compile(r'[\w/.-]+\.go\b')

operators = set()
components = set()
locations = set()
failure_count = 0

artifact_dir = os.environ["ARTIFACT_DIR"]
subdir = os.environ.get("FIREWATCH_GRANULAR_ARTIFACT_SUBDIR", "")
if subdir:
    artifact_dir = os.path.join(artifact_dir, subdir)

xml_paths = []
junit_dir = os.path.join(artifact_dir, "junit")
if os.path.isdir(junit_dir):
    for name in os.listdir(junit_dir):
        if name.endswith(".xml"):
            xml_paths.append(os.path.join(junit_dir, name))
for name in os.listdir(artifact_dir):
    full = os.path.join(artifact_dir, name)
    if name.endswith(".xml") and os.path.isfile(full) and full not in xml_paths:
        xml_paths.append(full)

for path in xml_paths:
    try:
        tree = ET.parse(path)
    except ET.ParseError:
        print(f"WARN: skipping malformed XML: {path}", file=sys.stderr)
        continue

    for tc in tree.iter("testcase"):
        failures = list(tc.iter("failure"))
        if not failures:
            continue
        failure_count += 1

        classname = tc.get("classname", "")
        name = tc.get("name", "")
        msg = failures[0].get("message", "")
        body = failures[0].text or ""
        search_text = f"{classname} {name} {msg} {body}"

        for m in OPERATOR_RE.finditer(search_text):
            operators.add(m.group(0).lower())

        if classname:
            parts = classname.rsplit(".", 1)
            comp = parts[-1] if len(parts) > 1 else parts[0]
            comp = re.sub(r'^Test', '', comp)
            comp = re.sub(r'[^a-zA-Z0-9_-]', '', comp).lower()
            if comp:
                components.add(comp)
        elif name:
            comp = name.split("/")[0]
            comp = re.sub(r'^Test', '', comp)
            comp = re.sub(r'[^a-zA-Z0-9_-]', '', comp).lower()
            if comp:
                components.add(comp)

        for m in LOCATION_RE.finditer(search_text):
            locations.add(m.group(0))

output_dir = os.environ["SHARED_DIR"]
labels_path = os.path.join(output_dir, "firewatch-additional-labels")
json_path = os.path.join(output_dir, "firewatch-granular-data.json")

operator_list = sorted(operators)[:OPERATOR_CAP]
component_list = sorted(components)[:COMPONENT_CAP]
location_list = sorted(locations)[:LOCATION_CAP]

if failure_count > 0:
    with open(labels_path, "w") as f:
        for op in operator_list:
            f.write(f"operator:{op}\n")
        for comp in component_list:
            f.write(f"component:{comp}\n")
        for loc in location_list:
            f.write(f"location:{loc}\n")

report = {
    "failure_count": failure_count,
    "operators": operator_list,
}
with open(json_path, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")

print(f"Extracted {failure_count} failure(s), {len(operator_list)} operator(s), "
      f"{len(component_list)} component(s), {len(location_list)} location(s)")
EXTRACT_LABELS

if [ -f "${labels_file}" ]; then
    echo "Labels written to ${labels_file}:"
    cat "${labels_file}"
fi

if [ -f "${json_report}" ]; then
    echo "Report written to ${json_report}"
fi

exit ${exit_code}
