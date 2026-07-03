#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

[ -s "${KUBECONFIG}" ]

# Flatten KUBECONFIG to embed certs inline — required by benchmark-runner Python client.
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

function BenchmarkRunnerDebug () {
    oc get all -n benchmark-runner 2>&1 || true
    oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>&1 || true
    oc get vmi -n benchmark-runner -o yaml 2>&1 || true
    oc get dv -n benchmark-runner 2>&1 || true
    oc describe dv -n benchmark-runner 2>&1 || true
    oc describe pod -n benchmark-runner -l cdi.kubevirt.io=importer 2>&1 || true
    oc logs -n benchmark-runner -l cdi.kubevirt.io=importer --tail=200 --prefix 2>&1 || true
    oc get deployment -n openshift-storage 2>&1 || true
    oc get storageclass 2>&1 || true
    oc get route default-route -n openshift-image-registry 2>&1 || true
    oc get events -n openshift-image-registry --sort-by='.lastTimestamp' 2>&1 || true
    oc get imagestream win10 -n openshift-virtualization-os-images -o yaml 2>&1 || true
}
function _on_exit () {
    local _rc=$?
    rm -f "${PULL_SECRET_FILE:-}"
    [[ ${_rc} -eq 0 ]] || BenchmarkRunnerDebug
}
# ERR omitted — double-fires with EXIT on failure
# TERM ($? may be 0 at signal time): always collect debug regardless
trap BenchmarkRunnerDebug TERM
trap _on_exit EXIT

set +x
KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
PAAS_USER=$(cat /var/run/secrets/windows-vm/paas-username)
PAAS_PASS=$(cat /var/run/secrets/windows-vm/paas-password)
SCALE_NODES=$(oc get nodes -l kubevirt.io/schedulable=true -o jsonpath-as-json='{.items[*].metadata.name}' | jq -r '[ .[] | "'"'"'" + . + "'"'"'" ] | "[" + join(", ") + "]"')
set -x
export KUBEADMIN_PASSWORD SCALE_NODES

export CREATE_VMS_ONLY=True

oc create namespace benchmark-runner --dry-run=client -o json --save-config | oc apply -f -

if oc get daemonset virt-handler -n openshift-cnv --ignore-not-found -o name | grep -q .; then
    oc rollout status daemonset/virt-handler -n openshift-cnv --timeout=5m
    oc rollout status deployment/virt-controller -n openshift-cnv --timeout=3m
    oc rollout status deployment/virt-api -n openshift-cnv --timeout=3m
    sleep 10
    typeset -i schedulableNodeCnt
    schedulableNodeCnt=$(
        oc get nodes \
            -l kubevirt.io/schedulable=true \
            -o jsonpath-as-json='{.items[*].metadata.name}' |
        jq 'length'
    )
    : "${schedulableNodeCnt} nodes with kubevirt.io/schedulable=true"
fi

# ODF 4.21 renamed csi-rbdplugin-provisioner to the FQDN form; created before
# StorageCluster Available so rollout status completes immediately
oc rollout status deployment/openshift-storage.rbd.csi.ceph.com-ctrlplugin \
    -n openshift-storage --timeout=10m

oc get storageclass ocs-storagecluster-ceph-rbd-virtualization -o name

# ── Mirror PaaS Windows image → cluster internal registry ────────────────────
WIN_NS='openshift-virtualization-os-images'
WIN_NAME='win10'
WIN_TAG='latest'
PAAS_IMAGE='images.paas.redhat.com/ieng/vm-img--rhov/ieng--windows--master:win10-amd64-latest'
CDI_REGISTRY='image-registry.openshift-image-registry.svc:5000'

# Enable the default internal registry route so we can push from this pod
if ! oc get route default-route -n openshift-image-registry --ignore-not-found -o name | grep -q .; then
    oc patch configs.imageregistry.operator.openshift.io/cluster \
        --type=merge -p '{"spec":{"defaultRoute":true}}'
    timeout 3m bash -c '
        until oc get route default-route -n openshift-image-registry -o name &>/dev/null; do
            echo "Waiting for internal registry route..."
            sleep 5
        done
    '
