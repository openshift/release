#!/bin/bash
set +x
set -euo pipefail
umask 077

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping seed preparation"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

# Load the seed inventory restored by ibu-restore-seed-inventory.
mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
for key in all bastions nodes masters; do
  cp "${SHARED_DIR}/${key}" "${INVENTORY_PATH}/group_vars/${key}"
done
cp "${SHARED_DIR}/bastion" "${INVENTORY_PATH}/host_vars/bastion"

# Retrieve credentials while the seed is still managed by ACM. The playbook
# saves /tmp/${SEED_SPOKE_CLUSTER}-kubeconfig on the persistent seed bastion
# and prepares the CoreOS extensions image for seed generation.
cd /eco-ci-cd
ansible-playbook playbooks/ran/ibu-prepare-spoke-sno.yml \
  -i "${INVENTORY_PATH}/build-inventory.py" \
  --extra-vars "hub_cluster=${CLUSTER_NAME}" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}"

# Query the prepared seed directly; no changes to the playbook image are needed.
echo "Recording the installed seed OpenShift version for preinstall."
SEED_METADATA_DIR=$(mktemp -d /tmp/ibi-seed-version.XXXXXX)
trap 'rm -rf -- "${SEED_METADATA_DIR}"' EXIT
SEED_QUERY_RC=0
ansible bastion \
  -i "${INVENTORY_PATH}/build-inventory.py" \
  -m kubernetes.core.k8s_info \
  -a "kubeconfig=/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig api_version=config.openshift.io/v1 kind=ClusterVersion name=version" \
  --tree "${SEED_METADATA_DIR}" >"${SEED_METADATA_DIR}/ansible.log" 2>&1 || SEED_QUERY_RC=$?

python3 - "${SEED_METADATA_DIR}/bastion" "${SHARED_DIR}/ibi-seed-version" \
  "${SEED_QUERY_RC}" "${SEED_METADATA_DIR}/ansible.log" \
  "${ARTIFACT_DIR}/ibi-seed-version-error.json" <<'PY'
import json
import pathlib
import re
import sys

query_rc = int(sys.argv[3])
try:
    result = json.loads(pathlib.Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    if not query_rc:
        raise
    result = {}

if query_rc:
    # Publish selected diagnostics only; raw output and resources stay private.
    if not isinstance(result, dict):
        result = {}
    message = result.get("msg")
    if message is None or message == "":
        output = pathlib.Path(sys.argv[4]).read_text(errors="replace")
        output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output)
        message = "\n".join(re.findall(
            r"(?m)^(?:ERROR!|\[ERROR\]|[\w.]+(?:Error|Exception):)[^\n]*", output
        )) or "Ansible failed without a readable host error."
    if (result.get("_ansible_no_log") or result.get("censored")
            or not isinstance(message, str)
            or re.search(
                r"(?i)authorization|bearer|\bbasic\b|password|passwd|token|"
                r"api[_-]?key|private[ _-]?key|client[-_]key[-_]data|"
                r"client[-_]certificate[-_]data|certificate[-_]authority[-_]data|"
                r"ansible_\w+[\"']?\s*[:=]|[\"']?(?:clusters|contexts|users)[\"']?\s*:", message)):
        message = "Ansible error details withheld because they may contain credentials or configuration."
    message = re.sub(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s\"'<>]+", "[REDACTED_URL]", message)
    message = re.sub(
        r"(?i)\b(host|hostname|server)[\"']?\s*[:=]\s*(?:'[^']*'|\"[^\"]*\"|[^\s,)]+)",
        r"\1=[REDACTED_HOST]", message,
    )
    message = re.sub(
        r"(?i)(\b(?:connect to host|resolve hostname|connection to)\s+)\S+",
        r"\1[REDACTED_HOST]", message,
    )
    diagnostic = {
        "ansible_exit_code": query_rc,
        "failed": result.get("failed") if isinstance(result.get("failed"), bool) else None,
        "unreachable": result.get("unreachable") if isinstance(result.get("unreachable"), bool) else None,
        "message": message[:4000],
    }
    report = pathlib.Path(sys.argv[5])
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(diagnostic, indent=2) + "\n")
    print(json.dumps(diagnostic), file=sys.stderr)
    raise SystemExit(1)

resources = result.get("resources", [])
if result.get("failed") or result.get("unreachable") or len(resources) != 1:
    raise SystemExit("Expected one ClusterVersion result from seed preparation.")

status = resources[0].get("status", {})
version = status.get("desired", {}).get("version", "")
history = status.get("history", [])
if (
    not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?", version)
    or not history
    or history[0].get("state") != "Completed"
    or history[0].get("version") != version
):
    raise SystemExit("The seed must have a completed OpenShift release before recording its version.")

pathlib.Path(sys.argv[2]).write_text(version + "\n")
print(f"Recorded seed OpenShift version: {version}")
PY
