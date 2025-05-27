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
        echo -e "\n# oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "\n# oc get machineconfig\n$(oc get machineconfig)"
        echo -e "\n# Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "\n# Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "\n# Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Explicitly set upgrade failure to operators
function check_failed_operator(){
    local latest_ver_in_history failing_status failing_operator failing_operators
    latest_ver_in_history=$(oc get clusterversion version -ojson|jq -r '.status.history[0].version')
    if [[ "${latest_ver_in_history}" != "${TARGET_VERSION}" ]]; then
        # Upgrade does not start, set it to CVO
        echo "Upgrade does not start, set UPGRADE_FAILURE_TYPE to cvo"
        export UPGRADE_FAILURE_TYPE="cvo"
    else
        failing_status=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").status')
        # Upgrade stuck at operators while failing=True, check from the operators reported in cv Failing condition
        if [[ ${failing_status} == "True" ]]; then
            failing_operator=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operator \K.*?(?= is)') || true
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operators \K.*?(?= are)'|tr -d ',') || true
            failing_operators="${failing_operator} ${failing_operators}"
        else
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'wait has exceeded 40 minutes for these operators: \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting up to 40 minutes on \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting on \K.*'|tr -d ',') || true
        fi
        if [[ -n "${failing_operators}" && "${failing_operators}" =~ [^[:space:]] ]]; then
            echo "Upgrade stuck, set UPGRADE_FAILURE_TYPE to ${failing_operators}"
            export UPGRADE_FAILURE_TYPE="${failing_operators}"
        fi
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo -e "\n# Generating the Junit for upgrade"
    local upg_report="${ARTIFACT_DIR}/junit_upgrade.xml"
    local cases_in_upgrade
    if (( FRC == 0 )); then
        # The cases are SLOs on the live cluster which may be a possible UPGRADE_FAILURE_TYPE
        local cases_from_available_operators upgrade_success_cases
        cases_from_available_operators=$(oc get co --no-headers|awk '{print $1}'|tr '\n' ' ' || true)
        upgrade_success_cases="${UPGRADE_FAILURE_TYPE} ${cases_from_available_operators} ${IMPLICIT_ENABLED_CASES}"
        upgrade_success_cases=$(echo ${upgrade_success_cases} | tr ' ' '\n'|sort -u|xargs)
        IFS=" " read -r -a cases_in_upgrade <<< "${upgrade_success_cases}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"0\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\"/>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    else
        IFS=" " read -r -a cases_in_upgrade <<< "${UPGRADE_FAILURE_TYPE}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"${#cases_in_upgrade[@]}\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\">" >> "${upg_report}"
            echo "    <failure message=\"openshift cluster upgrade failed at ${case}\"></failure>" >> "${upg_report}"
            echo "  </testcase>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    fi
}


