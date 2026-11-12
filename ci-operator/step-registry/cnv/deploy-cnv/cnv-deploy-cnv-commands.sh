#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck disable=SC1090
source <(curl -fsSL "https://raw.githubusercontent.com/openshift-cnv/cnv-ci/refs/heads/master/hack/shared-functions.sh")

CNV_IIB_CATALOG_NAME=cnv-iib-catalog
CNV_CATALOG_SOURCE=${CNV_CATALOG_SOURCE:-redhat-operators}
CNV_CATALOG_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_CNV_CATALOG_IMAGE:-${CNV_CATALOG_IMAGE:-}}" # IIB
CNV_HYPERCONVERGED_NAME=kubevirt-hyperconverged
CNV_INSTALL_NAMESPACE=openshift-cnv
CNV_OPERATOR_CHANNEL="${CNV_OPERATOR_CHANNEL:-stable}"
CNV_VERSION=${CNV_VERSION:?CNV_VERSION environment variable is required}
readonly IS_MCP_SERVER_DEPLOY="${IS_MCP_SERVER_DEPLOY:-false}"
# readonly CNV_MAJOR_MINOR=${CNV_VERSION%.*}
# CNV_STARTING_CSV="kubevirt-hyperconverged-operator.v${CNV_VERSION}"


wait_for_manual_debug() {
  echo "😵 Something went wrong, pause here to give yourself time to debug and investigate the issue"
  sleep 7200
}
trap wait_for_manual_debug ERR


create_cnv_catalog_source() {
  local catalog_source_name=${1}
  local catalog_image=${2}
  if [[ ${IS_MCP_SERVER_DEPLOY} == "true" ]]; then
    # MCP server evals need pull credentials for the IIB and mirrored bundles.
    add_cnv_pull_secrets
    oc wait mcp master worker --for=condition=Updated=True --timeout=20m
  fi
  (tee "${ARTIFACT_DIR}/${catalog_source_name}.yaml" | oc apply -o yaml -f -) <<__EOF__
    apiVersion: operators.coreos.com/v1alpha1
    kind: CatalogSource
    metadata:
      annotations:
        target.workload.openshift.io/management: '{"effect": "PreferredDuringScheduling"}'
      name: ${catalog_source_name}
      namespace: openshift-marketplace
    spec:
      displayName: OpenShift Virtualization Index Image
      sourceType: grpc
      image: ${catalog_image}
      publisher: Red Hat
      updateStrategy:
        registryPoll:
          interval: 10m
      icon:
        base64data: ""
        mediatype: ""
      priority: -100
      grpcPodConfig:
        extractContent:
          cacheDir: /tmp/cache
          catalogDir: /configs
        memoryTarget: 30Mi
        nodeSelector:
          kubernetes.io/os: linux
          node-role.kubernetes.io/master: ""
        priorityClassName: system-cluster-critical
        securityContextConfig: restricted
        tolerations:
        - effect: NoSchedule
          key: node-role.kubernetes.io/master
          operator: Exists
        - effect: NoExecute
          key: node.kubernetes.io/unreachable
          operator: Exists
          tolerationSeconds: 120
        - effect: NoExecute
          key: node.kubernetes.io/not-ready
          operator: Exists
          tolerationSeconds: 120

__EOF__
}

resolve_iib_from_map () {
    local iib_map_file_url="https://raw.githubusercontent.com/openshift-cnv/cnv-ci/refs/heads/master/version-mapping.json"
    local result
    result=$(curl -sL "${iib_map_file_url}" \
      | jq --arg version "${CNV_VERSION}" -r '.[$version].index_image // empty') || true
    echo "${result}"
}

add_cnv_pull_secrets() (
    local pull_secret_dir
    pull_secret_dir=$(mktemp -d)
    trap 'rm -rf "${pull_secret_dir}"' EXIT

    [[ -s "${BREW_IMAGE_REGISTRY_TOKEN_PATH}" && -s "${KONFLUX_REGISTRY_TOKEN_PATH}" ]] || {
        echo "Error: CNV registry pull token is missing or empty" >&2
        return 1
    }

    oc extract secret/pull-secret -n openshift-config \
      --keys=.dockerconfigjson --to="${pull_secret_dir}" --confirm

    jq --arg brew_user "${BREW_IMAGE_REGISTRY_USERNAME}" \
      --rawfile brew_token "${BREW_IMAGE_REGISTRY_TOKEN_PATH}" \
      --arg konflux_user "${KONFLUX_REGISTRY_USERNAME}" \
      --rawfile konflux_token "${KONFLUX_REGISTRY_TOKEN_PATH}" '
        .auths["brew.registry.redhat.io"] =
          {auth: ($brew_user + ":" + ($brew_token | rtrimstr("\n")) | @base64)}
        | .auths["quay.io/openshift-virtualization/konflux-builds"] =
          {auth: ($konflux_user + ":" + ($konflux_token | rtrimstr("\n")) | @base64)}
      ' \
      "${pull_secret_dir}/.dockerconfigjson" > "${pull_secret_dir}/.dockerconfigjson.new"

    oc set data secret/pull-secret -n openshift-config \
      --from-file=.dockerconfigjson="${pull_secret_dir}/.dockerconfigjson.new"
)

