#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo "Generating the Junit for upgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="0">
  <testcase classname="cluster upgrade" name="upgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="1">
  <testcase classname="cluster upgrade" name="upgrade should succeed">
    <failure message="">openshift cluster upgrade failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function run_command_oc() {
    local try=0 max=40 ret_val

    if [[ "$#" -lt 1 ]]; then
        return 0
    fi

    while (( try < max )); do
        if ret_val=$(oc "$@" 2>&1); then
            break
        fi
        (( try += 1 ))
        sleep 3
    done

    if (( try == max )); then
        echo >&2 "Run:[oc $*]"
        echo >&2 "Get:[$ret_val]"
        return 255
    fi

    echo "${ret_val}"
}

function check_node() {
    local node_number ready_number
    node_number=$(${OC} get node |grep -vc STATUS)
    ready_number=$(${OC} get node |grep -v STATUS | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node |grep -v STATUS | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_pod() {
    echo "Show all pods status for reference/debug"
    oc get pods --all-namespaces
}

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc null_version unavailable_operator degraded_operator

    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    ${OC} get clusteroperator >"${tmp_clusteroperator}"
    column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
    last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
        awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
        input="${tmp_clusteroperator_1}"
    fi

    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done < "${input}"
    rm -f "${tmp_clusteroperator}"

    echo "Make sure every operator column reports version"
    if null_version=$(${OC} get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
        echo >&2 "Null Version: ${null_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(${OC} get clusteroperator --no-headers | awk -v var="${TARGET_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    # In disconnected install, marketplace often get into False state, so it is better to remove it from cluster from flexy post-action
    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(${OC} get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    # In disconnected install, openshift-sample often get into Degrade state, so it is better to remove them from cluster from flexy post-action
    #degraded_operator=$(${OC} get clusteroperator | grep -v "openshift-sample" | awk '$5 == "True"')
    if degraded_operator=$(${OC} get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    #co_check=$(${OC} get clusteroperator -o json | jq '.items[] | select(.metadata.name != "openshift-samples") | .status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False')
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=20
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        if check_clusteroperators; then
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        else
            echo "cluster operators are not ready yet, wait and retry..."
            continous_successful_check=0
        fi
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some cluster operator does not get ready or not stable"
        echo "Debug: current CO output is:"
        oc get co
        return 1
    else
        echo "All cluster operators status check PASSED"
        return 0
    fi
}

function health_check() {
    #1. Check all cluster operators get stable and ready
    echo "Step #1: check all cluster operators get stable and ready"
    wait_clusteroperators_continous_success

    #2. Make sure every machine is in 'Ready' status
    echo "Step #2: Make sure every machine is in 'Ready' status"
    check_node

    #3. All pods are in status running or complete
    echo "Step #3: check all pods are in status running or complete"
    check_pod
}

if [ ! -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
  exit 1
fi
echo "switch kubeconfig"
export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export OC="run_command_oc"

echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE"
cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
oc patch hostedcluster "$cluster_name" -n "$HYPERSHIFT_NAMESPACE" --type=merge -p '{"spec":{"release":{"image":"'"${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"'"}}}'

_upgradeReady=1
for ((i=1; i<=60; i++)); do
  count=$(oc get hostedcluster -n clusters "$cluster_name" -ojsonpath='{.status.version.history[?(@.image=="'"${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"'")].state}' | grep -c Completed || true)
  if [ "$count" -eq 1 ] ; then
      echo "HyperShift HostedCluster(CP) upgrade successful"
      _upgradeReady=0
      break
  fi
  echo "Try ${i}/60: HyperShift HostedCluster(CP) is not updated yet. Checking again in 30 seconds"
  sleep 30
done

if [ $_upgradeReady -ne 0 ]; then
  echo "HyperShift HostedCluster(CP) upgrade failed"
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
health_check