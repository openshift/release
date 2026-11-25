#!/usr/bin/env bash

set -ex

function ocp_version() {
    oc get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F "." '{print $1"."$2}'
}
if [[ ! "${CNV_SUBSCRIPTION_SOURCE}" =~ ^(cnv-prerelease-catalog-source|redhat-operators)$ ]]
then
    echo "CNV_SUBSCRIPTION_SOURCE environment variable value '${CNV_SUBSCRIPTION_SOURCE}' not allowed, allowed values are 'redhat-operators' or 'cnv-prerelease-catalog-source'"
    exit 1
fi

# Fail fast on a quiet period the convergence barrier could never reach, instead
# of at the end of MGMT_CONVERGENCE_TIMEOUT.
for setting in MGMT_CONVERGENCE_TIMEOUT MGMT_CONVERGENCE_QUIET_PERIOD
do
    if [[ ! "${!setting}" =~ ^[0-9]+$ ]]
    then
        echo "${setting} environment variable value '${!setting}' is not a whole number of seconds"
        exit 1
    fi
done
if [[ "${MGMT_CONVERGENCE_QUIET_PERIOD}" -ge "${MGMT_CONVERGENCE_TIMEOUT}" ]]
then
    echo "MGMT_CONVERGENCE_QUIET_PERIOD '${MGMT_CONVERGENCE_QUIET_PERIOD}' must be smaller than MGMT_CONVERGENCE_TIMEOUT '${MGMT_CONVERGENCE_TIMEOUT}'"
    exit 1
fi


function add_pullsecret() {
  local REGISTRY=$1
  local USERNAME=$2
  local PASSWORD=$3

  oc extract secret/pull-secret -n openshift-config --keys=.dockerconfigjson --to=/tmp --confirm

  jq --arg reg "$REGISTRY" --arg user "$USERNAME" --arg pass "$PASSWORD" \
     '.auths[$reg] = {auth: ($user + ":" + $pass | @base64)}' \
     /tmp/.dockerconfigjson > /tmp/.dockerconfigjson.new

  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/.dockerconfigjson.new

  rm /tmp/.dockerconfigjson /tmp/.dockerconfigjson.new
}


# oc get has no deadline of its own, so bound it: an apiserver that accepts
# connections but stops answering would otherwise hold the barrier open past
# MGMT_CONVERGENCE_TIMEOUT. oc wait is already bounded by its own --timeout.
OC_REQUEST_TIMEOUT="60s"

# A pool keeps reporting Updated=True for its previous configuration until the
# MCO renders the new MachineConfigs, so first check that the ones created by
# CNV's virt-platform-autopilot have reached their pool. The autopilot labels
# them, so ask the apiserver for the ones belonging to each pool that exists
# rather than matching names here: a role no pool is named after, such as one
# the autopilot renders for a pool this cluster does not have, then never holds
# the barrier open.
# Any failed query returns non-zero, so an unanswered apiserver reads as "not
# applied" rather than as "nothing left to apply".
function autopilot_configs_applied() {
  local pools pool configs config applied
  pools="$(oc get mcp -o name --request-timeout="${OC_REQUEST_TIMEOUT}")" || return 1
  while read -r pool; do
    [[ -n "${pool}" ]] || continue
    pool="${pool##*/}"
    configs="$(oc get machineconfig -o name --request-timeout="${OC_REQUEST_TIMEOUT}" \
      -l "machineconfiguration.openshift.io/role=${pool},${MGMT_AUTOPILOT_MC_SELECTOR}")" || return 1
    [[ -n "${configs}" ]] || continue
    applied="$(oc get mcp "${pool}" -o jsonpath='{.status.configuration.source[*].name}' --request-timeout="${OC_REQUEST_TIMEOUT}")" || return 1
    while read -r config; do
      [[ -n "${config}" ]] || continue
      config="${config##*/}"
      if ! tr ' ' '\n' <<<"${applied}" | grep -qx "${config}"; then
        echo "MachineConfigPool ${pool} has not applied ${config} yet"
        return 1
      fi
    done <<<"${configs}"
  done <<<"${pools}"
}

# $1 is how long to wait for the pools to finish updating.
function management_nodes_settled() {
  autopilot_configs_applied &&
    oc wait mcp --all --for=condition=Updated=True --timeout="$1" >/dev/null &&
    oc wait mcp --all --for=condition=Updating=False --timeout=0s >/dev/null &&
    oc wait mcp --all --for=condition=Degraded=False --timeout=0s >/dev/null &&
    oc wait node --all --for=condition=Ready --timeout=0s >/dev/null
}

