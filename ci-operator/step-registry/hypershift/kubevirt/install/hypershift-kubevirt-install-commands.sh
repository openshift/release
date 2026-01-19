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

  oc wait mcp master worker --for condition=Updating=True --timeout=5m
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
