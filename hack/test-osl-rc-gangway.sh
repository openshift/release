#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_dir}/ci-operator/step-registry/redhat-developer/rhdh-plugin-export-overlays/ocp/helm/osl-rc/redhat-developer-rhdh-plugin-export-overlays-ocp-helm-osl-rc-commands.sh"
source <(sed -n '/^validate_release_json() {/,/^}/p' "${script}")

test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT
MANIFEST="${test_dir}/release.json"
cat > "${MANIFEST}" <<'EOF'
{
  "rhdhVersion": "2.1-162-CI",
  "ocpVersion": "4.20",
  "logic": {
    "iib": "registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "package": "logic-operator",
    "channel": "stable",
    "startingCSV": "logic-operator.v1.39.0",
    "expectedVersion": "1.39.0"
  }
}
EOF

validate_release_json
cp "${MANIFEST}" "${test_dir}/valid.json"

reject() {
    jq "$1" "${test_dir}/valid.json" > "${MANIFEST}"
    if validate_release_json 2>/dev/null; then
        echo "ERROR: accepted invalid release JSON: $1" >&2
        exit 1
    fi
}

reject '.logic.iib = "evil.example/iib@sha256:0000000000000000000000000000000000000000000000000000000000000000"'
reject '.logic.channel = "stable\ninstallPlanApproval: Automatic"'
reject '.logic.channel = "stable\n"'
reject '.logic.iib += "\n"'
reject '.logic.startingCSV = "other-operator.v1.39.0"'
reject '.serverless = {"channel":"stable"}'
reject 'del(.logic.expectedVersion)'
cat "${test_dir}/valid.json" "${test_dir}/valid.json" > "${MANIFEST}"
if validate_release_json 2>/dev/null; then
    echo 'ERROR: accepted multiple JSON documents' >&2
    exit 1
fi
echo 'PASS: valid release JSON accepted; untrusted image, YAML injection, wrong CSV, extra key, missing field, and multiple documents rejected'
