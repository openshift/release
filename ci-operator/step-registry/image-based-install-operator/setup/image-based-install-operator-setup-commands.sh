#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator setup command ************"

source "${SHARED_DIR}/packet-conf.sh"

echo "Creating Ansible inventory file"
cat > "${SHARED_DIR}/inventory" <<-EOF

[primary]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${CLUSTER_PROFILE_DIR}/packet-ssh-key ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"

EOF

echo "Creating Ansible configuration file"
cat > "${SHARED_DIR}/ansible.cfg" <<-EOF

[defaults]
callback_whitelist = profile_tasks
host_key_checking = False

verbosity = 2
stdout_callback = yaml
bin_ansible_callbacks = True

EOF

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/image-based-install-operator.tar.gz"

echo "export IMG=${IMG}" | ssh "${SSHOPTS[@]}" "root@${IP}" "cat >> /root/env.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

source /root/env.sh

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

REPO_DIR="/home/image-based-install-operator"
if [ ! -d "${REPO_DIR}" ]; then
  mkdir -p "${REPO_DIR}"

  echo "### Untar image-based-install-operator code..."
  tar -xzvf /root/image-based-install-operator.tar.gz -C "${REPO_DIR}"
fi

cd "${REPO_DIR}"

function wait_for_operator() {
    subscription="$1"
    namespace="${2:-}"
    echo "Waiting for operator ${subscription} to get installed on namespace ${namespace}..."

    for _ in $(seq 1 60); do
        csv=$(oc -n "${namespace}" get subscription "${subscription}" -o jsonpath='{.status.installedCSV}' || true)
        if [[ -n "${csv}" ]]; then
            if [[ "$(oc -n "${namespace}" get csv "${csv}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
                echo "ClusterServiceVersion (${csv}) is ready"
                return 0
            fi
        fi

        sleep 10
    done

    echo "Timed out waiting for csv to become ready!"
    return 1
}

function wait_for_crd() {
    crd="$1"
    namespace="${2:-}"

    wait_for_condition "crd/${crd}" "Established" "60s" "${namespace}"
}

function wait_for_condition() {
    object="$1"
    condition="$2"
    timeout="$3"
    namespace="${4:-}"
    selector="${5:-}"

    echo "Waiting for (${object}) on namespace (${namespace}) with labels (${selector}) to be created..."
    for i in {1..40}; do
        oc get ${object} --selector="${selector}" --namespace=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 10
    done

    echo "Waiting for (${object}) on namespace (${namespace}) with labels (${selector}) to become (${condition})..."
    oc wait -n "${namespace}" --for=condition=${condition} --selector "${selector}" ${object} --timeout=${timeout}
}

echo "### Installing hive from operator hub"
tee <<EOCR | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: hive
  labels:
    name: hive
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: hive-group
  namespace: hive
spec:
  targetNamespaces:
    - hive
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hive-operator
  namespace: hive
spec:
  installPlanApproval: Automatic
  name: hive-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  channel: alpha
EOCR

wait_for_operator "hive-operator" "hive"
wait_for_crd "clusterdeployments.hive.openshift.io"

tee <<EOCR | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: HiveConfig
metadata:
  name: hive
spec:
  logLevel: debug
  targetNamespace: hive
EOCR

wait_for_condition "hiveconfig.hive.openshift.io/hive" "Ready" "10m"

echo "Hive installed successfully"

echo "### Installing IBIO"
make deploy
wait_for_condition "pod" "Ready" "10m" "image-based-install-operator" "app=image-based-install-operator"

echo "IBIO installed successfully"

EOF
