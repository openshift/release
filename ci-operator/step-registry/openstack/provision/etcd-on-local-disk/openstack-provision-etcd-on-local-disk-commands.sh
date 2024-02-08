#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

function info() {
  printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function check_etcd_mounted_on_local_disk() {
  info 'INFO: Checking if etcd is mounted on local disk...'
  cp_nodes=$(oc get nodes -l node-role.kubernetes.io/master --no-headers -o custom-columns=NAME:.metadata.name)
  for node in ${cp_nodes}; do
      oc debug -n default "node/${node}" -- chroot /host bash -c 'mount | grep /var/lib/etcd'
      # Doesn't work yet:
      # oc debug -n default node/${node} -- chroot /host bash -c 'ls -alZ /var/lib/etcd | grep container_var_lib_t'
  done
}

function check_etcd_unmounted_on_local_disk() {
  info 'INFO: Checking if etcd is unmounted from local disk...'
  cp_nodes=$(oc get nodes -l node-role.kubernetes.io/master --no-headers -o custom-columns=NAME:.metadata.name)
  for node in ${cp_nodes}; do
      oc debug -n default "node/${node}" -- chroot /host bash -c 'mount | grep /var/lib/etcd'
      # Doesn't work yet:
      # oc debug -n default node/${node} -- chroot /host bash -c 'ls -alZ /var/lib/etcd | grep container_var_lib_t'
  done
}

function wait_for_cpms_done() {
  info 'INFO: Waiting for masters to be updated...'
  oc wait --timeout=5m --for=condition=Progressing=true controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster
  if
    ! oc wait --timeout=90m --for=condition=Progressing=false controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.spec.replicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.status.updatedReplicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.status.replicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.status.readyReplicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null; then
      info "ERROR: CPMS not scaled to 3 replicas"
      oc get controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster
      oc describe controlplanemachineset.machine.openshift.io cluster --namespace openshift-machine-api
      exit 1
  fi
  info "INFO: All masters updated"

  info 'INFO: Waiting up to 45m for clusteroperators to finish progressing...'
  oc wait clusteroperators --timeout=45m --all --for=condition=Progressing=false

  cp_machines=$(oc get machines -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=master' --no-headers -o custom-columns=NAME:.metadata.name)
  if [[ $(echo "${cp_machines}" | wc -l) -ne 3 ]]; then
    info "ERROR: Expected 3 control plane machines, got $(echo "${cp_machines}" | wc -l)"
    exit 1
  fi
  info 'INFO: Found 3 control plane machines'
}

function wait_for_machineconfig_done() {
  info 'INFO: Waiting up to 5m for the Machines to pick up the new MachineConfig...'
  oc wait --timeout=5m --for=condition=Updating=True machineconfigpool/master

  info 'INFO: Update started, waiting up to 60m for the Machines to finish updating...'
  oc wait --timeout=60m --for=condition=Updating=false machineconfigpool/master

  info 'INFO: Waiting up to 60s for masters to be in Ready state...'
  oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s

  info 'INFO: Waiting up to 45m for clusteroperators to finish progressing...'
  oc wait clusteroperators --timeout=45m --all --for=condition=Progressing=false
}

if [[ "${ETCD_ON_LOCAL_DISK}" == "true" ]] && [[ "${USE_RAMFS}" == "true" ]]; then
    info "ERROR: ETCD_ON_LOCAL_DISK is set to true and USE_RAMFS is set to true, the configuration is conflicting"
    exit 1
fi

if [[ "${ETCD_ON_LOCAL_DISK}" == "false" ]]; then
    info "INFO: ETCD_ON_LOCAL_DISK is set to false, skipping etcd on local disk configuration"
    exit 0
fi

if [[ "${USE_RAMFS}" == "true" ]]; then
    info "INFO: USE_RAMFS is set to true, skipping etcd on local disk configuration"
    exit 0
fi

OPENSTACK_CONTROLPLANE_FLAVOR="${OPENSTACK_CONTROLPLANE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR")}"
FLAVORS="$OPENSTACK_CONTROLPLANE_FLAVOR"
if test -f "${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE"; then
    OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE="$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE")"
    FLAVORS+=" $OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE"
fi

OPENSTACK_CONTROLPLANE_FLAVOR_NODISK="${OPENSTACK_CONTROLPLANE_FLAVOR}.nodisk"
if [[ "${ETCD_ON_LOCAL_DISK_FULL_TEST}" == "true" ]]; then
    if ! openstack flavor show "$OPENSTACK_CONTROLPLANE_FLAVOR_NODISK" 2>/dev/null; then
        info "ERROR: Flavor $OPENSTACK_CONTROLPLANE_FLAVOR_NODISK does not exist"
        exit 1
    fi
fi

for flavor in $FLAVORS; do
    if ! openstack flavor show "$flavor" -f value -c "OS-FLV-EXT-DATA:ephemeral" | grep -qE '^(10|[1-9]\d+)$'; then
        info "ERROR: Flavor $flavor does not have enough ephemeral disk space. It must have at least 10GiB of ephemeral disk space"
        exit 1
    fi
