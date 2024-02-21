#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "Describing abnormal mcp...\n"
        oc get mcp --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
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

function extract_ccoctl(){
    local payload_image image_arch cco_image
    local retry=5
    local tmp_ccoctl="/tmp/upgtool"
    mkdir -p ${tmp_ccoctl}
    export PATH=/tmp:${PATH}

    echo -e "Extracting ccoctl\n"
    payload_image="${TARGET}"
    set -x
    image_arch=$(oc adm release info ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret" -o jsonpath='{.config.architecture}')
    if [[ "${image_arch}" == "arm64" ]]; then
        echo "The target payload is arm64 arch, trying to find out a matched version of payload image on amd64"
        if [[ -n ${RELEASE_IMAGE_TARGET:-} ]]; then
            payload_image=${RELEASE_IMAGE_TARGET}
            echo "Getting target release image from RELEASE_IMAGE_TARGET: ${payload_image}"
        elif env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc get istag "release:target" -n ${NAMESPACE} &>/dev/null; then
            payload_image=$(env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc -n ${NAMESPACE} get istag "release:target" -o jsonpath='{.tag.from.name}')
            echo "Getting target release image from build farm imagestream: ${payload_image}"
        fi
    fi
    set +x
    cco_image=$(oc adm release info --image-for='cloud-credential-operator' ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret") || return 1
    while ! (env "NO_PROXY=*" "no_proxy=*" oc image extract $cco_image --path="/usr/bin/ccoctl:${tmp_ccoctl}" -a "${CLUSTER_PROFILE_DIR}/pull-secret");
    do
        echo >&2 "Failed to extract ccoctl binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_ccoctl}/ccoctl /tmp -f
    if [[ ! -e /tmp/ccoctl ]]; then
        echo "No ccoctl tool found!" && return 1
    else
        chmod 775 /tmp/ccoctl
    fi
}

function update_cloud_credentials_oidc(){
    local platform preCredsDir tobeCredsDir tmp_ret

    platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
    preCredsDir="/tmp/pre-include-creds"
    tobeCredsDir="/tmp/tobe-include-creds"
    mkdir "${preCredsDir}" "${tobeCredsDir}"
    # Extract all CRs from live cluster with --included
    if ! oc adm release extract --to "${preCredsDir}" --included --credentials-requests; then
        echo "Failed to extract CRs from live cluster!" && exit 1
    fi
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${TARGET}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!" && exit 1
    fi

    # TODO: add gcp and azure
    # Update iam role with ccoctl based on tobeCredsDir
    tmp_ret=0
    diff -r "${preCredsDir}" "${tobeCredsDir}" || tmp_ret=1
    if [[ ${tmp_ret} != 0 ]]; then
        toManifests="/tmp/to-manifests"
        mkdir "${toManifests}"
        case "${platform}" in
        "AWS")
            if [[ ! -e ${SHARED_DIR}/aws_oidc_provider_arn ]]; then
                echo "No aws_oidc_provider_arn file in SHARED_DIR" && exit 1
            else
                export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
                infra_name=${NAMESPACE}-${UNIQUE_HASH}
                oidc_provider=$(head -n1 ${SHARED_DIR}/aws_oidc_provider_arn)
                extract_ccoctl
                if ! ccoctl aws create-iam-roles --name="${infra_name}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="${tobeCredsDir}" --identity-provider-arn="${oidc_provider}" --output-dir="${toManifests}"; then
                    echo "Failed to update iam role!" && exit 1
                fi
                if [[ "$(ls -A ${toManifests}/manifests)" ]]; then
                    echo "Apply the new credential secrets."
                    oc apply -f "${toManifests}/manifests"
                fi
            fi
            ;;
        *)
           echo "to be supported platform: ${platform}" 
           ;;
        esac
    fi
}

