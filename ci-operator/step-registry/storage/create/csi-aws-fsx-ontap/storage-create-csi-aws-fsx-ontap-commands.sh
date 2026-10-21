#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

TRIDENT_NAMESPACE="trident"
SVM_NAME="trident_svm"
MACHINECONFIG_NAME="99-worker-ci-fsx-ontap-san"
FSXN_TAG="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')-ci-fsx-ontap"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

wait_for() {
  local timeout="$1" interval="$2" description="$3"
  shift 3
  local deadline=$(( $(date +%s) + timeout ))

  until "$@" >/dev/null 2>&1; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      die "timed out waiting for ${description}"
    fi
    sleep "${interval}"
  done
}

random_password() {
  # FSx requires upper-case, lower-case, and numeric characters. The random
  # suffix makes the value unique without relying on a pipe that can fail under
  # pipefail when its reader exits early.
  printf 'Aa1%s\n' "$(od -An -N11 -tx1 /dev/urandom | tr -d ' \n')"
}

random_passphrase() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

require_tools() {
  for tool in aws curl jq oc sha256sum tar; do
    command -v "${tool}" >/dev/null || die "${tool} is required"
  done
}

install_helm() {
  if command -v helm >/dev/null; then
    return
  fi

  local archive="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  curl --fail --location --silent --show-error "https://get.helm.sh/${archive}" -o "/tmp/${archive}"
  curl --fail --location --silent --show-error "https://get.helm.sh/${archive}.sha256sum" -o "/tmp/${archive}.sha256sum"
  (cd /tmp && sha256sum --check --status "${archive}.sha256sum")
  tar -xzf "/tmp/${archive}" -C /tmp
  install -m 0755 /tmp/linux-amd64/helm /tmp/helm
  export PATH="/tmp:${PATH}"
}

discover_cluster_network() {
  REGION="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')"
  [[ -n "${REGION}" ]] || die "cluster is not running on AWS"
  export AWS_DEFAULT_REGION="${REGION}"
  printf '%s\n' "${REGION}" > "${SHARED_DIR}/fsxn-region"

  local provider_id worker_instance instance_json
  provider_id="$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].spec.providerID}')"
  [[ "${provider_id}" == aws://* ]] || die "worker node does not have an AWS provider ID"
  worker_instance="${provider_id##*/}"
  instance_json="$(aws ec2 describe-instances --instance-ids "${worker_instance}" --output json)"
  VPC_ID="$(jq -r '.Reservations[0].Instances[0].VpcId' <<<"${instance_json}")"
  FSXN_SUBNET="$(jq -r '.Reservations[0].Instances[0].SubnetId' <<<"${instance_json}")"
  NODE_SECURITY_GROUP="$(jq -r '.Reservations[0].Instances[0].SecurityGroups[] | select(.GroupName | endswith("-node")) | .GroupId' <<<"${instance_json}" | head -n 1)"
  [[ -n "${NODE_SECURITY_GROUP}" ]] || NODE_SECURITY_GROUP="$(jq -r '.Reservations[0].Instances[0].SecurityGroups[0].GroupId' <<<"${instance_json}")"
  [[ "${VPC_ID}" != "null" && "${FSXN_SUBNET}" != "null" && "${NODE_SECURITY_GROUP}" != "null" ]] || die "could not discover worker networking"
}

create_security_group() {
  local group_name="${FSXN_TAG}-sg"
  FSXN_SECURITY_GROUP="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${group_name}" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ -z "${FSXN_SECURITY_GROUP}" || "${FSXN_SECURITY_GROUP}" == "None" ]]; then
    FSXN_SECURITY_GROUP="$(aws ec2 create-security-group --group-name "${group_name}" --description "Prow CI FSx for NetApp ONTAP SAN access" --vpc-id "${VPC_ID}" --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${group_name}},{Key=ci.openshift.io/owned,Value=true}]" --query GroupId --output text)"
    for port in 3260 4420 443; do
      aws ec2 authorize-security-group-ingress --group-id "${FSXN_SECURITY_GROUP}" --protocol tcp --port "${port}" --source-group "${NODE_SECURITY_GROUP}"
    done
  fi
  printf '%s\n' "${FSXN_SECURITY_GROUP}" > "${SHARED_DIR}/fsxn-security-group-id"
}

