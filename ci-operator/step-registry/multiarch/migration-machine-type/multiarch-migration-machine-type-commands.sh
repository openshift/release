#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Generate the Junit for multiarch machine type migration
function createMTOJunit() {
    echo "Generating the Junit for multiarch test"
    filename="import-multiarch"
    testsuite="machine type migration"
    if (( FRC == 0 )); then
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00001:lwan:control plane/infra machine type migration should succeed"/>
</testsuite>
EOF
    else
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00001:lwan:control plane/infra machine type migration should succeed">
    <failure message="">control plane/infra machine type migration failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function check_replicas() {
    local namespace=$1 resource_type=$2 resource_name=$3
    spec_replicas=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    ready_replicas=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [[ -z "$spec_replicas" || -z "$ready_replicas" ]]; then
        echo "Error: unable to retrieve replicas information for $resource_type/$resource_name."
        return 1
    fi
    if [[ "$spec_replicas" -eq "$ready_replicas" ]]; then
        echo "Success: ready replicas ($ready_replicas) match spec replicas ($spec_replicas) for $resource_type/$resource_name."
        # For control plane, we also need to check controlplanemachineset's .status.updatedReplicas to make sure all master nodes done migration
        if [[ $resource_type == *controlplane* ]]; then
            updated_replicas=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null)
            if [[ -z "$updated_replicas" ]]; then
                echo "Error: unable to retrieve updated replicas information for $resource_type/$resource_name."
                return 1
            elif [[ "$spec_replicas" -eq "$updated_replicas" ]]; then
                echo "Success: updated replicas ($updated_replicas) match spec replicas ($spec_replicas) for $resource_type/$resource_name."
            else
                echo "Fail: updated replicas ($updated_replicas) don't match spec replicas ($spec_replicas) for $resource_type/$resource_name."
                return 1
            fi
        fi
        return 0
    else
        echo "Fail: ready replicas ($ready_replicas) don't match spec replicas ($spec_replicas) for $resource_type/$resource_name."
        return 1
    fi
}

function wait_for_ready_replicas() {
    local namespace=$1 resource_type=$2 resource_name=$3 replicas max_retries
    local interval=60 try=0
    replicas=$(oc get "$resource_type" "${resource_name}" -n "$namespace" -o jsonpath='{.spec.replicas}')
    max_retries=$(expr $replicas \* 30 \* 60 \/ $interval)
    echo "Waiting for $resource_type in namespace $namespace to have ready replicas matching spec replicas..."
    while (( try < max_retries )); do
        if (check_replicas "${namespace}" "${resource_type}" ${resource_name}); then
            break
        else
            sleep $interval
        fi
        (( try += 1 ))
    done
    if (( try == max_retries )); then
        echo >&2 "Timeout waiting for the number of ready nodes to equal the number of replicas"
        return 1
    else
        echo "The number of ready nodes matches the number of replicas"
        return 0
    fi
}

function gnu_triplet_machine_to_goarch() {
  case "$1" in
    "aarch64")
      echo "arm64"
      ;;
    "x86_64")
      echo "amd64"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

function check_nodes_arch() {
    local machine_roles=()
    if [[ -n "${MIGRATION_CP_MACHINE_TYPE}" ]]; then
        machine_roles+=("master")
    fi
    if [[ -n "${MIGRATION_INFRA_MACHINE_TYPE}" ]]; then
        machine_roles+=("infra")
    fi
    echo "Checking architecture for machine roles ${machine_roles[*]}"
    for machine_role in "${machine_roles[@]}"; do
        echo "Check all ${machine_role} nodes have migrated to ${MIGRATION_ARCHITECTURE} machine type"
        nodes_arch=$(oc get nodes -l node-role.kubernetes.io/${machine_role}= -o yaml | yq-v4 '.items[].status.nodeInfo.architecture' | sort -u)
        if [[ "${nodes_arch}" != $(gnu_triplet_machine_to_goarch "${MIGRATION_ARCHITECTURE}") ]]; then
            echo "There are unexpected architecture nodes, machine type migration failed"
            oc get nodes -o wide
            return 1
        else
            echo "All nodes are expected architecture, machine type migration succeed"
        fi
    done
    return 0 
}

