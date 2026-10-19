#!/bin/bash
set +x
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

OCP_DEPLOYMENT_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
CNF_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

echo "=== IBI Seed eco-gotests Configuration ==="
echo "SEED_SPOKE_CLUSTER=${SEED_SPOKE_CLUSTER}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"
echo "VERSION=${VERSION}"
echo ""

# Copy inventory from SHARED_DIR (processed by earlier hub-deploy step)
echo "=== Copying inventory for seed hub ${CLUSTER_NAME} from SHARED_DIR ==="

mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/all"       "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions"  "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
cp "${SHARED_DIR}/nodes"     "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
cp "${SHARED_DIR}/masters"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
cp "${SHARED_DIR}/bastion"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"

mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

cp "${SHARED_DIR}/bastions" "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
cp "${SHARED_DIR}/all"      "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
cp "${SHARED_DIR}/bastion"  "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"

echo "Inventory copied from SHARED_DIR"

echo ""
echo "=== Step 1: Check saved seed kubeconfig on the seed bastion ==="
cd /eco-ci-cd
SEED_SPOKE_KUBECONFIG="/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig"
# Preparation must run before ACM detachment. Do not fetch the hub Secret here.
if ! ansible bastion \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  -m ansible.builtin.shell \
  -a "test -r '${SEED_SPOKE_KUBECONFIG}' && test -s '${SEED_SPOKE_KUBECONFIG}'"; then
  echo "Seed kubeconfig is missing, empty, or unreadable on the seed bastion. Run ibi-seed-prepare before ibu-prune-argocd-apps." >&2
  exit 1
fi

echo ""
echo "=== Step 2: Generate eco-gotests IBI seedgeneration script ==="

ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"

ansible-playbook playbooks/deploy-run-eco-gotests.yaml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}" \
  --extra-vars "features=${ECO_GOTESTS_FEATURES}" \
  --extra-vars 'labels=!no-container' \
  --extra-vars 'eco_worker_label=""' \
  --extra-vars 'eco_cnf_core_net_switch_user=""' \
  --extra-vars 'eco_cnf_core_net_switch_pass=""' \
  --extra-vars 'eco_gotests_tag=latest' \
  --extra-vars "additional_test_env_variables=\"${ECO_GOTESTS_ENV_VARS}\""

# Preparation above removes the old test directory before creating this launcher.
printf '%s\n' /tmp/eco_gotests/report > "${SHARED_DIR}/ibi-rp-seedgen-dir"