function apply_cnv_idms() {
    local cnv_version_dash="v${CNV_VERSION/./-}"
    local cnv_idms_file_url="https://raw.githubusercontent.com/openshift-cnv/cnv-ci/refs/heads/master/hack/cnv_idms.yaml"
    curl -sL "${cnv_idms_file_url}" \
      | sed "s/__CNV_VERSION__/${cnv_version_dash}/" | oc apply -f -
}

function apply_brew_idms() {
    local brew_idms_file_url="https://raw.githubusercontent.com/openshift-cnv/cnv-ci/refs/heads/master/hack/brew_idms.yaml"
    curl -sL "${brew_idms_file_url}" | oc apply -f -
}


### MAIN ###################################################################################

env::hash | grep -e "^CNV_" -e "^HCO_" | sort

if [[ -n $CNV_CATALOG_IMAGE ]]; then
  CNV_CATALOG_IMAGE="${CNV_CATALOG_IMAGE/registry-proxy.engineering.redhat.com/brew.registry.redhat.io}"
  CNV_CATALOG_SOURCE=${CNV_IIB_CATALOG_NAME}
  create_cnv_catalog_source "${CNV_IIB_CATALOG_NAME}" "${CNV_CATALOG_IMAGE}"
  make_sure_all_catalog_source_are_healthy 600 10
fi

if [[ -z ${CNV_CATALOG_IMAGE} && -n ${CNV_CATALOG_SOURCE} && ${CNV_CATALOG_SOURCE} == "${CNV_IIB_CATALOG_NAME}" ]]; then
    CNV_CATALOG_IMAGE=$(resolve_iib_from_map)
    if [[ -z ${CNV_CATALOG_IMAGE} ]]; then
        echo "Error: Failed to resolve IIB image for version ${CNV_VERSION}"
        exit 1
    fi
    echo "Resolved IIB image for version ${CNV_VERSION}: ${CNV_CATALOG_IMAGE}"
    create_cnv_catalog_source "${CNV_IIB_CATALOG_NAME}" "${CNV_CATALOG_IMAGE}"
    make_sure_all_catalog_source_are_healthy 600 10
fi

echo_debug "Pausing MCPs"
mcp.pause

echo_debug "Applying IDMS"
apply_cnv_idms
apply_brew_idms

echo_debug "Resuming MCPs"
mcp.resume

echo_debug "Waiting for MCPs to update"
wait_for_mcp_to_update 90

echo_debug "Creating install namespace"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${CNV_INSTALL_NAMESPACE}"
EOF

echo_debug "Deploying new operator group"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${CNV_INSTALL_NAMESPACE}-operator-group"
  namespace: "${CNV_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${CNV_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

echo_debug "Subscribing to the operator"
SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: ${CNV_INSTALL_NAMESPACE}
spec:
  channel: ${CNV_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: ${CNV_CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
    CSV=$(oc -n "${CNV_INSTALL_NAMESPACE}" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "${CNV_INSTALL_NAMESPACE}" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    sleep 10
done

echo_debug "Creating HyperConverged resource"
oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  annotations:
    platform.kubevirt.io/autopilot: "false"
  name: ${CNV_HYPERCONVERGED_NAME}
  namespace: ${CNV_INSTALL_NAMESPACE}
EOF

# Disable autopilot
#oc annotate hyperconverged "${CNV_HYPERCONVERGED_NAME}" -n "${CNV_INSTALL_NAMESPACE}" platform.kubevirt.io/autopilot=false

echo_debug "Waiting for HyperConverged resource to be ready"
retry 3 5 oc wait hyperconverged -n "${CNV_INSTALL_NAMESPACE}" "${CNV_HYPERCONVERGED_NAME}" --for=condition=Available --timeout=15m

echo "🟢 CNV is deployed successfully"

echo_debug "Waiting for MCPs to update"
sleep 30
wait_for_mcp_to_update 90