# The MachineConfigs created by virt-platform-autopilot (psi kernel argument,
# swap) make the MCO reboot every node of their pools, and HyperConverged
# Available says nothing about that rollout. Masters are schedulable here and
# host hosted control plane pods including etcd, so a rollout that is still in
# flight takes the hosted cluster down mid-test. Wait for it to finish and for
# the nodes to stay settled for a quiet period, so a rollout starting late is
# caught too.
function wait_for_management_nodes() {
  local deadline=$(( SECONDS + MGMT_CONVERGENCE_TIMEOUT ))
  local stable_since="" timeout
  echo "Waiting up to ${MGMT_CONVERGENCE_TIMEOUT}s for the management nodes to settle on their MachineConfigs"
  while (( SECONDS < deadline )); do
    # Block until the rollout is over, then only sample during the quiet period
    # so that anything going unhealthy restarts it.
    timeout="$(( deadline - SECONDS ))s"
    if [[ -n "${stable_since}" ]]; then
      timeout=0s
    fi
    if management_nodes_settled "${timeout}"; then
      stable_since="${stable_since:-${SECONDS}}"
      if (( SECONDS - stable_since >= MGMT_CONVERGENCE_QUIET_PERIOD )); then
        echo "Management nodes stayed settled for ${MGMT_CONVERGENCE_QUIET_PERIOD}s"
        return 0
      fi
    else
      stable_since=""
    fi
    sleep 15
  done
  echo "Error: management nodes did not settle within ${MGMT_CONVERGENCE_TIMEOUT}s"
  oc get mcp -o wide --request-timeout="${OC_REQUEST_TIMEOUT}" || true
  oc get nodes -o wide --request-timeout="${OC_REQUEST_TIMEOUT}" || true
  oc get machineconfig --request-timeout="${OC_REQUEST_TIMEOUT}" || true
  return 1
}

# Get yq tool
YQ="/tmp/yq"
curl -L -o ${YQ} https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
chmod +x ${YQ}

# Dynamically get CNV catalog image and channel that were provided to the job via gangway API
CNV_PRERELEASE_CATALOG_IMAGE=$(curl -s https://prow.ci.openshift.org/prowjob?prowjob="${PROW_JOB_ID}" |\
  ${YQ} e '.spec.pod_spec.containers[0].env[] | select(.name == "CNV_PRERELEASE_CATALOG_IMAGE") | .value')
CNV_SUBSCRIPTION_CHANNEL=$(curl -s https://prow.ci.openshift.org/prowjob?prowjob="${PROW_JOB_ID}" |\
  ${YQ} e '.spec.pod_spec.containers[0].env[] | select(.name == "CNV_CHANNEL") | .value')

if [ "${CNV_SUBSCRIPTION_SOURCE}" == "redhat-operators" ]
then
  CNV_RELEASE_CHANNEL=stable
elif [ -n "${CNV_PRERELEASE_CATALOG_IMAGE}" ] && [ -n "${CNV_SUBSCRIPTION_CHANNEL}" ]
then
  CNV_RELEASE_CHANNEL=${CNV_SUBSCRIPTION_CHANNEL}
else
  CNV_RELEASE_CHANNEL=nightly-$(ocp_version)
  CNV_PRERELEASE_CATALOG_IMAGE=quay.io/openshift-cnv/nightly-catalog:$(ocp_version)
fi

# The kubevirt tests require wildcard routes to be allowed
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

# Make the masters schedulable so we have more capacity to run VMs
CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ ${CONTROL_PLANE_TOPOLOGY} != "External" ]]
then
  oc patch scheduler cluster --type=json -p '[{ "op": "replace", "path": "/spec/mastersSchedulable", "value": true }]'
fi

# In case of nested-mgmt topology where there's only one worker node, we need to label it as a master
# in order to get some kubevirt components to be scheduled. This is needed since CNV 4.17.0+
if [[ $(oc get nodes --no-headers | wc -l) -eq 1 ]]
then
	NODENAME=$(oc get nodes -o jsonpath='{.items[].metadata.name}')
	oc label node ${NODENAME} node-role.kubernetes.io/control-plane=
fi

if [ -n "${CNV_PRERELEASE_CATALOG_IMAGE}" ]
then
  if [[ "${CNV_PRERELEASE_CATALOG_IMAGE}" == *"brew"* ]]; then
    # Add brew registry pull secret
    add_pullsecret "brew.registry.redhat.io" "${BREW_IMAGE_REGISTRY_USERNAME}" "$(cat "${BREW_IMAGE_REGISTRY_TOKEN_PATH}")"

    # Deploy IDMS for brew registry
    cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: brew-idms
spec:
  imageDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry.redhat.io