echo ""
# Capture floating catalog identities while the seed API is still available.
# The later mirror step must use these exact manifests, not a newer :latest.
CATALOG_WORK=$(mktemp -d /tmp/ibi-seed-catalogs.XXXXXX)
trap 'rm -rf -- "$CATALOG_WORK"' EXIT
cp /var/group_variables/common/all/ansible_ssh_private_key "$CATALOG_WORK/ssh-key"
chmod 600 "$CATALOG_WORK/ssh-key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")
[[ "$BASTION_IP" =~ ^[a-zA-Z0-9.-]+$ && "$BASTION_USER" =~ ^[a-zA-Z0-9_-]+$ ]]
[[ "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ && "$SEED_SPOKE_CLUSTER" =~ ^[a-z0-9-]+$ ]]
[[ "$MIRROR_REGISTRY" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]
SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
[[ "$SEED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]
rm -f -- "${SHARED_DIR}/ibi-seed-catalogs.json"
ssh -i "$CATALOG_WORK/ssh-key" -o BatchMode=yes -o ConnectTimeout=30 \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$BASTION_USER@$BASTION_IP" \
  "python3 - '$SEED_SPOKE_KUBECONFIG' '/home/telcov10n/project/generated/$CLUSTER_NAME/auth/kubeconfig' '$MIRROR_REGISTRY' '$SEED_VERSION'" \
  > "$CATALOG_WORK/catalogs.json" <<'PY'
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

spoke, hub, registry, version = sys.argv[1:]
os.umask(0o077)


def run(args, timeout=120):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(args[0] + " failed (exit " + str(result.returncode) + ")")
    return result.stdout


def get(kubeconfig, *args):
    return json.loads(run(["oc", "--kubeconfig", kubeconfig, "--request-timeout=60s",
                           *args, "-o", "json"]))


def repository(ref):
    ref = ref.split("@", 1)[0]
    return ref.rsplit(":", 1)[0] if ":" in ref.rsplit("/", 1)[-1] else ref


def digest(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


catalogs = get(spoke, "get", "catalogsources.operators.coreos.com", "-A")["items"]
pods = get(spoke, "get", "pods", "-A", "-l", "olm.catalogSource")["items"]
secret = get(hub, "-n", "openshift-config", "get", "secret", "pull-secret")
auths = json.loads(base64.b64decode(secret["data"][".dockerconfigjson"], validate=True))["auths"]
snapshots = {}
with tempfile.TemporaryDirectory(prefix="ibi-catalogs.") as scratch:
    auth = Path(scratch) / "auth.json"
    auth.write_text(json.dumps({"auths": {registry: auths[registry]}}))

    def raw(ref):
        return run(["skopeo", "inspect", "--raw", "--tls-verify=false",
                    "--authfile", str(auth), "docker://" + ref])

    for catalog in catalogs:
        ref = catalog.get("spec", {}).get("image", "")
        if not ref.startswith(registry + "/") or "@" in ref:
            continue
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9./_:-]*", ref):
            raise ValueError("Invalid catalog reference")
        if ":" not in ref.rsplit("/", 1)[-1]:
            ref += ":latest"
        manifest = raw(ref)
        captured = digest(manifest)
        allowed = {captured}
        index = json.loads(manifest)
        if "manifests" in index:
            children = [entry["digest"] for entry in index["manifests"]
                        if entry.get("platform", {}).get("os") == "linux"
                        and entry.get("platform", {}).get("architecture") == "amd64"]
            if len(children) != 1 or digest(raw(repository(ref) + "@" + children[0])) != children[0]:
                raise ValueError("Catalog lacks a verified linux/amd64 manifest")
            allowed.add(children[0])
        meta = catalog["metadata"]
        matches = [pod for pod in pods
                   if pod["metadata"]["namespace"] == meta["namespace"]
                   and pod["metadata"].get("labels", {}).get("olm.catalogSource") == meta["name"]
                   and not pod["metadata"].get("deletionTimestamp")]
        if len(matches) != 1:
            raise ValueError("Expected one active seed catalog Pod: " + meta["name"])
        pod = matches[0]
        if not any(c.get("type") == "Ready" and c.get("status") == "True"
                   for c in pod.get("status", {}).get("conditions", [])):
            raise ValueError("Seed catalog Pod is not Ready: " + meta["name"])
        names = {c["name"] for c in pod["spec"]["containers"] if repository(c["image"]) == repository(ref)}
        statuses = [s for s in pod.get("status", {}).get("containerStatuses", [])
                    if s["name"] in names and s.get("ready")]
        image_id = statuses[0].get("imageID", "") if len(statuses) == 1 else ""
        match = re.search(r"(sha256:[a-f0-9]{64})$", image_id)
        if not match or match.group(1) not in allowed:
            raise ValueError("Running catalog differs from registry snapshot: " + meta["name"])
        retained = repository(ref) + ":ibi-catalog-" + captured[7:]
        run(["skopeo", "copy", "--all", "--preserve-digests",
             "--authfile", str(auth), "--src-tls-verify=false", "--dest-tls-verify=false",
             "docker://" + repository(ref) + "@" + captured, "docker://" + retained], 600)
        if digest(raw(ref)) != captured or digest(raw(retained)) != captured:
            raise ValueError("Catalog changed during snapshot")
        if ref in snapshots and snapshots[ref] != captured:
            raise ValueError("Conflicting catalog snapshots")
        snapshots[ref] = captured
if not snapshots:
    raise ValueError("No local seed catalog tags were captured")
print(json.dumps({"registry": registry, "version": version, "catalogs": snapshots}, indent=2))
PY
cp "$CATALOG_WORK/catalogs.json" "${SHARED_DIR}/ibi-seed-catalogs.json"
echo "Seed catalog digests captured and retained."

echo "=== Step 2b: Run seedgeneration ==="
ansible-playbook playbooks/ran/ibu-run-seedgeneration.yml \
  -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
  --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
  --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}"

echo "Gather artifacts from bastion"
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$CATALOG_WORK/ssh-key" \
  "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests/report/*.xml" \
  "${ARTIFACT_DIR}/junit_eco_gotests/" || true

echo ""
echo "=== IBI Seed Eco-Gotests Complete ==="
echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
echo "Seed generation completed; the image is ready to mirror to the target registry."