# Add cloudcredential.openshift.io/upgradeable-to: <version_number> to cloudcredential cluster when cco mode is manual or the case in OCPQE-19413
function cco_annotation(){
    if (( SOURCE_MINOR_VERSION == TARGET_MINOR_VERSION )) || (( SOURCE_MINOR_VERSION < 8 )); then
        echo "CCO annotation change is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local cco_mode; cco_mode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}')"
    local platform; platform="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')"
    if [[ ${cco_mode} == "Manual" ]]; then
        echo "CCO annotation change is required in Manual mode"
    elif [[ -z "${cco_mode}" || ${cco_mode} == "Mint" ]]; then
        if [[ "${SOURCE_MINOR_VERSION}" == "14" && ${platform} == "GCP" ]] ; then
            echo "CCO annotation change is required in default or Mint mode on 4.14 GCP cluster"
        else
            echo "CCO annotation change is not required in default or Mint mode on 4.${SOURCE_MINOR_VERSION} ${platform} cluster"
            return 0
        fi
    else
        echo "CCO annotation change is not required in ${cco_mode} mode"
        return 0
    fi

    echo "Require CCO annotation change"
    local wait_time_loop_var=0; to_version="$(echo "${TARGET_VERSION}" | cut -f1 -d-)"
    oc patch cloudcredential.operator.openshift.io/cluster --patch '{"metadata":{"annotations": {"cloudcredential.openshift.io/upgradeable-to": "'"${to_version}"'"}}}' --type=merge

    echo "CCO annotation patch gets started"

    echo -e "sleep 5 min wait CCO annotation patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "MissingUpgradeableAnnotation"; then
            echo -e "CCO annotation patch PASSED\n"
            return 0
        else
            echo -e "CCO annotation patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for CCO annotation completing, exiting" && return 1
    fi
}

# Update RHEL repo before upgrade
function rhel_repo(){
    echo "Updating RHEL node repo"
    # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
    # to be able to SSH.
    if ! whoami &> /dev/null; then
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
        else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
            exit 1
        fi
    fi
    SOURCE_REPO_VERSION=$(echo "${SOURCE_VERSION}" | cut -d'.' -f1,2)
    TARGET_REPO_VERSION=$(echo "${TARGET_VERSION}" | cut -d'.' -f1,2)
    export SOURCE_REPO_VERSION
    export TARGET_REPO_VERSION

    cat > /tmp/repo.yaml <<-'EOF'
---
- name: Update repo Playbook
  hosts: workers
  any_errors_fatal: true
  gather_facts: false
  vars:
    source_repo_version: "{{ lookup('env', 'SOURCE_REPO_VERSION') }}"
    target_repo_version: "{{ lookup('env', 'TARGET_REPO_VERSION') }}"
    platform_version: "{{ lookup('env', 'PLATFORM_VERSION') }}"
    major_platform_version: "{{ platform_version[:1] }}"
  tasks:
  - name: Wait for host connection to ensure SSH has started
    wait_for_connection:
      timeout: 600
  - name: Replace source release version with target release version in the files
    replace:
      path: "/etc/yum.repos.d/rhel-{{ major_platform_version }}-server-ose-rpms.repo"
      regexp: "{{ source_repo_version }}"
      replace: "{{ target_repo_version }}"
  - name: Clean up yum cache
    command: yum clean all
EOF

    version_info="$(oc version | grep Server | sed -E 's/.*: ([4-9].[0-9]+)/\1/' | cut -d '.' -f 1,2)"
    openshift_ansible_branch='master'
    if [[ "$version_info" =~ [4-9].[0-9]+ ]] ; then
        openshift_ansible_branch="release-${version_info}"
        minor_version="${version_info##*.}"
        if [[ -n "$minor_version" ]] && [[ $minor_version -le 10 ]] ; then
            source /opt/python-env/ansible2.9/bin/activate
        else
            source /opt/python-env/ansible-core/bin/activate
        fi
        ansible --version
    else
        echo "WARNING: version_info is $version_info"
    fi
    echo -e "Using openshift-ansible branch $openshift_ansible_branch\n"
    cd /usr/share/ansible/openshift-ansible
    git stash || true
    git checkout "$openshift_ansible_branch"
    git pull || true
    ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
    ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /tmp/repo.yaml -vvv
}

