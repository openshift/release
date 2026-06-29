#!/usr/bin/env bash
# Configure an NFS server on the disconnected bastion and create a StorageClass
# and PersistentVolume backed by that export. Uses soft NFS mount so storage
# loss surfaces as I/O errors for SBR fault detection.
set -euo pipefail

# OpenShift assigns a random UID to the step pod; if it has no /etc/passwd
# entry, ssh fails with "No user exists for uid NNNN". Add one if needed.
if ! whoami &>/dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "user:x:$(id -u):0:user:/tmp:/bin/bash" >> /etc/passwd
    fi
fi
export HOME=/tmp

# In disconnected environments all cluster API traffic goes through the bastion
# proxy; without this, oc apply can't resolve/reach the cluster API endpoint.
[[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && source "${SHARED_DIR}/proxy-conf.sh"

BASTION_PUBLIC=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
BASTION_PRIVATE=$(head -n 1 "${SHARED_DIR}/bastion_private_address")
BASTION_USER=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
SSH_KEY="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

NFS_EXPORT="/srv/nfs/sbr"
# NFS server container — the CI bastion is Fedora CoreOS (immutable OS, no
# nfs-utils installed). The bastion already runs services as podman containers
# (squid proxy, mirror registry), so we do the same for NFS.
# Uses the upstream Kubernetes e2e NFS test image (Fedora-based, multi-arch).
NFS_IMAGE="registry.k8s.io/e2e-test-images/volume/nfs:1.6.0"

# AWS credentials for security group update
REGION="${REGION:-${LEASED_RESOURCE}}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${REGION}"

ssh_bastion() {
    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY}" \
        "${BASTION_USER}@${BASTION_PUBLIC}" \
        "$@"
}

echo "Configuring NFS server on bastion (containerized, FCOS-compatible)"

# Open port 2049 (NFS) on the bastion security group — not present by default.
# Cluster nodes need this to mount the NFS export.
echo "Opening NFS port 2049 on bastion security group..."
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=dns-name,Values=${BASTION_PUBLIC}" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].VpcId" --output text)
SG_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
    --query "Vpcs[0].CidrBlock" --output text)
echo "  bastion instance=${INSTANCE_ID} sg=${SG_ID} vpc_cidr=${VPC_CIDR}"
aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" --protocol tcp --port 2049 --cidr "${VPC_CIDR}" \
    || true  # idempotent — ignore "already exists" error

ssh_bastion "sudo mkdir -p ${NFS_EXPORT} && sudo chmod 777 ${NFS_EXPORT}"

# Pull and run NFS v4 server in a privileged podman container.
# --net host: binds to both the public and private bastion IPs so cluster
#             nodes can reach it via the private address in the PV spec.
# --restart always: survives podman restarts.
ssh_bastion "sudo podman pull ${NFS_IMAGE}"
ssh_bastion "sudo podman run -d \
    --name nfs-sbr \
    --privileged \
    --net host \
    --restart always \
    -v ${NFS_EXPORT}:${NFS_EXPORT}:z \
    ${NFS_IMAGE} ${NFS_EXPORT}"

# Give the server a moment to start, then verify it is exporting
sleep 5
ssh_bastion "sudo podman exec nfs-sbr showmount -e localhost 2>/dev/null || true"
echo "NFS server ready"

# Pre-create SBR device files on the NFS export so the operator's init Job
# (registry.access.redhat.com/ubi8/ubi-minimal:latest) exits 0 immediately
# upon finding existing files — bypassing any image pull timing issue.
# Filenames match agent.SharedStorageSBRDeviceFile / SharedStorageFenceDeviceSuffix
# / SharedStorageNodeMappingSuffix as defined in internal/agent/flags.go.
echo "Pre-creating SBR device files on NFS export..."
ssh_bastion "
    sudo dd if=/dev/zero of=${NFS_EXPORT}/sbr-device bs=1024 count=1024 2>/dev/null
    sudo dd if=/dev/zero of=${NFS_EXPORT}/sbr-device-fence bs=1024 count=1024 2>/dev/null
    printf '{\"pre-created\":true}\n' | sudo tee ${NFS_EXPORT}/sbr-device-nodemap >/dev/null
    sudo chmod 664 ${NFS_EXPORT}/sbr-device ${NFS_EXPORT}/sbr-device-fence ${NFS_EXPORT}/sbr-device-nodemap
"
echo "SBR device files pre-created"

# Create StorageClass backed by the bastion NFS export.
# soft + timeo=50: if the NFS server becomes unreachable the kernel returns
# EIO to the caller after ~5 seconds instead of retrying indefinitely.
# Without soft mount, SBR storage loss tests would hang in kernel retries
# and never trigger the remediation path.
oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-sbr
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
mountOptions:
  - vers=4.1
  - soft
  - timeo=50
EOF

oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-sbr-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - vers=4.1
    - soft
    - timeo=50
  nfs:
    server: ${BASTION_PRIVATE}
    path: ${NFS_EXPORT}
  storageClassName: nfs-sbr
  persistentVolumeReclaimPolicy: Retain