fi
REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
: "Internal registry external route: ${REGISTRY}"

oc create namespace "${WIN_NS}" --dry-run=client -o json --save-config | oc apply -f -

# Allow the default service account in benchmark-runner to pull from WIN_NS
oc policy add-role-to-user system:image-puller \
    system:serviceaccount:benchmark-runner:default \
    -n "${WIN_NS}" || true

# Build a temporary auth config for oc image mirror:
#   source → PaaS registry (PAAS_USER:PAAS_PASS)
#   dest   → cluster external registry route (unused:OCP-token)
PULL_SECRET_FILE=$(mktemp /tmp/pull-secret-XXXXXX.json)
set +x
OCP_API=$(oc whoami --show-server)
oc login "${OCP_API}" -u kubeadmin -p "${KUBEADMIN_PASSWORD}" --insecure-skip-tls-verify >/dev/null
OCP_TOKEN=$(oc whoami -t)
python3.14 - "${PULL_SECRET_FILE}" "${PAAS_USER}" "${PAAS_PASS}" "${OCP_TOKEN}" "${REGISTRY}" <<'PYEOF'
import sys, json, base64
dest_file, paas_user, paas_pass, ocp_token, registry = sys.argv[1:]
config = {
    "auths": {
        "images.paas.redhat.com": {
            "auth": base64.b64encode(f"{paas_user}:{paas_pass}".encode()).decode()
        },
        registry: {
            "auth": base64.b64encode(f"unused:{ocp_token}".encode()).decode()
        }
    }
}
with open(dest_file, 'w') as f:
    json.dump(config, f)
PYEOF
set -x

: "Mirroring ${PAAS_IMAGE} → ${REGISTRY}/${WIN_NS}/${WIN_NAME}:${WIN_TAG}"
oc image mirror \
    --registry-config="${PULL_SECRET_FILE}" \
    --insecure \
    "${PAAS_IMAGE}=${REGISTRY}/${WIN_NS}/${WIN_NAME}:${WIN_TAG}"

rm -f "${PULL_SECRET_FILE}"

# Create a pull secret for CDI to authenticate against the internal registry
# CDI importer pod uses the service-address (not the external route)
set +x
oc create secret docker-registry windows-paas-pull-secret \
    -n benchmark-runner \
    --docker-server="${CDI_REGISTRY}" \
    --docker-username=unused \
    --docker-password="${OCP_TOKEN}" \
    --dry-run=client -o yaml | oc apply -f -
set -x

# Patch benchmark-runner's windows DV template to use source.registry instead
# of source.http — the template is shipped inside the container image
BR_SITE_PKG=$(python3.14 -c \
    "import benchmark_runner, os; print(os.path.dirname(benchmark_runner.__file__))")
BR_DV_TMPL="${BR_SITE_PKG}/common/template_operations/templates/windows/internal_data/windows_dv_template.yaml"
python3.14 - "${BR_DV_TMPL}" <<'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
patched = content.replace(
    '  source:\n      http:\n         url: {{ url }}',
    '  source:\n      registry:\n         url: {{ url }}\n         secretRef: windows-paas-pull-secret'
)
if patched == content:
    print(f"ERROR: pattern not found in {path} — check template indentation", flush=True)
    sys.exit(1)
open(path, 'w').write(patched)
print(f"Patched {path}:")
print(open(path).read())
PYEOF

export WINDOWS_URL="docker://${CDI_REGISTRY}/${WIN_NS}/${WIN_NAME}:${WIN_TAG}"

buildVersion=$(
    curl -s "https://pypi.org/pypi/benchmark-runner/json" |
    python3.14 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" ||
    echo "1.0.0"
)
export BUILD_VERSION="${buildVersion}"

export RUN_TYPE="${RUN_TYPE:-test_ci}"

: "Creating Windows VM: workload=${WORKLOAD} scale=${SCALE} image=${WINDOWS_IMAGE}"
python3.14 /benchmark_runner/main/main.py