# Upgrade RHEL node
function rhel_upgrade(){
    echo "Upgrading RHEL nodes"
    echo "Validating parsed Ansible inventory"
    ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
    echo -e "\nRunning RHEL worker upgrade"
    sed -i 's|^remote_tmp.*|remote_tmp = /tmp/.ansible|g' /usr/share/ansible/openshift-ansible/ansible.cfg
    ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /usr/share/ansible/openshift-ansible/playbooks/upgrade.yml -vvv

    echo "Check K8s version on the RHEL node"
    master_0=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[0]}{.metadata.name}{"\n"}{end}')
    rhel_0=$(oc get nodes -l node.openshift.io/os_id=rhel -o jsonpath='{range .items[0]}{.metadata.name}{"\n"}{end}')
    exp_version=$(oc get node ${master_0} --output=jsonpath='{.status.nodeInfo.kubeletVersion}' | cut -d '.' -f 1,2)
    act_version=$(oc get node ${rhel_0} --output=jsonpath='{.status.nodeInfo.kubeletVersion}' | cut -d '.' -f 1,2)

    echo -e "Expected K8s version is: ${exp_version}\nActual K8s version is: ${act_version}"
    if [[ ${exp_version} == "${act_version}" ]]; then
        echo "RHEL worker has correct K8s version"
    else
        echo "RHEL worker has incorrect K8s version" && exit 1
    fi
    echo -e "oc get node -owide\n$(oc get node -owide)"
    echo "RHEL worker upgrade complete"
}