EOF

# The SBR controller's validateStorageClass uses kubernetes.io/no-provisioner (unknown
# provisioner) so it falls through to testRWXSupport, which creates a temporary 1Gi
# PVC. The best-fit scheduler binds that PVC to the smallest matching PV. If our only
# PV is 10Gi, the test consumes it and then patches its reclaim policy to Delete —
# leaving the actual SBRC PVC (10Mi) with no PV to bind to.
# Workaround: provide a 1Gi decoy PV sized to attract the test PVC exactly, keeping
# the 10Gi PV available for the real SBRC workload.
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-sbr-pv-test
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - vers=4.1
    - soft
    - timeo=50
  nfs:
    server: ${BASTION_PRIVATE}
    path: ${NFS_EXPORT}
  storageClassName: nfs-sbr
  persistentVolumeReclaimPolicy: Delete
EOF

echo "StorageClass 'nfs-sbr' and PersistentVolumes created"
oc get sc nfs-sbr
oc get pv nfs-sbr-pv nfs-sbr-pv-test

# --- Mirror UBI base image for SBR operator init Job ---
# The SBR operator's ensureSBRDevice() init Job hardcodes
# registry.access.redhat.com/ubi8/ubi-minimal:latest. This image is not in the
# operator's relatedImages (so oc-mirror never mirrors it) and uses a tag
# reference which IDMS cannot redirect. We mirror it manually and create an ITMS.
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "Mirroring ubi8/ubi-minimal to disconnected registry ${MIRROR_REGISTRY_HOST}..."
ssh_bastion "sudo skopeo copy --retry-times 3 \
    --src-tls-verify=true --dest-tls-verify=false \
    --authfile=/tmp/new_pull_secret \
    docker://registry.access.redhat.com/ubi8/ubi-minimal:latest \
    docker://${MIRROR_REGISTRY_HOST}/ubi8/ubi-minimal:latest" \
    || { echo "ERROR: failed to mirror ubi8/ubi-minimal"; exit 1; }
echo "UBI image mirrored"

# Create an ImageTagMirrorSet so CRI-O redirects the tag-based pull to the mirror.
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ubi-minimal-mirror
spec:
  imageTagMirrors:
  - source: registry.access.redhat.com/ubi8/ubi-minimal
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/ubi8/ubi-minimal
EOF

# Wait for ITMS to propagate to all nodes by actively verifying the image is pullable.
# The previous approach (watching MCP rendered config names) is unreliable: ITMS may
# update CRI-O config via a path that does not change the rendered MachineConfig name.
# Active verification is the only reliable signal that nodes have picked up the mirror.
echo "Waiting for ubi8/ubi-minimal to be pullable via ITMS mirror (up to 12m)..."
UBI_PULLABLE=false
for i in $(seq 1 24); do
    sleep 30
    oc delete pod sbr-ubi-preflight --ignore-not-found --wait=false 2>/dev/null || true
    POD_PHASE=$(oc run sbr-ubi-preflight \
        --image=registry.access.redhat.com/ubi8/ubi-minimal:latest \
        --restart=Never \
        --command -- sh -c 'echo PREFLIGHT_OK' 2>/dev/null && \
        timeout 30 bash -c 'until [[ $(oc get pod sbr-ubi-preflight -o jsonpath="{.status.phase}" 2>/dev/null) =~ ^(Succeeded|Failed)$ ]]; do sleep 2; done; oc get pod sbr-ubi-preflight -o jsonpath="{.status.phase}"' \
        2>/dev/null || true)
    if [[ "$POD_PHASE" == "Succeeded" ]]; then
        echo "  ubi8/ubi-minimal pullable after $((i * 30))s"
        UBI_PULLABLE=true
        oc delete pod sbr-ubi-preflight --ignore-not-found 2>/dev/null || true
        break
    fi
    echo "  attempt ${i}/24: image not yet pullable (phase=${POD_PHASE:-pending}), retrying in 30s..."
    oc delete pod sbr-ubi-preflight --ignore-not-found --wait=false 2>/dev/null || true
done

if [[ "${UBI_PULLABLE}" != "true" ]]; then
    echo "WARNING: ubi8/ubi-minimal not pullable after 12m — ITMS may not have propagated."
    echo "  SBR init Job may fail; device files are pre-created so it will retry quickly."
    oc get mcp 2>/dev/null || true
fi

# For the watchdog test, use the OCP release cli image — it's already mirrored
# as part of the release payload and has the basic tools the probe pods need.
WATCHDOG_IMAGE=$(oc adm release info --image-for=cli 2>/dev/null || true)
if [[ -n "$WATCHDOG_IMAGE" ]]; then
    echo "Using release cli image for watchdog probes: ${WATCHDOG_IMAGE}"
    echo "${WATCHDOG_IMAGE}" > "${SHARED_DIR}/sbr_watchdog_debug_image"
else
    echo "WARNING: could not resolve release cli image, watchdog probes will use default"
fi

echo "UBI mirror setup complete"
