#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_IIB_CATALOG_NAME=cnv-iib-catalog
CNV_CATALOG_SOURCE=${CNV_CATALOG_SOURCE:-redhat-operators}
CNV_CATALOG_IMAGE=${CNV_CATALOG_IMAGE:-} # IIB
CNV_HYPERCONVERGED_NAME=kubevirt-hyperconverged
CNV_INSTALL_NAMESPACE=openshift-cnv
CNV_OPERATOR_CHANNEL="${CNV_OPERATOR_CHANNEL:-stable}"
CNV_VERSION=${CNV_VERSION:?CNV_VERSION environment variable is required}
# readonly CNV_MAJOR_MINOR=${CNV_VERSION%.*}
# CNV_STARTING_CSV="kubevirt-hyperconverged-operator.v${CNV_VERSION}"


wait_for_manual_debug() {
  echo "😵 Something went wrong, pause here to give yourself time to debug and investigate the issue"
  sleep 7200
}
trap wait_for_manual_debug ERR

echo_debug()
{
    echo "$@" >&2
}

env_hashed() {

    # Check if trace is currently on
    local trace_was_on=0
    if [[ $- == *x* ]]; then
        set +x  # Turn it OFF immediately to hide logic
        trace_was_on=1
    fi

    # Define sensitive keywords separated by a pipe |
    # (case-insensitive partial matching will be applied)
    local sensitive_patterns="password|token|secret|access_key"

    env | while IFS= read -r line; do
        # Split the line at the first '=' to separate Key and Value
        # We use Bash parameter expansion to ensure we only split on the first '='
        local key="${line%%=*}"
        local val="${line#*=}"

        # Check matching: Convert key to lowercase matches the pattern regex
        if [[ "${key,,}" =~ $sensitive_patterns ]]; then

            # 3. Hash Generation: Detect OS (Linux vs macOS)
            local hash=""
            if command -v sha512sum >/dev/null 2>&1; then
                # Linux (Coreutils)
                hash=$(printf "%s" "$val" | sha512sum | awk '{print $1}' | cut -c1-64) # We truncate the hash to 64 characters
            # elif command -v shasum >/dev/null 2>&1; then
            # #macOS / BSD
            #     hash=$(printf "%s" "$val" | shasum -a 512 | awk '{print $1}')
            else
                hash="[error_no_sha512sum_tool_found]"
            fi

            # Print Key with Hashed Value
            echo "$key=SHA512:$hash..."
        else
            # Print non-sensitive lines exactly as they are
            echo "$line"
        fi
    done

    # Restore trace if it was on
    if [[ $trace_was_on -eq 1 ]]; then
        set -x
    fi
}


# Description:
#   Polls all CatalogSource resources in the cluster until they are all healthy and ready,
#   or until a timeout is reached.
# Usage:
#   make_sure_all_catalog_source_are_healthy <timeout-seconds> [<poll-interval-seconds>]
make_sure_all_catalog_source_are_healthy() {
  local timeout=${1:?"Error: timeout (in seconds) is required as first argument"}
  local interval=${2:-5}
  local start_time=${SECONDS}

  local CS_NAME="${CNV_IIB_CATALOG_NAME}"
  local CS_IMAGE="${CNV_CATALOG_IMAGE}"

  echo_debug "Waiting for all CatalogSource resources to become healthy (timeout: ${timeout}s, interval: ${interval}s)..."

  while true; do
    # Fetch all CatalogSources and count those not READY or explicitly unhealthy
    local not_ready_count
    not_ready_count=$(oc get catalogsource --all-namespaces -o json \
      | jq '[.items[] | select(
            .status.connectionState.lastObservedState != "READY" or
            (.status.health.healthy? == false)
          )] | length')

    if [[ "$not_ready_count" -eq 0 ]]; then
      echo_debug "All CatalogSource resources are healthy and ready."
      return 0
    fi

    # Check for timeout
    local elapsed=$(( SECONDS - start_time ))
    if (( elapsed >= timeout )); then
      echo_debug "Timeout after ${elapsed}s: ${not_ready_count} CatalogSource(s) are still not healthy or ready."
      oc get catalogsource --all-namespaces -o yaml | tee "${ARTIFACT_DIR}/catalogsources.yaml"

      echo_debug '[DEBUG] Dumping the state of all subscriptions'
      oc get subscriptions.operators -A -o yaml | tee "${ARTIFACT_DIR}/subscriptions.yaml"

      echo_debug "Checking catalog source status..."
      # Check if catalog source still exists (it might have been deleted by OpenShift)
      if oc get catalogsource "${CS_NAME}" -n openshift-marketplace &>/dev/null; then
        echo_debug "Catalog source still exists, showing details:"
        oc get catalogsource "${CS_NAME}" -n openshift-marketplace -o yaml | tee "${ARTIFACT_DIR}/catalogsource.${CS_NAME}.yaml"
        echo_debug ""
        echo_debug "Catalog source pod status:"
        oc get pods -n openshift-marketplace -l olm.catalogSource="${CS_NAME}" -o wide >&2 || true
        echo_debug ""
        echo_debug "Catalog source events:"
        oc get events -n openshift-marketplace --field-selector involvedObject.name="${CS_NAME}" --sort-by='.lastTimestamp' | tail -20 >&2 || true
      else
        echo_debug "[ERROR] Catalog source ${CS_NAME} was deleted by OpenShift (likely due to image pull failure)."
        echo_debug "Image: ${CS_IMAGE}"
        echo_debug "This usually indicates:"
        echo_debug "  - Image does not exist or is inaccessible"
        echo_debug "  - Authentication/authorization issues"
        echo_debug "  - Network connectivity problems"
        echo_debug "  - Invalid image reference"
      fi

      return 1
    fi

    echo_debug "${not_ready_count} CatalogSource(s) not ready or unhealthy. Retrying in ${interval}s..."
    sleep "${interval}"
  done
}

create_cnv_catalog_source() {
  local catalog_source_name=${1}
  local catalog_image=${2}
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

### MAIN ###################################################################################

env_hashed | grep -i cnv | sort

if [[ -n $CNV_CATALOG_IMAGE ]]; then
  CNV_CATALOG_SOURCE=${CNV_IIB_CATALOG_NAME}
  create_cnv_catalog_source "${CNV_IIB_CATALOG_NAME}" "${CNV_CATALOG_IMAGE}"
  make_sure_all_catalog_source_are_healthy 600 10
fi

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
  name: ${CNV_HYPERCONVERGED_NAME}
  namespace: ${CNV_INSTALL_NAMESPACE}
EOF

oc wait hyperconverged -n "${CNV_INSTALL_NAMESPACE}" "${CNV_HYPERCONVERGED_NAME}" --for=condition=Available --timeout=15m

echo "CNV is deployed successfully"