function change_imagestream() {
    local namespaces imagestreams
    echo "Changing all imagestreams importMode to PreserveOriginal"
    namespaces=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}')
    for namespace in $namespaces; do
        echo "Processing Namespace: $namespace"
        imagestreams=$(oc get imagestreams -n "$namespace" -o jsonpath='{.items[*].metadata.name}') || return 1
        for imagestream in $imagestreams; do
            echo "Processing ImageStream: $imagestream"
            oc import-image $imagestream -n $namespace --all --confirm --request-timeout=2m --import-mode='PreserveOriginal' || return 1
        done
    done
}

function check_imagestream() {
    local namespaces imagestreams importModes
    echo "Check if all imagestreams importMode changed to PreserveOriginal"
    namespaces=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}')
    for namespace in $namespaces; do
        echo "Checking namespace: $namespace"
        imagestreams=$(oc get imagestreams -n "$namespace" -o jsonpath='{.items[*].metadata.name}')
        for imagestream in $imagestreams; do
            echo "ImageStream: $imagestream"
            importModes=$(oc get imagestream "$imagestream" -n "$namespace" -o json | jq -r '.spec.tags[] | select(.from.kind != "ImageStreamTag") | .importPolicy.importMode')
            if [ -z "$importModes" ]; then
                echo "No importMode set for this ImageStream"
            else
                for importMode in $importModes; do
                    if [ "${importMode}" != "PreserveOriginal" ]; then
                        echo "The importMode of imagestream $imagestream in namespace $namespace are not changed to PreserveOriginal"
                        return 1
                    fi
                done
            fi
        done
    done
}

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc unavailable_operator degraded_operator
    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    oc get clusteroperator >"${tmp_clusteroperator}"
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

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(oc get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
        echo >&2 "Some operators are not Available, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(oc get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's DEGRADED column is False"
    if degraded_operator=$(oc get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
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

function check_mcp() {
    local updating_mcp unhealthy_mcp tmp_output
    tmp_output=$(mktemp)
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        updating_mcp=$(cat "${tmp_output}" | grep -v "False")
        if [[ -n "${updating_mcp}" ]]; then
            echo "Some mcp is updating..."
            echo "${updating_mcp}"
            return 1
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi

    # Do not check UPDATED on purpose, beause some paused mcp would not update itself until unpaused
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        unhealthy_mcp=$(cat "${tmp_output}" | grep -v "False.*False.*0")
        if [[ -n "${unhealthy_mcp}" ]]; then
            echo "Detected unhealthy mcp:"
            echo "${unhealthy_mcp}"
            echo "Real-time detected unhealthy mcp:"
            oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
            echo "Real-time full mcp output:"
            oc get machineconfigpools
            echo ""
            unhealthy_mcp_names=$(echo "${unhealthy_mcp}" | awk '{print $1}')
            echo "Using oc describe to check status of unhealthy mcp ..."
            for mcp_name in ${unhealthy_mcp_names}; do
              echo "Name: $mcp_name"
              oc describe mcp $mcp_name || echo "oc describe mcp $mcp_name failed"
            done
            return 2
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi
    return 0
}

function wait_mcp_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=5 max_retries=20 ret=0
    local continous_degraded_check=0 degraded_criteria=5
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        ret=0
        check_mcp || ret=$?
        if [[ "$ret" == "0" ]]; then
            continous_degraded_check=0
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        elif [[ "$ret" == "1" ]]; then
            echo "Some machines are updating..."
            continous_successful_check=0
            continous_degraded_check=0
        else
            continous_successful_check=0
            echo "Some machines are degraded #${continous_degraded_check}..."
            (( continous_degraded_check += 1 ))
            if (( continous_degraded_check >= degraded_criteria )); then
                break
            fi
        fi
        echo "wait and retry..."
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        echo "Debug: current mcp output is:"
        oc get machineconfigpools
        return 1
    else
        echo "All mcp status check PASSED"
        return 0
    fi
}

function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | wc -l)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node --no-headers | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function health_check() {
    echo "Step #1: Make sure no degrated or updating mcp"
    wait_mcp_continous_success

    echo "Step #2: check all cluster operators get stable and ready"
    wait_clusteroperators_continous_success

    echo "Step #3: Make sure every machine is in 'Ready' status"
    check_node
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Make sure yq-v4 is installed
if [ ! -f /tmp/yq-v4 ]; then
  # TODO move to image
  curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
fi
PATH=${PATH}:/tmp

echo "Make sure all imagestreams importMode are PreserveOriginal"
change_imagestream
check_imagestream

CLUSTER_TYPE=${CLUSTER_TYPE:-$CLOUD_TYPE}
REGION=${LEASED_RESOURCE:-$REGION}
echo -e "Cluster type is ${CLUSTER_TYPE}\nRegion is ${REGION}"
# AMI for AWS ARM
case $CLUSTER_TYPE in
*aws*)
  echo "Extracting AMI..."
  amiid_migration=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml | \
    yq-v4 ".data.stream
      | eval(.).architectures.${MIGRATION_ARCHITECTURE}.images.aws.regions.\"${REGION}\".image")
  echo "migrate machine type to architecture ${MIGRATION_ARCHITECTURE} and with ami ${amiid_migration} ..."
  if [[ -n "${MIGRATION_CP_MACHINE_TYPE}" ]]; then
    echo "Start migrating control plane to ${MIGRATION_CP_MACHINE_TYPE} ..."
    oc -n openshift-machine-api get -o yaml controlplanemachineset.machine.openshift.io cluster | yq-v4 "$(cat <<EOF
     .spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.ami.id = "${amiid_migration}"
     | .spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.instanceType = "${MIGRATION_CP_MACHINE_TYPE}"