# Update RHEL repo before upgrade
function rhel_repo(){
    echo "Updating RHEL node repo"
    local testcase="rhel"
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
    # to be able to SSH.
    if ! whoami &> /dev/null; then
        if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
        else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
            # Explicitly set failure to rhel for rhel worker upgrade failure
            export UPGRADE_FAILURE_TYPE="${testcase}"
            exit 1
        fi
    fi
    TARGET_REPO_VERSION=$(echo "${TARGET_VERSION}" | cut -d'.' -f1,2)
    export TARGET_REPO_VERSION

    cat > /tmp/repo.yaml <<-'EOF'
---
- name: Update repo Playbook
  hosts: workers
  any_errors_fatal: true
  gather_facts: false
  vars:
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
      regexp: "/reposync/[^/]*/"
      replace: "/reposync/{{ target_repo_version }}/"
  - name: Clean up yum cache
    command: yum clean all
EOF

    # current Server version may not be the expected branch when cluster is not fully upgraded 
    # using TARGET_REPO_VERSION instead directly
    version_info="${TARGET_REPO_VERSION}"
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

function rhel_pre_upgrade(){
    cat > /tmp/pre_cordon.yaml <<-'EOF'
---
- name: create a flag file for this playbook under /tmp
  file:
    path: "/tmp/pre_cordon"
    state: touch
  delegate_to: localhost
EOF

    cat > /tmp/pre_uncordon.yaml <<-'EOF'
---
- name: create a flag file for this playbook under /tmp
  file:
    path: "/tmp/pre_uncordon"
    state: touch
  delegate_to: localhost
EOF

    cat > /tmp/pre_upgrade.yaml <<-'EOF'
---
- name: create a flag file for this playbook under /tmp
  file:
    path: "/tmp/pre_upgrade"
    state: touch
  delegate_to: localhost
EOF

    cat > /tmp/post_upgrade.yaml <<-'EOF'
---
- name: create a flag file for this playbook under /tmp
  file:
    path: "/tmp/post_upgrade"
    state: touch
  delegate_to: localhost
EOF

    echo "Adding upgrade hooks to the inventory"
    cat > /tmp/upgrade_hooks <<-'EOF'
openshift_node_pre_cordon_hook=/tmp/pre_cordon.yaml
openshift_node_pre_uncordon_hook=/tmp/pre_uncordon.yaml
openshift_node_pre_upgrade_hook=/tmp/pre_upgrade.yaml
openshift_node_post_upgrade_hook=/tmp/post_upgrade.yaml
EOF

    sed -i '/\[all\:vars\]/r /tmp/upgrade_hooks' "${SHARED_DIR}/ansible-hosts"
}

# Upgrade RHEL node
function rhel_upgrade(){
    echo "Upgrading RHEL nodes"
    echo "Validating parsed Ansible inventory"
    ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
    echo -e "\nRunning RHEL worker upgrade"
    sed -i 's|^remote_tmp.*|remote_tmp = /tmp/.ansible|g' /usr/share/ansible/openshift-ansible/ansible.cfg
    ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /usr/share/ansible/openshift-ansible/playbooks/upgrade.yml -vvv || { export UPGRADE_FAILURE_TYPE="${testcase}"; return 1; }

    check_upgrade_status
}

function rhel_post_upgrade(){
    echo "Run sanity checking after RHEL upgrade"
    local testcase="rhel"
    echo "Check K8s version on the RHEL node"
    master_0=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[0]}{.metadata.name}{"\n"}{end}')
    rhel_0=$(oc get nodes -l node.openshift.io/os_id=rhel -o jsonpath='{range .items[0]}{.metadata.name}{"\n"}{end}')
    exp_version=$(oc get node ${master_0} --output=jsonpath='{.status.nodeInfo.kubeletVersion}' | cut -d '.' -f 1,2)
    act_version=$(oc get node ${rhel_0} --output=jsonpath='{.status.nodeInfo.kubeletVersion}' | cut -d '.' -f 1,2)

    echo -e "Expected K8s version is: ${exp_version}\nActual K8s version is: ${act_version}"
    if [[ ${exp_version} == "${act_version}" ]]; then
        echo "RHEL worker has correct K8s version"
    else
        echo "RHEL worker has incorrect K8s version"
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi

    echo "Check the upgrade hook flags created"
    for hookname in pre_cordon pre_uncordon pre_upgrade post_upgrade; do
        if [[ -f /tmp/${hookname} ]]; then
            echo "The hook ${hookname}.yaml was executed."
        else
            echo "The hook ${hookname}.yaml was NOT executed."
            export UPGRADE_FAILURE_TYPE="${testcase}"
            return 1
        fi
    done
        
    echo "Make sure oc logs works well with pod running on RHEL worker"
    mcd_rhel_pod=$(oc get pod -n openshift-machine-config-operator -o wide | grep "${rhel_0}" |grep "machine-config-daemon" | awk '{print $1}')
    local ret=0
    run_command "oc logs -n openshift-machine-config-operator ${mcd_rhel_pod} -c machine-config-daemon" || ret=1
    if [[ "$ret" == "0" ]]; then
        echo "oc logs checking command passed."
    else
        echo "oc logs checking command failed."
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi

    if [[ "$TARGET_MINOR_VERSION" -ge 14 ]]; then
        cat > /tmp/post_check.yaml <<-'EOF'
---
- name: Run post check on the workers
  hosts: workers
  gather_facts: false
  tasks:
  - name: Ensure fixfiles_exclude_dirs contains '/var/lib/kubelet'
    command: grep -q '/var/lib/kubelet' /etc/selinux/fixfiles_exclude_dirs
    register: grep_result
    ignore_errors: yes

  - name: Fail the play if the expected dir is NOT found
    fail:
      msg: "'/var/lib/kubelet' was NOT found in fixfiles_exclude_dirs. Quitting..."
    when: grep_result.rc != 0
EOF
        ansible-playbook -i "${SHARED_DIR}/ansible-hosts" /tmp/post_check.yaml -vvv || { export UPGRADE_FAILURE_TYPE="${testcase}"; return 1; }
    fi

    echo -e "oc get node -owide\n$(oc get node -owide)"
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" out avail progress cluster_version
    cluster_version="${TARGET_VERSION}"
    
    echo "Starting the upgrade checking on $(date "+%F %T")"
    while (( wait_upgrade > 0 )); do
        sleep 5m
        wait_upgrade=$(( wait_upgrade - 5 ))
        if ! ( run_command "oc get clusterversion" ); then
            continue
        fi
        if ! out="$(oc get clusterversion --no-headers || false)"; then
            echo "Error occurred when getting clusterversion"
            continue
        fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${cluster_version}" ]]; then
            echo -e "Upgrade succeed on $(date "+%F %T")\n\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade timeout on $(date "+%F %T"), exiting\n"
        check_failed_operator
        return 1
    fi
}

