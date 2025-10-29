#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi


echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME="kni-qe-99"
echo CLUSTER_NAME=${CLUSTER_NAME}

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/kni-qe-99/auth/kubeconfig"

# deploy ztp operators (acm, lso, gitops)
cd /eco-ci-cd/
ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=$VERSION disconnected=$DISCONNECTED operators='$OPERATORS'"

# configure lso
ansible-playbook playbooks/ran/configure-lvm-storage.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --private-key ~/.ssh/ansible_ssh_private_key --extra-vars "kubeconfig=${KUBECONFIG_PATH}"

echo "Creating MultiClusterHub Resource"
oc create -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF

echo "Waiting for MultiClusterHub to reach Running status..."
timeout=600
elapsed=0
while [ $elapsed -lt $timeout ]; do
  status=$(oc get mch -o=jsonpath='{.items[0].status.phase}' -n open-cluster-management 2>/dev/null || echo "NotFound")
  if [ "$status" == "Running" ]; then
    echo "MultiClusterHub is Running"
    break
  fi
  echo "Current status: $status. Waiting..."
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "$status" != "Running" ]; then
  echo "ERROR: MultiClusterHub did not reach Running status within ${timeout} seconds"
  exit 1
fi

echo "Creating ConfigMap for mirror registry"
oc create -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: multicluster-engine
data:
  registries.conf: |
    unqualified-search-registries = ["registry.access.redhat.com", "docker.io"]
    short-name-mode = ""

    [[registry]]
      prefix = ""
      location = "quay.io/openshift-release-dev"

      [[registry.mirror]]
        location = "ocp-qe-01.savanna.lab.eng.rdu2.redhat.com:5015/openshift-release-dev"
        pull-from-mirror = "digest-only"

    [[registry]]
      prefix = ""
      location = "registry.access.redhat.com/openshift4/ose-oauth-proxy"

      [[registry.mirror]]
        location = "brew.registry.redhat.io/openshift4/ose-oauth-proxy"
        pull-from-mirror = "digest-only"

    [[registry]]
      prefix = ""
      location = "registry.ci.openshift.org/ocp"

      [[registry.mirror]]
        location = "ocp-qe-01.savanna.lab.eng.rdu2.redhat.com:5015/ocp"
        pull-from-mirror = "digest-only"

    [[registry]]
      prefix = ""
      location = "registry.redhat.io/multicluster-engine"

      [[registry.mirror]]
        location = "brew.registry.redhat.io/multicluster-engine"
        pull-from-mirror = "digest-only"

    [[registry]]
      prefix = ""
      location = "registry.redhat.io/rhacm2"

      [[registry.mirror]]
        location = "brew.registry.redhat.io/rhacm2"
        pull-from-mirror = "digest-only"
EOF

echo "Creating AgentServiceConfig"
oc create -f - <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
  name: agent
  namespace: multicluster-engine
spec:
  databaseStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
  filesystemStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
  mirrorRegistryRef:
    name: mirror-registry-ca
  osImages:
    - openshiftVersion: "4.17"
      version: "417.94.202410090854-0"
      url: "https://rhcos.mirror.openshift.com/art/storage/prod/streams/4.17-9.4/builds/417.94.202410090854-0/x86_64/rhcos-417.94.202410090854-0-live.x86_64.iso"
      cpuArchitecture: "x86_64"
EOF

echo "Waiting for assisted-service pod to be running..."
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
  pod_status=$(oc get pods -n multicluster-engine | grep assisted-service | grep -c "Running" || echo "0")
  if [ "$pod_status" -gt 0 ]; then
    echo "assisted-service pod is Running:"
    oc get pods -n multicluster-engine | grep assisted-service
    break
  fi
  echo "Waiting for assisted-service pod..."
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "$pod_status" -eq 0 ]; then
  echo "ERROR: assisted-service pod did not reach Running status within ${timeout} seconds"
  exit 1
fi

echo "Applying Provisioning resource"
oc apply -f - <<EOF
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  preProvisioningOSDownloadURLs: {}
  provisioningNetwork: Disabled
  watchAllNamespaces: true
EOF

echo "Waiting for metal3 pods to be running..."
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
  metal3_pods=$(oc get pods -A | grep metal | grep -c "Running" || echo "0")
  if [ "$metal3_pods" -ge 3 ]; then
    echo "metal3 pods are Running:"
    oc get pods -A | grep metal
    break
  fi
  echo "Waiting for metal3 pods... (current running: $metal3_pods)"
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "$metal3_pods" -lt 3 ]; then
  echo "WARNING: Expected metal3 pods did not all reach Running status within ${timeout} seconds"
  oc get pods -A | grep metal || echo "No metal3 pods found"
fi

echo "Hub configuration completed successfully"