create_filesystem() {
  FSXN_FILESYSTEM_ID="$(aws fsx describe-file-systems --query "FileSystems[?Tags[?Key=='Name' && Value=='${FSXN_TAG}']].FileSystemId | [0]" --output text)"
  [[ "${FSXN_FILESYSTEM_ID}" == "None" ]] || die "FSx filesystem ${FSXN_FILESYSTEM_ID} already exists; run the cleanup step before retrying"

  local ontap_configuration
  ontap_configuration="DeploymentType=${FSXN_DEPLOYMENT_TYPE},ThroughputCapacityPerHAPair=${FSXN_THROUGHPUT},HAPairs=1,AutomaticBackupRetentionDays=0,FsxAdminPassword=${FSX_ADMIN_PASSWORD}"
  FSXN_FILESYSTEM_ID="$(aws fsx create-file-system --file-system-type ONTAP --storage-capacity "${FSXN_STORAGE_GIB}" --subnet-ids "${FSXN_SUBNET}" --security-group-ids "${FSXN_SECURITY_GROUP}" --ontap-configuration "${ontap_configuration}" --tags "Key=Name,Value=${FSXN_TAG}" "Key=ci.openshift.io/owned,Value=true" --query 'FileSystem.FileSystemId' --output text)"
  printf '%s\n' "${FSXN_FILESYSTEM_ID}" > "${SHARED_DIR}/fsxn-filesystem-id"
  wait_for 3000 30 "FSx filesystem ${FSXN_FILESYSTEM_ID}" bash -c "[[ \$(aws fsx describe-file-systems --file-system-ids '${FSXN_FILESYSTEM_ID}' --query 'FileSystems[0].Lifecycle' --output text) == AVAILABLE ]]"
}

prepare_workers() {
  local multipath_config nvme_module
  multipath_config="data:text/plain;base64,$(base64 -w0 <<'EOF'
defaults {
    user_friendly_names no
    find_multipaths no
}
blacklist {
    device {
        vendor "NVME"
        product "Amazon Elastic Block Store"
    }
}
EOF
)"
  nvme_module='data:,nvme_tcp%0A'

  cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: ${MACHINECONFIG_NAME}
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
      - path: /etc/multipath.conf
        mode: 420
        overwrite: true
        contents:
          source: ${multipath_config}
      - path: /etc/modules-load.d/nvme-tcp.conf
        mode: 420
        overwrite: true
        contents:
          source: ${nvme_module}
    systemd:
      units:
      - name: iscsid.service
        enabled: true
      - name: multipathd.service
        enabled: true
      - name: ci-fsx-ontap-identities.service
        enabled: true
        contents: |
          [Unit]
          Description=Generate unique iSCSI and NVMe host identities for FSx CI
          Before=kubelet.service iscsid.service
          ConditionPathExists=!/var/lib/ci-fsx-ontap-identities.done
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStartPre=/usr/bin/mkdir -p /etc/nvme /etc/iscsi
          ExecStart=/usr/bin/sh -c '/usr/sbin/nvme gen-hostnqn > /etc/nvme/hostnqn'
          ExecStart=/usr/bin/sh -c '/usr/bin/uuidgen > /etc/nvme/hostid'
          ExecStart=/usr/bin/sh -c 'echo "InitiatorName=\$(/usr/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi'
          ExecStart=/usr/bin/touch /var/lib/ci-fsx-ontap-identities.done
          [Install]
          WantedBy=multi-user.target
EOF

  printf '%s\n' "${MACHINECONFIG_NAME}" > "${SHARED_DIR}/fsxn-machineconfig-name"
  wait_for 3000 30 "worker MachineConfigPool update" bash -c 'read -r updating updated degraded < <(oc get mcp worker -o jsonpath="{.status.conditions[?(@.type==\"Updating\")].status} {.status.conditions[?(@.type==\"Updated\")].status} {.status.conditions[?(@.type==\"Degraded\")].status}"); [[ "$updating" == False && "$updated" == True && "$degraded" == False ]]'
}

