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
if ! ansible bastion \
  -i "${INVENTORY_PATH}/build-inventory.py" \
  -m kubernetes.core.k8s_info \
  -a "kubeconfig=/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig api_version=config.openshift.io/v1 kind=ClusterVersion name=version" \
  --tree "${SEED_METADATA_DIR}" >/dev/null; then
  echo "Could not read the seed ClusterVersion from the seed bastion." >&2
  exit 1
fi

python3 - "${SEED_METADATA_DIR}/bastion" "${SHARED_DIR}/ibi-seed-version" <<'PY'
import json
import pathlib
import re
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
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