# Check version, state in history
function check_history() {
    local version state testcase="OCP-21588"
    version=$(oc get clusterversion/version -o jsonpath='{.status.history[0].version}')
    state=$(oc get clusterversion/version -o jsonpath='{.status.history[0].state}')
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    if [[ ${version} == "${TARGET_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${TARGET_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster upgrade to ${TARGET_VERSION} failed, current version is ${version}, exiting"
	# Explicitly set failure to cvo
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi
}

function check_mcp() {
    local out updated updating degraded try=0 max_retries=30
    while (( try < max_retries )); 
    do
        echo "Checking worker pool status #${try}..."
        echo -e "oc get machineconfigpools\n$(oc get machineconfigpools)"
        out="$(oc get machineconfigpools worker --no-headers)"
        updated="$(echo "${out}" | awk '{print $3}')"
        updating="$(echo "${out}" | awk '{print $4}')"
        degraded="$(echo "${out}" | awk '{print $5}')"

        if [[ ${updated} == "True" && ${updating} == "False" && ${degraded} == "False" ]]; then
            echo "Worker pool status check passed" && return 0
        fi
        sleep 120
        (( try += 1 ))
    done
    echo >&2 "Worker pool status check failed"
    # Explicitly set failure to mco
    export UPGRADE_FAILURE_TYPE="machine-config"
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

# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"
run_command "oc get machineconfigpools"
run_command "oc get machineconfig"

export TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
export TARGET_VERSION
export TARGET_MINOR_VERSION
echo -e "Target release version is: ${TARGET_VERSION}\nTarget minor version is: ${TARGET_MINOR_VERSION}"

SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
export SOURCE_VERSION
export SOURCE_MINOR_VERSION
echo -e "Source release version is: ${SOURCE_VERSION}\nSource minor version is: ${SOURCE_MINOR_VERSION}"
echo -e "The source release version is gotten from clusterversion resource, that can not stand for the current version of worker nodes!"
# Set genenral upgrade ci failure to overall as default
export UPGRADE_FAILURE_TYPE="overall"
# The cases are from existing general checkpoints enabled implicitly in upgrade step, which may be a possible UPGRADE_FAILURE_TYPE
export IMPLICIT_ENABLED_CASES=""
if [[ $(oc get nodes -l node.openshift.io/os_id=rhel) != "" ]]; then
    run_command "oc get node -owide"
    rhel_repo
    rhel_pre_upgrade
    rhel_upgrade
    rhel_post_upgrade
    check_mcp
    check_history
fi