create_svm() {
  FSXN_SVM_ID="$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=${FSXN_FILESYSTEM_ID}" --query "StorageVirtualMachines[?Name=='${SVM_NAME}'].StorageVirtualMachineId | [0]" --output text)"
  if [[ "${FSXN_SVM_ID}" == "None" ]]; then
    FSXN_SVM_ID="$(aws fsx create-storage-virtual-machine --file-system-id "${FSXN_FILESYSTEM_ID}" --name "${SVM_NAME}" --svm-admin-password "${SVM_ADMIN_PASSWORD}" --query 'StorageVirtualMachine.StorageVirtualMachineId' --output text)"
  fi
  printf '%s\n' "${FSXN_SVM_ID}" > "${SHARED_DIR}/fsxn-svm-id"
  wait_for 1200 20 "FSx SVM ${SVM_NAME}" bash -c "[[ \$(aws fsx describe-storage-virtual-machines --storage-virtual-machine-ids '${FSXN_SVM_ID}' --query 'StorageVirtualMachines[0].Lifecycle' --output text) == CREATED ]]"
  SVM_MANAGEMENT_LIF="$(aws fsx describe-storage-virtual-machines --storage-virtual-machine-ids "${FSXN_SVM_ID}" --query 'StorageVirtualMachines[0].Endpoints.Management.IpAddresses[0]' --output text)"
  [[ "${SVM_MANAGEMENT_LIF}" != "None" ]] || die "SVM does not have a management LIF"
  printf '%s\n' "${SVM_MANAGEMENT_LIF}" > "${SHARED_DIR}/fsxn-svm-management-lif"
}

install_trident() {
  install_helm
  helm repo add netapp-trident https://netapp.github.io/trident-helm-chart --force-update
  helm upgrade --install trident netapp-trident/trident-operator --version "${TRIDENT_CHART_VERSION}" --create-namespace --namespace "${TRIDENT_NAMESPACE}" --wait --timeout 15m
  wait_for 900 15 "Trident installation" bash -c "[[ \$(oc get tridentorchestrator trident -o jsonpath='{.status.status}' 2>/dev/null) == Installed ]]"
  oc rollout status daemonset/trident-node-linux --namespace "${TRIDENT_NAMESPACE}" --timeout=10m
}

configure_trident() {
  oc create secret generic fsxn-backend-credentials --namespace "${TRIDENT_NAMESPACE}" --from-literal=username=vsadmin --from-literal=password="${SVM_ADMIN_PASSWORD}" --dry-run=client -o yaml | oc apply -f -
  oc create secret generic fsxn-luks --namespace "${TRIDENT_NAMESPACE}" --from-literal=luks-passphrase-name=A --from-literal=luks-passphrase="${LUKS_PASSPHRASE}" --dry-run=client -o yaml | oc apply -f -

  cat <<EOF | oc apply -f -
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ci-fsxn-iscsi
  namespace: ${TRIDENT_NAMESPACE}
spec:
  version: 1
  storageDriverName: ontap-san
  backendName: ci-fsxn-iscsi
  sanType: iscsi
  useREST: true
  svm: ${SVM_NAME}
  managementLIF: ${SVM_MANAGEMENT_LIF}
  storagePrefix: ci_iscsi_
  credentials:
    name: fsxn-backend-credentials
  labels:
    protocol: iscsi
---
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ci-fsxn-iscsi-luks
  namespace: ${TRIDENT_NAMESPACE}
spec:
  version: 1
  storageDriverName: ontap-san
  backendName: ci-fsxn-iscsi-luks
  sanType: iscsi
  useREST: true
  svm: ${SVM_NAME}
  managementLIF: ${SVM_MANAGEMENT_LIF}
  storagePrefix: ci_iscsi_luks_
  credentials:
    name: fsxn-backend-credentials
  labels:
    protocol: iscsi-luks
  defaults:
    luksEncryption: "true"
---
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ci-fsxn-nvme
  namespace: ${TRIDENT_NAMESPACE}
spec:
  version: 1
  storageDriverName: ontap-san
  backendName: ci-fsxn-nvme
  sanType: nvme
  useREST: true
  svm: ${SVM_NAME}
  managementLIF: ${SVM_MANAGEMENT_LIF}
  storagePrefix: ci_nvme_
  credentials:
    name: fsxn-backend-credentials
  labels:
    protocol: nvme
---
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ci-fsxn-nvme-luks
  namespace: ${TRIDENT_NAMESPACE}
spec:
  version: 1
  storageDriverName: ontap-san
  backendName: ci-fsxn-nvme-luks
  sanType: nvme
  useREST: true
  svm: ${SVM_NAME}
  managementLIF: ${SVM_MANAGEMENT_LIF}
  storagePrefix: ci_nvme_luks_
  credentials:
    name: fsxn-backend-credentials
  labels:
    protocol: nvme-luks
  defaults:
    luksEncryption: "true"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ci-netapp-iscsi
provisioner: csi.trident.netapp.io
allowVolumeExpansion: true
parameters:
  backendType: ontap-san
  selector: protocol=iscsi
  fsType: ext4
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ci-netapp-iscsi-luks
provisioner: csi.trident.netapp.io
allowVolumeExpansion: true
parameters:
  backendType: ontap-san
  selector: protocol=iscsi-luks
  fsType: ext4
  csi.storage.k8s.io/node-stage-secret-name: fsxn-luks
  csi.storage.k8s.io/node-stage-secret-namespace: ${TRIDENT_NAMESPACE}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ci-netapp-nvme
provisioner: csi.trident.netapp.io
allowVolumeExpansion: true
parameters:
  backendType: ontap-san
  selector: protocol=nvme
  fsType: ext4
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ci-netapp-nvme-luks
provisioner: csi.trident.netapp.io
allowVolumeExpansion: true
parameters:
  backendType: ontap-san
  selector: protocol=nvme-luks
  fsType: ext4
  csi.storage.k8s.io/node-stage-secret-name: fsxn-luks
  csi.storage.k8s.io/node-stage-secret-namespace: ${TRIDENT_NAMESPACE}
EOF

  for backend in ci-fsxn-iscsi ci-fsxn-iscsi-luks ci-fsxn-nvme ci-fsxn-nvme-luks; do
    wait_for 300 10 "Trident backend ${backend}" bash -c "[[ \$(oc get tridentbackendconfig '${backend}' -n '${TRIDENT_NAMESPACE}' -o jsonpath='{.status.phase}' 2>/dev/null) == Bound ]]"
  done
}