EOF
)" | oc apply -oyaml -f -
    wait_for_ready_replicas "openshift-machine-api" "controlplanemachineset.machine.openshift.io" "cluster"
  fi
  if [[ -n "${MIGRATION_INFRA_MACHINE_TYPE}" ]]; then
    pre_infra_name=$(oc get machineset -n openshift-machine-api -o yaml | yq-v4 '.items[] | select(.spec.template.spec.metadata.labels["node-role.kubernetes.io/infra"] == "") | .metadata.name')
    migration_infra_name="${pre_infra_name}-migration"
    echo "Create a new infra machineset with ${MIGRATION_INFRA_MACHINE_TYPE}"
    oc -n openshift-machine-api get -o yaml machinesets.machine.openshift.io | yq-v4 "$(cat <<EOF
     .items |= map(select(.spec.template.spec.metadata.labels["node-role.kubernetes.io/infra"] == "")
     | .metadata.name = "${migration_infra_name}"
     | .spec.template.spec.providerSpec.value.ami.id = "${amiid_migration}"
     | .spec.template.spec.providerSpec.value.instanceType = "${MIGRATION_INFRA_MACHINE_TYPE}"
     | .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = .metadata.name
     | .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = .metadata.name
     | del(.status)
     | del(.metadata.selfLink)
     | del(.metadata.uid)
     )
EOF
)" | oc create -f -
    echo "Wait for ${MIGRATION_INFRA_MACHINE_TYPE} infra nodes up"
    wait_for_ready_replicas "openshift-machine-api" "machinesets.machine.openshift.io" ${migration_infra_name}
    echo "Scale down the pre infra nodes"
    oc -n openshift-machine-api scale machineset/"${pre_infra_name}" --replicas=0
  fi
;;
*)
  echo "Migration control plane/infra machine type for cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

echo "Do health check after migration"
health_check

echo "Check all nodes are migrated to expected architecture"
check_nodes_arch