EOF
  elif [[ "${CNV_PRERELEASE_CATALOG_IMAGE}" == *"quay"* ]]; then
    # Add quay registry pull secret for cnv nightly channel
    QUAY_USERNAME=openshift-cnv+openshift_ci
    QUAY_PASSWORD=$(cat /etc/cnv-nightly-pull-credentials/openshift_cnv_pullsecret)
    add_pullsecret "quay.io/openshift-cnv" "${QUAY_USERNAME}" "${QUAY_PASSWORD}"
  fi

  # Wait for MCPs to reach stable state after pull secret change
  # MCPs may already be updated or may need to update - just ensure they're stable
  oc wait mcp master worker --for condition=Updated=True --timeout=20m

  # Create a catalog source for the pre-release builds
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cnv-prerelease-catalog-source
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${CNV_PRERELEASE_CATALOG_IMAGE}
  displayName: OpenShift Virtualization Pre-Release Catalog
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 8h
EOF
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: ${CNV_RELEASE_CHANNEL}
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: ${CNV_SUBSCRIPTION_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

sleep 30

RETRIES=30
CSV=
for i in $(seq ${RETRIES}); do
  if [[ -z ${CSV} ]]; then
    CSV=$(oc get subscription -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.installedCSV}')
  fi
  if [[ -z ${CSV} ]]; then
    echo "Try ${i}/${RETRIES}: can't get the CSV yet. Checking again in 30 seconds"
    sleep 30
  fi
  if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "CNV is deployed"
    break
  else
    echo "Try ${i}/${RETRIES}: CNV is not deployed yet. Checking again in 30 seconds"
    sleep 30
  fi
done

if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
  echo "Error: Failed to deploy CNV"
  echo "CSV ${CSV} YAML"
  oc get CSV ${CSV} -n openshift-cnv -o yaml
  echo
  echo "CSV ${CSV} Describe"
  oc describe CSV ${CSV} -n openshift-cnv
  exit 1
fi

# Deploy HyperConverged custom resource to complete kubevirt's installation
oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  featureGates:
    enableCommonBootImageImport: false
  logVerbosityConfig:
    kubevirt:
      virtLauncher: 8
      virtHandler: 8
      virtController: 8
      virtApi: 8
      virtOperator: 8
EOF

oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m

# CNV is installed, but the MachineConfig rollout it triggers may still be in
# flight. Do not let the step report success until the management nodes are back.
# A hosted management cluster has no MachineConfigPools to wait for.
if [[ ${CONTROL_PLANE_TOPOLOGY} != "External" ]]
then
  wait_for_management_nodes
fi

# CDI auto-detects only volumeMode=Block for gp3-csi in its StorageProfile, and a
# DataVolume that asks for Filesystem without naming its access modes then has
# nothing to take them from and never binds. Advertise Filesystem as well so such
# a DataVolume can bind, but keep Block first: CDI picks the first claimPropertySet
# for a DataVolume that names no volumeMode at all, and on gp3-csi a Filesystem
# root disk is an image file that CDI sizes to the free space of the PVC's
# filesystem and KubeVirt resizes again on every start of the domain. A guest that
# reboots out of its Ignition first boot then comes back to a smaller disk than the
# GPT that first boot grew to the end of, and drops into the dracut emergency shell.
if oc get storageprofile gp3-csi &>/dev/null; then
  echo "Patching gp3-csi StorageProfile to also advertise Filesystem volumeMode"
  oc patch storageprofile gp3-csi --type=merge -p \
    '{"spec":{"claimPropertySets":[{"accessModes":["ReadWriteOnce"],"volumeMode":"Block"},{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}]}}'
fi

echo "Installing VM console logger in order to aid debugging potential VM boot issues"
oc apply -f https://raw.githubusercontent.com/davidvossel/kubevirt-console-debugger/main/kubevirt-console-logger.yaml


if [ "$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "Azure" ];
then
  # Pin cpuModel to Broadwell in case of Azure cluster, to avoid discrepancies between the cluster nodes
  PATCH_COMMAND="oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=json -p='[{\"op\": \"add\", \"path\": \"/spec/defaultCPUModel\", \"value\": \"Broadwell\"}]'"
  MAX_RETRIES=5
  for ((i=1; i<=MAX_RETRIES; i++)); do
    echo "Attempt $i of $MAX_RETRIES..."
    if eval $PATCH_COMMAND; then
      echo "Patch succeeded."
      exit 0
    else
      echo "Patch failed. Retrying in 2 seconds..."
      sleep 2
    fi
  done

  echo "Patch failed after $MAX_RETRIES attempts."
  exit 1
fi
