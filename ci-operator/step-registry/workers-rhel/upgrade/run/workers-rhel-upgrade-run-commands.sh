#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

trap 'FRC=$?; createUpgradeJunit; debug' ERR EXIT TERM

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

# Generate the Junit for RHEL upgrade
function createUpgradeJunit() {
    echo "Generating the Junit for RHEL upgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_rhel_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="RHEL upgrade" tests="1" failures="0">
  <testcase classname="RHEL upgrade" name="RHEL nodes upgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_rhel_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="RHEL upgrade" tests="1" failures="1">
  <testcase classname="RHEL upgrade" name="RHEL nodes upgrade should succeed"/>
    <failure message="">RHEL nodes upgrade failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

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

# Install an updated version of the client
mkdir -p /tmp/client
curl https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/openshift-client-linux.tar.gz | tar --directory=/tmp/client -xzf -
PATH=/tmp/client:$PATH
oc version --client

echo "$(date -u --rfc-3339=seconds) - Validating parsed Ansible inventory"
ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
echo "$(date -u --rfc-3339=seconds) - Running RHEL worker upgrade"
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" playbooks/upgrade.yml -vvv

export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "$(date -u --rfc-3339=seconds) - Check K8s version on the RHEL node"
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

echo "$(date -u --rfc-3339=seconds) - Get node"
oc get node -owide

echo "$(date -u --rfc-3339=seconds) - RHEL worker upgrade complete"