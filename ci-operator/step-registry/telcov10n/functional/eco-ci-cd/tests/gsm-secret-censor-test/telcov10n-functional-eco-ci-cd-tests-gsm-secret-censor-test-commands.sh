#!/bin/bash
set -uo pipefail

pip install yq --quiet
curl -sSL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /alabama/.local/bin/jq && chmod +x /alabama/.local/bin/jq
export PATH="${PATH}:/alabama/.local/bin"

SECRET_FILE=/var/group_variables/demo/example

# Helper from PR 85110 — reads a scalar from a YAML file without printing
# the file content to stdout.
read_yaml_key() {
  python3 -c '
import sys, yaml
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError:
    sys.exit("Error: " + path + " is not valid YAML")
if not isinstance(data, dict):
    sys.exit("Error: " + path + " is empty or not a YAML mapping")
if key not in data:
    sys.exit("Error: key " + key + " not found in " + path)
sys.stdout.write(str(data[key]))
' "$1" "$2"
}

echo "========================================================"
echo "=== INSECURE PATTERN (set -x ON) — should be CENSORED ==="
echo "========================================================"
set -x
KEY1_INSECURE=$(yq '.key1' "${SECRET_FILE}")
echo "key1 insecure: ${KEY1_INSECURE}"
set +x

echo ""
echo "========================================================"
echo "=== SECURE PATTERN (PR 85110) — should NOT appear in logs ==="
echo "========================================================"
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
KEY1_SECURE=$(read_yaml_key "${SECRET_FILE}" key1) || exit 1
KEY2_SECURE=$(read_yaml_key "${SECRET_FILE}" key2) || exit 1
$WAS_TRACING && set -x

echo "If censoring works, neither value above appears unredacted in the build log."
echo "Secure key1 read completed (value not printed)."
echo "Secure key2 read completed (value not printed)."

exit 1