# Extract oc binary which is supposed to be identical with target release
function extract_oc(){
    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    which oc
    oc version --client
    return 0
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
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

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc unavailable_operator degraded_operator skip_operator

    skip_operator="aro" # ARO operator versioned but based on RP git commit ID not cluster version
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

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(${OC} get clusteroperator --no-headers | grep -v ${skip_operator} | awk -v var="${TARGET_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(${OC} get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o jsonpath='{.items[].status.conditions[?(@.type=="Available")].status}'| grep -iv "True"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(${OC} get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's DEGRADED column is False"
    # In disconnected install, openshift-sample often get into Degrade state, so it is better to remove them from cluster from flexy post-action
    #degraded_operator=$(${OC} get clusteroperator | grep -v "openshift-sample" | awk '$5 == "True"')
    if degraded_operator=$(${OC} get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    #co_check=$(${OC} get clusteroperator -o json | jq '.items[] | select(.metadata.name != "openshift-samples") | .status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False')
    if ${OC} get clusteroperator -o jsonpath='{.items[].status.conditions[?(@.type=="Degraded")].status}'| grep -iv 'False'; then
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
    oc get mcp -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        updating_mcp=$(cat "${tmp_output}" | grep -v "False")
        if [[ -n "${updating_mcp}" ]]; then
            echo "Some mcp is updating..."
            echo "${updating_mcp}"
            return 1
        fi
    else
        echo "Did not run "oc get mcp" successfully!"
        return 1
    fi

    # Do not check UPDATED on purpose, beause some paused mcp would not update itself until unpaused
    oc get mcp -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        unhealthy_mcp=$(cat "${tmp_output}" | grep -v "False.*False.*0")
        if [[ -n "${unhealthy_mcp}" ]]; then
            echo "Detected unhealthy mcp:"
            echo "${unhealthy_mcp}"
            echo "Real-time detected unhealthy mcp:"
            oc get mcp -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
            echo "Real-time full mcp output:"
            oc get mcp
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
        echo "Did not run "oc get mcp" successfully!"
        return 1
    fi
    return 0
}

function wait_mcp_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria max_retries ret=0 interval=30
    num=$(oc get node --no-headers | wc -l)
    max_retries=$(expr $num \* 20 \* 60 \/ $interval) # Wait 20 minutes for each node, try 60/interval times per minutes
    passed_criteria=$(expr 5 \* 60 \/ $interval) # We consider mcp to be updated if its status is updated for 5 minutes
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
        sleep ${interval}
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        echo "Debug: current mcp output is:"
        oc get mcp
        return 1
    else
        echo "All mcp status check PASSED"
        return 0
    fi
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

function health_check() {
    echo "Step #1: Make sure no degrated or updating mcp"
    wait_mcp_continous_success

    echo "Step #2: check all cluster operators get stable and ready"
    wait_clusteroperators_continous_success

    echo "Step #3: Make sure every machine is in 'Ready' status"
    check_node

    echo "Step #4: check all pods are in status running or complete"
    check_pod
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response try max_retries
    if [[ "${TARGET}" =~ "@sha256:" ]]; then
        digest="$(echo "${TARGET}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${TARGET}" -o json | jq -r ".digest")"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    set -x
    try=0
    max_retries=2
    response=$(https_proxy="" HTTPS_PROXY="" curl --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1" -v)
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1" -v)
        (( try += 1 ))
        sleep 60
    done
    set +x
    if (( response == 200 )); then
        echo "${TARGET} is signed" && return 0
    else
        echo "Seem like ${TARGET} is not signed" && return 1
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    if (( SOURCE_MINOR_VERSION == TARGET_MINOR_VERSION )) || (( SOURCE_MINOR_VERSION < 8 )); then
        echo "Admin ack is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    if [[ ${out} != *"ack-4.${SOURCE_MINOR_VERSION}"* ]]; then
        echo "Admin ack not required: ${out}" && return
    fi

    echo "Require admin ack:\n ${out}"
    local wait_time_loop_var=0 ack_data

    ack_data="$(echo "${out}" | jq -r "keys[]")"
    for ack in ${ack_data};
    do
        # e.g.: ack-4.12-kube-1.26-api-removals-in-4.13
        if [[ "${ack}" == *"ack-4.${SOURCE_MINOR_VERSION}"* ]]
        then
            echo "Admin ack patch data is: ${ack}"
            oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done
    echo "Admin-acks patch gets started"

    echo -e "sleep 5 min wait admin-acks patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "AdminAckRequired"; then
            echo -e "Admin-acks patch PASSED\n"
            return 0
        else
            echo -e "Admin-acks patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for admin-acks completing, exiting" && return 1
    fi
}

# Check if the cluster hit the image validation error, which caused by image signature
function error_check_invalid_image() {
    local try=0 max_retries=5 tmp_log cmd expected_msg
    tmp_log=$(mktemp)
    while (( try < max_retries )); do
        echo "Trying #${try}"
        cmd="oc adm upgrade"
        expected_msg="failure=The update cannot be verified:"
        run_command "${cmd} 2>&1 | tee ${tmp_log}"
        if grep -q "${expected_msg}" "${tmp_log}"; then
            echo "Found the expected validation error message"
            break
        fi
        (( try += 1 ))
        sleep 60
    done
    if (( ${try} >= ${max_retries} )); then
        echo >&2 "Timed out catching image invalid error message..." && return 1
    fi

}

function clear_upgrade() {
    local cmd tmp_log expected_msg
    tmp_log=$(mktemp)
    cmd="oc adm upgrade --clear"
    expected_msg="Cancelled requested upgrade to"
    run_command "${cmd} 2>&1 | tee ${tmp_log}"
    if grep -q "${expected_msg}" "${tmp_log}"; then
        echo "Last upgrade is cleaned."
    else
        echo "Clear the last upgrade fail!"
        return 1
    fi
}

# Upgrade the cluster to target release
function upgrade() {
    local log_file history_len cluster_src_ver
    if check_ota_case_enabled "OCP-21588"; then
        log_file=$(mktemp)
        echo "Testing --allow-explicit-upgrade option"
        run_command "oc adm upgrade --to-image=${TARGET} --force=${FORCE_UPDATE} 2>&1 | tee ${log_file}" || true
        if grep -q 'specify --allow-explicit-upgrade to continue' "${log_file}"; then
            echo "--allow-explicit-upgrade prompt message is shown"
        else
            echo "--allow-explicit-upgrade prompt message is NOT shown!"
            exit 1
        fi
        history_len=$(oc get clusterversion -o json | jq '.items[0].status.history | length')
        if [[ "${history_len}" != 1 ]]; then
            echo "seem like there are more than 1 hisotry in CVO, sounds some unexpected update happened!"
            exit 1
        fi
    fi
    if check_ota_case_enabled "OCP-24663"; then
        cluster_src_ver=$(oc version -o json | jq -r '.openshiftVersion')
        if [[ -z "${cluster_src_ver}" ]]; then
            echo "Did not get cluster version at this moment"
            exit 1
        else
            echo "Current cluster is on ${cluster_src_ver}"
        fi
        echo "Negative Testing: upgrade to an unsigned image without --force option"
        admin_ack
        cco_annotation
        run_command "oc adm upgrade --to-image=${TARGET} --allow-explicit-upgrade"
        error_check_invalid_image
        clear_upgrade
        check_upgrade_status "${cluster_src_ver}"
    fi
    run_command "oc adm upgrade --to-image=${TARGET} --allow-explicit-upgrade --force=${FORCE_UPDATE}"
    echo "Upgrading cluster to ${TARGET} gets started..."
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" out avail progress cluster_version
    if [[ -n "${1:-}" ]]; then
        cluster_version="$1"
    else
        cluster_version="${TARGET_VERSION}"
    fi
    echo "Starting the upgrade checking on $(date "+%F %T")"
    while (( wait_upgrade > 0 )); do
        sleep 5m
        wait_upgrade=$(( wait_upgrade - 5 ))
        if ! ( run_command "oc get clusterversion" ); then
            continue
        fi
        if ! out="$(oc get clusterversion --no-headers)"; then continue; fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${cluster_version}" ]]; then
            echo -e "Upgrade succeed on $(date "+%F %T")\n\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade timeout on $(date "+%F %T"), exiting\n" && return 1
    fi
}

# Check version, state in history
function check_history() {
    local version state
    version=$(oc get clusterversion/version -o jsonpath='{.status.history[0].version}')
    state=$(oc get clusterversion/version -o jsonpath='{.status.history[0].state}')
    if [[ ${version} == "${TARGET_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${TARGET_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster upgrade to ${TARGET_VERSION} failed, current version is ${version}, exiting" && return 1
    fi
}

# check if any of cases is enabled via ENABLE_OTA_TEST
function check_ota_case_enabled() {
    local case_id
    local cases_array=("$@")
    for case_id in "${cases_array[@]}"; do
        # shellcheck disable=SC2076
        if [[ " ${ENABLE_OTA_TEST} " =~ " ${case_id} " ]]; then
            echo "${case_id} is enabled via ENABLE_OTA_TEST on this job."
            return 0
        fi
    done
    return 1
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Get the target upgrades release, by default, OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is the target release
# If it's serial upgrades then override-upgrade file will store the release and overrides OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# upgrade-edge file expects a comma separated releases list like target_release1,target_release2,...
export TARGET_RELEASES=("${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}")
if [[ -f "${SHARED_DIR}/upgrade-edge" ]]; then
    release_string="$(< "${SHARED_DIR}/upgrade-edge")"
    # shellcheck disable=SC2207
    TARGET_RELEASES=($(echo "$release_string" | tr ',' ' '))
fi
echo "Upgrade targets are ${TARGET_RELEASES[*]}"

export OC="run_command_oc"

# Target version oc will be extract in the /tmp/client directory, use it first
mkdir -p /tmp/client
export OC_DIR="/tmp/client"
export PATH=${OC_DIR}:$PATH

for target in "${TARGET_RELEASES[@]}"
do
    export TARGET="${target}"
    TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
    extract_oc

    SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
    SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
    export SOURCE_VERSION
    export SOURCE_MINOR_VERSION
    echo -e "Source release version is: ${SOURCE_VERSION}\nSource minor version is: ${SOURCE_MINOR_VERSION}"

    TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
    export TARGET_VERSION
    export TARGET_MINOR_VERSION
    echo -e "Target release version is: ${TARGET_VERSION}\nTarget minor version is: ${TARGET_MINOR_VERSION}"

    export FORCE_UPDATE="false"
    if ! check_signed; then
        echo "You're updating to an unsigned images, you must override the verification using --force flag"
        FORCE_UPDATE="true"
        if check_ota_case_enabled "OCP-30832" "OCP-27986" "OCP-24358" "OCP-69968"; then
            echo "The case need to run against a signed target image!"
            exit 1
        fi
    else
        echo "You're updating to a signed images, so run the upgrade command without --force flag"
    fi
    if [[ "${FORCE_UPDATE}" == "false" ]]; then
        admin_ack
        cco_annotation
    fi
    if [[ "${UPGRADE_CCO_MANUAL_MODE}" == "oidc" ]]; then
        update_cloud_credentials_oidc
    fi
    upgrade
    check_upgrade_status
    check_history

    if [[ $(oc get nodes -l node.openshift.io/os_id=rhel) != "" ]]; then
        echo -e "oc get node -owide\n$(oc get node -owide)"
        rhel_repo
        rhel_upgrade
    fi
    health_check
done

