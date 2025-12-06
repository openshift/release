#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

HOSTED_CLUSTER_NAME="$(<"${SHARED_DIR}/hostedcluster_name")"
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

HOSTED_CLUSTER_NS=$(oc get -A hostedclusters.hypershift.openshift.io -o=jsonpath="{.items[?(@.metadata.name=='$HOSTED_CLUSTER_NAME')].metadata.namespace}")
AGENT_NAMESPACE="${HOSTED_CLUSTER_NS}-${HOSTED_CLUSTER_NAME}"

oc get ns "${AGENT_NAMESPACE}" || oc create namespace "${AGENT_NAMESPACE}"

if ! oc get secret pull-secret -n "${AGENT_NAMESPACE}"; then
    oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
    oc create secret generic pull-secret --from-file=.dockerconfigjson=/tmp/.dockerconfigjson \
      --type=kubernetes.io/dockerconfigjson -n "${AGENT_NAMESPACE}"
fi

oc apply -f - <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}
  namespace: ${AGENT_NAMESPACE}
spec:
  cpuArchitecture: ${ADDITIONAL_WORKER_ARCHITECTURE}
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

# Wait until ISO is generated for InfraEnv
oc wait --for=condition=ImageCreated infraenv/${HOSTED_CLUSTER_NAME} -n ${AGENT_NAMESPACE} --timeout=5m

# shellcheck disable=SC2154
# We use the additional workers implemented for heterogeneous clusters as nodes for the hypershift hosted cluster
for bmhost in $(yq -o=j -I=0 e '.[] | select(.name|test("worker-a"))' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ] || [ ${#ipv6} -eq 0 ]; then
    echo "[ERROR] Unable to parse the Bare Metal Host metadata"
    exit 1
  fi
  network_config="interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: true
      ipv6:
        enabled: true
        dhcp: true"
  # split the ipi_disabled_ifaces semi-comma separated list into an array
  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
  for iface in "${ipi_disabled_ifaces[@]}"; do
    # Take care of the indentation when adding the disabled interfaces to the above yaml
    network_config+="
    - name: ${iface}
      type: ethernet
      state: up
      ipv4:
        enabled: false
        dhcp: false
      ipv6:
        enabled: false
        dhcp: false"
  done

  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${name}-bmc-secret
  namespace: ${AGENT_NAMESPACE}
type: Opaque
stringData:
  username: "${redfish_user}"
  password: "${redfish_password}"
---
apiVersion: v1
kind: Secret
metadata:
  name: ${name}-network-config-secret
  namespace: ${AGENT_NAMESPACE}
stringData:
  nmstate: |
    ${network_config}
  networkData: ""
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${AGENT_NAMESPACE}
  labels:
    infraenvs.agent-install.openshift.io: ${HOSTED_CLUSTER_NAME}
  annotations:
    inspect.metal3.io: disabled
    bmac.agent-install.openshift.io/hostname: ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}
spec:
  automatedCleaningMode: disabled
  architecture: ${ADDITIONAL_WORKER_ARCHITECTURE}
  bmc:
    address: ${redfish_scheme}://${bmc_address}${redfish_base_uri}
    disableCertificateVerification: true
    credentialsName: ${name}-bmc-secret
  bootMACAddress: ${mac}
  online: true
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  networkData:
    name: ${name}-network-config-secret
    namespace: ${AGENT_NAMESPACE}
EOF

  # Wait for BMH to reach available state before proceeding to next host
  echo "[INFO] Waiting for BMH ${name} to become available..."
  retries=3
  for attempt in $(seq 1 ${retries}); do
    # Wait for BMH to reach 'available' state (ready to be provisioned)
    timeout_seconds=1200  # 20 minutes
    elapsed=0
    while [ ${elapsed} -lt ${timeout_seconds} ]; do
      bmh_state=$(oc get -n "${AGENT_NAMESPACE}" bmh/${name} -o jsonpath='{.status.provisioning.state}' 2>/dev/null || echo "")
      if [ "${bmh_state}" = "available" ]; then
        echo "[INFO] BMH ${name} is available after attempt ${attempt}"
        break 2  # Break out of both loops
      elif [ "${bmh_state}" = "provisioning" ] || [ "${bmh_state}" = "provisioned" ]; then
        echo "[INFO] BMH ${name} is already being provisioned (state: ${bmh_state})"
        break 2  # Break out of both loops - this is also acceptable
      fi
      echo "[DEBUG] BMH ${name} state: ${bmh_state}, waiting..."
      sleep 30
      elapsed=$((elapsed + 30))
    done
    
    if [ ${elapsed} -ge ${timeout_seconds} ] && [ ${attempt} -lt ${retries} ]; then
      echo "[WARN] BMH ${name} not available on attempt ${attempt}/${retries}, retrying in 60 seconds..."
      sleep 60
    elif [ ${elapsed} -ge ${timeout_seconds} ]; then
      echo "[ERROR] BMH ${name} failed to become available after ${retries} attempts"
      oc get -n "${AGENT_NAMESPACE}" bmh/${name} -o yaml || true
      oc describe -n "${AGENT_NAMESPACE}" bmh/${name} || true
      exit 1
    else
      break  # Success, exit retry loop
    fi
  done
  
  # Add delay between BMH creations to avoid race conditions
  echo "[INFO] Waiting 30 seconds before creating next BMH..."
  sleep 30
done

nodepool_expected_size=$(yq e '[.[] | select(.name|test("worker-a"))]|length' "${SHARED_DIR}/hosts.yaml")

retries=30
for i in $(seq 1 ${retries}) max; do
    if [ "${i}" == "max" ]; then
        echo "[ERROR] Timeout waiting for agent resources to be created"
        exit 1
    fi
    count="$(oc get -n "${AGENT_NAMESPACE}" --no-headers --ignore-not-found agents.agent-install.openshift.io | wc -l)"
    if [ "${count}" == "${nodepool_expected_size}" ] ; then
        echo "[INFO] Agent objects exist. Continuing"
        break
    fi
    echo "[WARN] The agent objects did not reconcile yet. Waiting for 60 seconds. Attempt ${i}/${retries}"
    sleep 60
done

oc wait -n "${AGENT_NAMESPACE}" agents.agent-install.openshift.io --all=true --for=condition=RequirementsMet

echo "[INFO] Scaling the nodepool to $nodepool_expected_size"
oc scale -n "${HOSTED_CLUSTER_NS}" --replicas "${nodepool_expected_size}" nodepools.hypershift.openshift.io "${HOSTED_CLUSTER_NAME}"
echo "[WAIT] Wait for the agents to be added to the existing cluster"
oc wait -n "${AGENT_NAMESPACE}" --all=true \
  --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=30m agents.agent-install.openshift.io

oc get -n "${AGENT_NAMESPACE}" -o yaml infraenvs.agent-install.openshift.io "${HOSTED_CLUSTER_NAME}" > "${ARTIFACT_DIR}/InfraEnv.yaml"
oc get -n "${AGENT_NAMESPACE}" -o yaml baremetalhosts.metal3.io > "${ARTIFACT_DIR}/extra_baremetalhosts.yaml"
