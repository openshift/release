#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

function info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function wait_for_cpms_done() {
  info 'INFO: Waiting for masters to be updated...'
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
}

function wait_for_machineconfig_done() {
  info 'INFO: Waiting up to 5m for the Machines to pick up the new MachineConfig...'
  oc wait --timeout=5m --for=condition=Updating=True machineconfigpool/master
  
  info 'INFO: Update started, waiting up to 45m for the Machines to finish updating...'
  oc wait --timeout=45m --for=condition=Updating=false machineconfigpool/master
  
  info 'INFO: Waiting up to 60s for masters to be in Ready state...'
  oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s
  
  info 'INFO: Waiting up to 30m for clusteroperators to finish progressing...'
  oc wait clusteroperators --timeout=30m --all --for=condition=Progressing=false
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

FLAVORS="${OPENSTACK_CONTROLPLANE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR")}"
if test -f "${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE"; then
    OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE="$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE")"
    FLAVORS+=" $OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE"
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
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

info "INFO: Adding additionalBlockDevices to the control plane machineset"
oc patch ControlPlaneMachineSet/cluster -n openshift-machine-api --type json -p '[{"op": "add", "path": "/spec/template/machines_v1beta1_machine_openshift_io/spec/providerSpec/value/additionalBlockDevices", "value": [{"name": "etcd", "sizeGiB": 10, "storage": {"type": "Local"}}]}]'

info 'INFO: Waiting up to 5 minutes for the CPMS operator to pick up the edit...'
oc wait --timeout=5m --for=condition=Progressing=true controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster

wait_for_cpms_done

info 'INFO: Waiting up to 30m for clusteroperators to finish progressing...'
oc wait clusteroperators --timeout=30m --all --for=condition=Progressing=false

cp_machines=$(oc get machines -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=master' --no-headers -o custom-columns=NAME:.metadata.name)
if [[ $(echo "${cp_machines}" | wc -l) -ne 3 ]]; then
  info "ERROR: Expected 3 control plane machines, got $(echo "${cp_machines}" | wc -l)"
  exit 1
fi
info 'INFO: Found 3 control plane machines'

for machine in ${cp_machines}; do
  if ! oc get machine -n openshift-machine-api "${machine}" -o jsonpath='{.spec.providerSpec.value.additionalBlockDevices}' | grep -q 'etcd'; then
    info "ERROR: Machine ${machine} does not have the etcd block device"
    exit 1
  fi
  info "INFO: Machine ${machine} has the etcd block device"
done
info 'INFO: All control plane machines have the etcd block device'

info 'INFO: Create 98-var-lib-etcd MachineConfig'
oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-var-lib-etcd
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Make File System on /dev/vdb
          DefaultDependencies=no
          BindsTo=dev-vdb.device
          After=dev-vdb.device var.mount
          Before=systemd-fsck@dev-vdb.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/sbin/mkfs.xfs -f /dev/vdb
          TimeoutSec=0

          [Install]
          WantedBy=var-lib-containers.mount
        enabled: true
        name: systemd-mkfs@dev-vdb.service
      - contents: |
          [Unit]
          Description=Mount /dev/vdb to /var/lib/etcd
          Before=local-fs.target
          Requires=systemd-mkfs@dev-vdb.service
          After=systemd-mkfs@dev-vdb.service var.mount

          [Mount]
          What=/dev/vdb
          Where=/var/lib/etcd
          Type=xfs
          Options=defaults,prjquota

          [Install]
          WantedBy=local-fs.target
        enabled: true
        name: var-lib-etcd.mount
      - contents: |
          [Unit]
          Description=Sync etcd data if new mount is empty
          DefaultDependencies=no
          After=var-lib-etcd.mount var.mount
          Before=crio.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecCondition=/usr/bin/test ! -d /var/lib/etcd/member
          ExecStart=/usr/sbin/setenforce 0
          ExecStart=/bin/rsync -ar /sysroot/ostree/deploy/rhcos/var/lib/etcd/ /var/lib/etcd/
          ExecStart=/usr/sbin/setenforce 1
          TimeoutSec=0

          [Install]
          WantedBy=multi-user.target graphical.target
        enabled: true
        name: sync-var-lib-etcd-to-etcd.service
      - contents: |
          [Unit]
          Description=Restore recursive SELinux security contexts
          DefaultDependencies=no
          After=var-lib-etcd.mount
          Before=crio.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/sbin/restorecon -R /var/lib/etcd/
          TimeoutSec=0

          [Install]
          WantedBy=multi-user.target graphical.target
        enabled: true
        name: restorecon-var-lib-etcd.service
EOF

wait_for_machineconfig_done

info 'INFO: Replacing the 98-var-lib-etcd MachineConfig with a modified version that removes the logic for creating and syncing the device and that prevents the nodes from rebooting...'
oc replace -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-var-lib-etcd
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Mount /dev/vdb to /var/lib/etcd
          Before=local-fs.target
          Requires=systemd-mkfs@dev-vdb.service
          After=systemd-mkfs@dev-vdb.service var.mount

          [Mount]
          What=/dev/vdb
          Where=/var/lib/etcd
          Type=xfs
          Options=defaults,prjquota

          [Install]
          WantedBy=local-fs.target
        enabled: true
        name: var-lib-etcd.mount
EOF

wait_for_machineconfig_done

info "INFO: Moving etcd on local disk is complete and the cluster is healthy, all done!"
