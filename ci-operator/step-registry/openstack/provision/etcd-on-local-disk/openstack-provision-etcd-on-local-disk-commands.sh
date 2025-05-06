#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

function info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
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

openshift_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)

# Deploying on OpenStack with rootVolume and etcd on local disk 
# is not supported on OpenShift versions lower than 4.13
if [[ $(jq -n "$openshift_version < 4.13") == "true" ]]; then
  info "This procedure is not supported on OpenShift versions lower than 4.13... Skipping."
  exit 0
fi

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

info 'INFO: Waiting up to 30m for clusteroperators to finish progressing...'
oc wait clusteroperators --timeout=30m --all --for=condition=Progressing=false

cp_machines=$(oc get machines -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=master' --no-headers -o custom-columns=NAME:.metadata.name)
if [[ $(echo "${cp_machines}" | wc -l) -ne 3 ]]; then
  info "ERROR: Expected 3 control plane machines, got $(echo "${cp_machines}" | wc -l)"
  exit 1
fi
info 'INFO: Found 3 control plane machines'

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
      version: 3.4.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Mount local-etcd to /var/lib/etcd

          [Mount]
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
          ConditionPathIsSymbolicLink=!/dev/disk/by-label/local-etcd

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/bin/bash -c "[ -L /dev/disk/by-label/ephemeral0 ] || ( >&2 echo Ephemeral disk does not exist; /usr/bin/false )"
          ExecStart=/usr/sbin/mkfs.xfs -f -L local-etcd /dev/disk/by-label/ephemeral0

          [Install]
          RequiredBy=dev-disk-by\x2dlabel-local\x2detcd.device
        enabled: true
        name: create-local-etcd.service
      - contents: |
          [Unit]
          Description=Migrate existing data to local etcd
          After=var-lib-etcd.mount
          Before=crio.service

          Requisite=var-lib-etcd.mount
          ConditionPathExists=!/var/lib/etcd/member
          ConditionPathIsDirectory=/sysroot/ostree/deploy/rhcos/var/lib/etcd/member

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          
          ExecStart=/bin/bash -c "if [ -d /var/lib/etcd/member.migrate ]; then rm -rf /var/lib/etcd/member.migrate; fi" 

          ExecStart=/usr/bin/cp -aZ /sysroot/ostree/deploy/rhcos/var/lib/etcd/member/ /var/lib/etcd/member.migrate
          ExecStart=/usr/bin/mv /var/lib/etcd/member.migrate /var/lib/etcd/member

          [Install]
          RequiredBy=var-lib-etcd.mount
        enabled: true
        name: migrate-to-local-etcd.service
      - contents: |
          [Unit]
          Description=Relabel /var/lib/etcd

          After=migrate-to-local-etcd.service
          Before=crio.service
          Requisite=var-lib-etcd.mount

          [Service]
          Type=oneshot
          RemainAfterExit=yes

          ExecCondition=/bin/bash -c "[ -n \"$(/usr/sbin/restorecon -nv /var/lib/etcd)\" ]" 

          ExecStart=/usr/sbin/restorecon -R /var/lib/etcd

          [Install]
          RequiredBy=var-lib-etcd.mount
        enabled: true
        name: relabel-var-lib-etcd.service
EOF

wait_for_machineconfig_done

info "INFO: Moving etcd on local disk is complete and the cluster is healthy, all done!"
