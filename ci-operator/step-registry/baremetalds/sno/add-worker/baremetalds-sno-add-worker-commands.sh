#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds SNO add-worker ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

timeout -s 9 80m ssh "${SSHOPTS[@]}" "root@${IP}" bash -s \
  "${WORKER_VCPU}" "${WORKER_MEMORY}" "${WORKER_DISK}" << 'REMOTE_SCRIPT'
set -xeo pipefail

WORKER_VCPU="$1"
WORKER_MEMORY="$2"
WORKER_DISK_GB="$3"

cd /root/dev-scripts
source common.sh
source ocp_install_env.sh

export KUBECONFIG
KUBECONFIG=$(ls /root/dev-scripts/ocp/*/auth/kubeconfig)

MASTER_VM="${CLUSTER_NAME}_master_0"
WORKER_NAME="${CLUSTER_NAME}_worker_0"
WORKER_MAC="52:54:00:ee:42:02"
INSTALLATION_DISK="/dev/vda"

# Use the baremetal network from dev-scripts (not provisioning)
NETWORK_NAME="${BAREMETAL_NETWORK_NAME}"
echo "Using baremetal network: ${NETWORK_NAME}"

# Compute worker IP: master DHCP entry's last octet + 1
MASTER_IP=$(virsh net-dumpxml "${NETWORK_NAME}" | grep -oP "ip='\K[^']+" | head -1)
WORKER_LAST_OCTET=$(echo "${MASTER_IP}" | awk -F. '{print $4+1}')
if (( WORKER_LAST_OCTET > 254 )); then
  echo "ERROR: computed worker IP octet ${WORKER_LAST_OCTET} is invalid" >&2
  exit 1
fi
WORKER_IP=$(echo "${MASTER_IP}" | awk -F. -v o="${WORKER_LAST_OCTET}" '{printf "%s.%s.%s.%d", $1, $2, $3, o}')
echo "Master IP: ${MASTER_IP}, Worker IP: ${WORKER_IP}"

# --- Worker ignition ---
# MCS (port 22623) is fronted by haproxy on the API VIP. Extract the API
# host from the working kubeconfig — it resolves to the correct IP.
echo "=== Fetching worker ignition from MCS ==="
API_HOST=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | cut -d: -f1)
echo "API host from kubeconfig: ${API_HOST}"
curl -sk --connect-timeout 10 "https://${API_HOST}:22623/config/worker" > /tmp/worker.ign || true
if [[ ! -s /tmp/worker.ign ]]; then
  echo "MCS via API host failed, trying master IP..." >&2
  curl -sk --connect-timeout 10 "https://${MASTER_IP}:22623/config/worker" > /tmp/worker.ign || true
fi
if [[ ! -s /tmp/worker.ign ]]; then
  echo "MCS unreachable, extracting pointer ignition via oc (worker will need MCS access)" >&2
  oc extract -n openshift-machine-api secret/worker-user-data \
    --keys=userData --to=- > /tmp/worker.ign
fi
echo "Worker ignition size: $(wc -c < /tmp/worker.ign) bytes"

# --- Worker live-ISO ignition ---
echo "=== Building worker live-ISO ignition ==="
set +x
WORKER_IGN_B64=$(base64 -w0 /tmp/worker.ign)
if [[ -f /root/dev-scripts/config_root.sh ]]; then
  source /root/dev-scripts/config_root.sh
fi
SSH_PUB_KEY="${SSH_PUB_KEY:-$(cat /root/.ssh/id_rsa.pub 2>/dev/null || true)}"
set -x

INSTALL_SCRIPT_B64=$(base64 -w0 <<'INSTALL_SH'
#!/bin/bash
set -euxo pipefail
coreos-installer install --ignition=/root/config.ign ${INSTALL_DEVICE}
touch /tmp/install-done
INSTALL_SH
)

cat > /tmp/worker-live-iso.ign <<WORKERLIVEIGN
{
  "ignition": {
    "config": {},
    "version": "3.1.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": ["${SSH_PUB_KEY}"]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/root/config.ign",
        "mode": 420,
        "overwrite": true,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,${WORKER_IGN_B64}"
        }
      },
      {
        "path": "/usr/local/bin/install.sh",
        "mode": 493,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,${INSTALL_SCRIPT_B64}"
        }
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "[Unit]\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/install.sh\nEnvironment=INSTALL_DEVICE=${INSTALLATION_DISK}\nStandardOutput=journal+console\nStandardError=journal+console\n[Install]\nWantedBy=multi-user.target\n",
        "enabled": true,
        "name": "coreos-install.service"
      }
    ]
  }
}
WORKERLIVEIGN

# --- RHCOS ISO ---
echo "=== Preparing RHCOS ISO for worker ==="
OPENSHIFT_INSTALL=$(find /root/dev-scripts -name openshift-install -type f -executable 2>/dev/null | head -1)
RHCOS_ISO_URL=$("${OPENSHIFT_INSTALL}" coreos print-stream-json 2>/dev/null | \
  python3 -c "import sys, json; d=json.load(sys.stdin); print(d['architectures']['x86_64']['artifacts']['metal']['formats']['iso']['disk']['location'])")
ISO_FILENAME=$(basename "${RHCOS_ISO_URL}")

CACHED_ISO=$(find /root -name "${ISO_FILENAME}" -type f 2>/dev/null | head -1)
WORKER_ISO="/var/lib/libvirt/images/worker-image.iso"

if [[ -n "${CACHED_ISO}" ]]; then
  echo "Using cached RHCOS ISO: ${CACHED_ISO}"
  cp "${CACHED_ISO}" "${WORKER_ISO}"
else
  echo "Downloading RHCOS ISO..."
  curl -L -o "${WORKER_ISO}" "${RHCOS_ISO_URL}"
fi

# Embed worker ignition into the ISO
for attempt in $(seq 1 5); do
  if podman run --rm --privileged --security-opt label=disable \
    -v /dev:/dev -v /run/udev:/run/udev \
    -v /tmp:/tmp -v /var/lib/libvirt/images:/var/lib/libvirt/images \
    quay.io/coreos/coreos-installer:release \
    iso ignition embed "${WORKER_ISO}" \
    -f --ignition-file /tmp/worker-live-iso.ign; then
    echo "Worker ISO embedded on attempt ${attempt}"
    break
  fi
  echo "Embed attempt ${attempt} failed, retrying..."
  sleep 10
  if [[ "${attempt}" -eq 5 ]]; then
    echo "Failed to embed worker ISO after 5 attempts" >&2
    exit 1
  fi
done

sudo chcon -t svirt_image_t "${WORKER_ISO}" 2>/dev/null || true

# --- Create worker VM ---
echo "=== Creating worker VM ==="

# Add DHCP reservation
virsh net-update "${NETWORK_NAME}" add ip-dhcp-host \
  "<host mac='${WORKER_MAC}' ip='${WORKER_IP}'/>" --live --config || true

# Create worker disk
WORKER_DISK_PATH="/var/lib/libvirt/images/${WORKER_NAME}-disk-0.qcow2"
qemu-img create -f qcow2 "${WORKER_DISK_PATH}" "${WORKER_DISK_GB}G"

cat > /tmp/worker-vm.xml <<VMXML
<domain type='kvm'>
  <name>${WORKER_NAME}</name>
  <memory unit='MiB'>${WORKER_MEMORY}</memory>
  <vcpu>${WORKER_VCPU}</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
  </os>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='unsafe'/>
      <source file='${WORKER_DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
      <boot order='2'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='${WORKER_ISO}'/>
      <target dev='sda' bus='scsi'/>
      <readonly/>
      <boot order='1'/>
    </disk>
    <interface type='network'>
      <source network='${NETWORK_NAME}'/>
      <mac address='${WORKER_MAC}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' listen='127.0.0.1' autoport='yes'/>
  </devices>
</domain>
VMXML

virsh define /tmp/worker-vm.xml
virsh start "${WORKER_NAME}"
echo "Worker VM started (booting from live ISO)"

# --- Wait for coreos-installer to complete on the live ISO ---
echo "=== Waiting for live ISO to boot and install to disk ==="

echo "Waiting for VM to become reachable..."
for i in $(seq 1 60); do
  if ping -c 1 -W 2 "${WORKER_IP}" > /dev/null 2>&1; then
    echo "VM reachable after $((i * 10)) seconds"
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    echo "VM never became reachable" >&2
    virsh domstate "${WORKER_NAME}"
    exit 1
  fi
  sleep 10
done

echo "Waiting for coreos-installer to finish writing to disk..."
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
       core@"${WORKER_IP}" "test -f /tmp/install-done" 2>/dev/null; then
    echo "coreos-installer completed after $((i * 10)) seconds"
    break
  fi
  if (( i % 6 == 0 )); then
    echo "Still waiting for install... (${i}0s)"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      core@"${WORKER_IP}" "\
        systemctl is-active coreos-install.service 2>/dev/null || echo 'service not active'; \
        journalctl -u coreos-install.service --no-pager -n 3 2>/dev/null \
      " 2>/dev/null || echo "SSH check failed"
  fi
  if [[ "${i}" -eq 60 ]]; then
    echo "coreos-installer did not complete in time" >&2
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      core@"${WORKER_IP}" "journalctl -u coreos-install.service --no-pager" 2>/dev/null || true
    exit 1
  fi
  sleep 10
done

# --- Restart VM from installed disk ---
echo "=== Detaching ISO and restarting VM from disk ==="
virsh destroy "${WORKER_NAME}"
sleep 2

virsh detach-disk "${WORKER_NAME}" sda --persistent 2>/dev/null || \
  virsh change-media "${WORKER_NAME}" sda --eject --config 2>/dev/null || true
echo "ISO detached from VM"

virsh start "${WORKER_NAME}"
echo "Worker VM restarted (booting from installed disk)"

# --- CSR approval + wait ---
echo "=== Waiting for worker to join cluster ==="

(
  while true; do
    pending=$(oc get csr -o jsonpath='{.items[?(@.status == {})].metadata.name}' 2>/dev/null || true)
    for csr_name in ${pending}; do
      echo "Approving CSR: ${csr_name}"
      oc adm certificate approve "${csr_name}" 2>/dev/null || true
    done
    sleep 10
  done
) &
CSR_APPROVER_PID=$!

WAIT_ITER=0
timeout 60m bash -c '
  WAIT_ITER=0
  while true; do
    WAIT_ITER=$((WAIT_ITER + 1))
    if oc get nodes --no-headers 2>/dev/null | grep -v "master\|control-plane" | grep -q "Ready"; then
      echo "Worker node is Ready!"
      break
    fi
    if (( WAIT_ITER % 6 == 1 )); then
      echo "--- debug: VM state ---"
      virsh domstate "'"${WORKER_NAME}"'" 2>/dev/null || true
      if ping -c 1 -W 2 "'"${WORKER_IP}"'" > /dev/null 2>&1; then
        echo "worker reachable"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
          core@"'"${WORKER_IP}"'" "\
            echo boot-id: \$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); \
            echo root-dev: \$(findmnt -n -o SOURCE / 2>/dev/null); \
            systemctl is-active kubelet 2>/dev/null || echo kubelet-inactive; \
            journalctl -u kubelet --no-pager -n 3 2>/dev/null \
          " 2>/dev/null || echo "SSH failed"
      else
        echo "worker NOT reachable"
      fi
      echo "--- nodes ---"
      oc get nodes --no-headers 2>/dev/null || true
      echo "--- CSRs ---"
      oc get csr --no-headers 2>/dev/null | head -5 || true
    fi
    echo "Waiting for worker node... (iteration ${WAIT_ITER})"
    sleep 20
  done
'

kill "${CSR_APPROVER_PID}" 2>/dev/null || true
wait "${CSR_APPROVER_PID}" 2>/dev/null || true

echo "=== Worker node added successfully ==="
oc get nodes
REMOTE_SCRIPT