verify_storageclass() {
  local storageclass="$1" volume_mode="$2" suffix="$3"
  local namespace="fsxn-trident-smoke"
  local pvc="${storageclass}-${suffix}"
  local pod="${pvc}-pod"
  local volume_consumer

  if [[ "${volume_mode}" == "Block" ]]; then
    volume_consumer='    volumeDevices:
    - name: volume
      devicePath: /dev/volume'
  else
    volume_consumer='    volumeMounts:
    - name: volume
      mountPath: /volume'
  fi

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${namespace}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${storageclass}
  volumeMode: ${volume_mode}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${namespace}
spec:
  restartPolicy: Never
  containers:
  - name: consumer
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["sh", "-c", "sleep 3600"]
${volume_consumer}
  volumes:
  - name: volume
    persistentVolumeClaim:
      claimName: ${pvc}
EOF
  oc wait --for=jsonpath='{.status.phase}'=Bound "pvc/${pvc}" --namespace "${namespace}" --timeout=10m
  oc wait --for=condition=Ready "pod/${pod}" --namespace "${namespace}" --timeout=10m
}

smoke_test_storageclasses() {
  local status=0

  oc create namespace fsxn-trident-smoke --dry-run=client -o yaml | oc apply -f -
  for storageclass in ci-netapp-iscsi ci-netapp-iscsi-luks ci-netapp-nvme ci-netapp-nvme-luks; do
    if ! verify_storageclass "${storageclass}" Filesystem fs; then
      status=1
      break
    fi
    if ! verify_storageclass "${storageclass}" Block block; then
      status=1
      break
    fi
  done
  oc delete namespace fsxn-trident-smoke --ignore-not-found --wait=true --timeout=15m
  return "${status}"
}

main() {
  require_tools
  FSX_ADMIN_PASSWORD="$(random_password)"
  SVM_ADMIN_PASSWORD="$(random_password)"
  LUKS_PASSPHRASE="$(random_passphrase)"

  discover_cluster_network
  create_security_group
  create_filesystem
  prepare_workers
  create_svm
  install_trident
  configure_trident
  smoke_test_storageclasses
}

main "$@"