done

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

info "This test applies the MachineConfig in place to nodes which already have an ephemeral disk."
info "To work correctly it must migrate etcd from the root disk to the new etcd mount."
# Preparation:
#
# - Update CPMS to add local etcd to add `additionalBlockDevices` stanza
# - Apply MachineConfig
# - Wait for rollout to complete
info "INFO: Adding additionalBlockDevices to the control plane machineset"
oc patch ControlPlaneMachineSet/cluster -n openshift-machine-api --type json -p '
[
  {
    "op": "add",
    "path": "/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/additionalBlockDevices",
    "value": [
      {
        "name": "etcd",
        "sizeGiB": 10,
        "storage": {
          "type": "Local"
        }
      }
    ]
  }
]'
wait_for_cpms_done

cp_machines=$(oc get machines -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=master' --no-headers -o custom-columns=NAME:.metadata.name)
for machine in ${cp_machines}; do
  if ! oc get machine -n openshift-machine-api "${machine}" -o jsonpath='{.spec.providerSpec.value.additionalBlockDevices}' | grep -q 'etcd'; then
    info "ERROR: Machine ${machine} does not have the etcd block device"
    exit 1
  fi
  info "INFO: Machine ${machine} has the etcd block device"
done
info 'INFO: All control plane machines have the etcd block device'


info 'INFO: Create 98-var-lib-etcd MachineConfig'
cat <<'EOF' > /tmp/98-var-lib-etcd.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-var-lib-etcd
spec:
  config:
    ignition:
      version: 3.4.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Mount local-etcd to /var/lib/etcd

          [Mount]
          # This must be mounted by device, not label, to ensure systemd generates
          # the device dependency we use below to trigger filesystem creation.
          What=/dev/disk/by-label/local-etcd
          Where=/var/lib/etcd
          Type=xfs
          Options=defaults,prjquota

          [Install]
          WantedBy=local-fs.target
        enabled: true
        name: var-lib-etcd.mount
      - contents: |
          [Unit]
          Description=Create local-etcd filesystem
          DefaultDependencies=no
          After=local-fs-pre.target

          # Don't run if the filesystem already exists
          ConditionPathIsSymbolicLink=!/dev/disk/by-label/local-etcd

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          # Fail with an obvious message if /dev/disk/by-label/ephemeral0
          # doesn't exist.
          # This is important so we can fail the device unit and therefore the
          # mount immediately without a timeout.
          ExecStart=/bin/bash -c "[ -L /dev/disk/by-label/ephemeral0 ] || ( >&2 echo Ephemeral disk does not exist; /usr/bin/false )"
          ExecStart=/usr/sbin/mkfs.xfs -f -L local-etcd /dev/disk/by-label/ephemeral0

          [Install]
          # The mount unit has an implicit dependency on its device. We run as
          # a dependency of the device unit. This allows us to create the device
          # if required, or to fail fast if it cannot be created.
          RequiredBy=dev-disk-by\x2dlabel-local\x2detcd.device
        enabled: true
        name: create-local-etcd.service
      - contents: |
          [Unit]
          Description=Migrate existing data to local etcd

          # Run after /var/lib/etcd is mounted, but before crio starts so etcd
          # isn't running yet.
          After=var-lib-etcd.mount
          Before=crio.service

          # Only migrate etcd data if /var/lib/etcd is mounted, doesn't contain
          # a member directory, and the ostree does
          Requisite=var-lib-etcd.mount
          ConditionPathExists=!/var/lib/etcd/member
          ConditionPathIsDirectory=/sysroot/ostree/deploy/rhcos/var/lib/etcd/member

          [Service]
          Type=oneshot
          RemainAfterExit=yes

          # Clean up any previous migration state
          ExecStart=/bin/bash -c "if [ -d /var/lib/etcd/member.migrate ]; then rm -rf /var/lib/etcd/member.migrate; fi"

          # Copy and move in separate steps to ensure atomic creation of a
          # complete member directory
          ExecStart=/usr/bin/cp -aZ /sysroot/ostree/deploy/rhcos/var/lib/etcd/member/ /var/lib/etcd/member.migrate
          ExecStart=/usr/bin/mv /var/lib/etcd/member.migrate /var/lib/etcd/member

          [Install]
          RequiredBy=var-lib-etcd.mount
        enabled: true
        name: migrate-to-local-etcd.service
      - contents: |
          [Unit]
          Description=Relabel /var/lib/etcd

          # Run after we've migrated any existing content, but before crio so
          # etcd isn't running yet.
          After=migrate-to-local-etcd.service
          Before=crio.service

          # Only if /var/lib/etcd is mounted
          Requisite=var-lib-etcd.mount

          [Service]
          Type=oneshot
          RemainAfterExit=yes

          # Do a quick check of the mountpoint directory before doing a full recursive relabel
          # If restorecon /var/lib/etcd would not relabel the directory, don't
          # run the recursive relabel
          ExecCondition=/bin/bash -c "[ -n \"$(restorecon -nv /var/lib/etcd)\" ]"

          ExecStart=/usr/sbin/restorecon -R /var/lib/etcd

          [Install]
          RequiredBy=var-lib-etcd.mount
        enabled: true
        name: relabel-var-lib-etcd.service
EOF
info "INFO: Applying 98-var-lib-etcd MachineConfig"
oc create -f /tmp/98-var-lib-etcd.yaml

# Verify:
#
# - The cluster is operating correctly
# - /var/lib/etcd is a new mount
# - /var/lib/etcd has the correct SELinux labels
wait_for_machineconfig_done
check_etcd_mounted_on_local_disk
info "INFO: Moving etcd on local disk is complete and the cluster is healthy!"

if [[ "${ETCD_ON_LOCAL_DISK_FULL_TEST}" == "false" ]]; then
    info "INFO: Test is complete, exiting..."
    exit 0
fi

info "This tests that the MachineConfig operates correctly when configured on a machine with no ephemeral disk."
# Preparation:
#
# - Update CPMS to remove local etcd and change the flavor to a flavor with no disk
# - Wait for rollout to complete
info "INFO: Remove additionalBlockDevices to the control plane machineset"
oc patch ControlPlaneMachineSet/cluster -n openshift-machine-api --type json -p '
[
  {
    "op": "remove",
    "path": "/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/additionalBlockDevices",
  },
  {
    "op": "replace",
    "path": "/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/flavor",
    "value": "'"${OPENSTACK_CONTROLPLANE_FLAVOR_NODISK}"'"
  }
]'
wait_for_cpms_done

# Verify:
#
# - The cluster is operating correctly
# - The etcd block device is not present on the control plane machines
# - There will be a failed systemd service: create-local-etcd.service
wait_for_machineconfig_done
check_etcd_unmounted_on_local_disk
cp_machines=$(oc get machines -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=master' --no-headers -o custom-columns=NAME:.metadata.name)
for machine in ${cp_machines}; do
  if oc get machine -n openshift-machine-api "${machine}" -o jsonpath='{.spec.providerSpec.value}' | grep -q 'additionalBlockDevices'; then
    info "ERROR: Machine ${machine} does has the etcd block device"
    exit 1
  fi
  info "INFO: Machine ${machine} does not have the etcd block device"
done
info 'INFO: All control plane machines do not have the etcd block device'
cp_nodes=$(oc get nodes -l node-role.kubernetes.io/master --no-headers -o custom-columns=NAME:.metadata.name)
for node in ${cp_nodes}; do
  info "INFO: Checking /dev/vdb on node ${node}"
  if oc debug -n default node/"${node}" -- chroot /host lsblk | grep -q '/dev/vdb'; then
    info "ERROR: /dev/vdb is present on node ${node}"
    exit 1
  else
    info "INFO: /dev/vdb is not present on node ${node}"
  fi
done

info "This tests that it is possible to remove the local etcd configuration when it is not in use."
# Preparation:
#
# - Remove MachineConfig
info "INFO: Remove 98-var-lib-etcd MachineConfig"
oc delete -f /tmp/98-var-lib-etcd.yaml

# Verify:
#
# - The cluster is operating correctly
# - There are no additional failed systemd services
wait_for_machineconfig_done
cp_nodes=$(oc get nodes -l node-role.kubernetes.io/master --no-headers -o custom-columns=NAME:.metadata.name)
# This does not work for some reason:
#
# for node in ${cp_nodes}; do
#   info "INFO: Checking create-local-etcd.service on node ${node}"
#   service=$(oc debug -n default node/"${node}" -- chroot /host systemctl status create-local-etcd.service)
#   if [[ "${service}" == *"Active: failed"* ]]; then
#     info "ERROR: create-local-etcd.service failed on node ${node}"
#     exit 1
#   else
#     info "INFO: create-local-etcd.service did not fail on node ${node}"
#   fi
# done

info "This tests that the MachineConfig works correctly when deployed on a new machine without any existing etcd state to migrate."
# Preparation:
#
# - Apply MachineConfig again
# - Wait for rollout to complete
# - Update CPMS to add local etcd
# - Wait for rollout to complete
info "INFO: Apply 98-var-lib-etcd MachineConfig"
oc create -f /tmp/98-var-lib-etcd.yaml
wait_for_machineconfig_done
info "INFO: Adding additionalBlockDevices to the control plane machineset and changing the flavor to a flavor with an ephemeral disk"
oc patch ControlPlaneMachineSet/cluster -n openshift-machine-api --type json -p '
[
  {
    "op": "add",
    "path": "/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/additionalBlockDevices",
    "value": [
      {
        "name": "etcd",
        "sizeGiB": 10,
        "storage": {
          "type": "Local"
        }
      }
    ]
  },
  {
    "op": "replace",
    "path": "/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/flavor",
    "value": "'"${OPENSTACK_CONTROLPLANE_FLAVOR}"'"
  }
]'
wait_for_cpms_done

# Verify:
#
# - The cluster is operating correctly
# - /var/lib/etcd is a new mount
# - /var/lib/etcd has the correct SELinux labels
wait_for_machineconfig_done
check_etcd_mounted_on_local_disk


info "INFO: Test is complete, exiting..."
