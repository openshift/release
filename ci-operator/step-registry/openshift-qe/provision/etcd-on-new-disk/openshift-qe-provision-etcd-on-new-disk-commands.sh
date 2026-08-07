#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function info() {
    printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function wait_for_machineconfig_done() {
  info 'Waiting up to 5m for the master MachineConfigPool to start updating...'
  oc wait --timeout=5m --for=condition=Updating=True machineconfigpool/master

  info 'Update started, waiting up to 45m for the rollout to complete...'
  oc wait --timeout=45m --for=condition=Updating=false machineconfigpool/master

  info 'Waiting up to 60s for master nodes to be Ready...'
  oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=60s

  info 'Waiting up to 30m for clusteroperators to finish progressing...'
  oc wait clusteroperators --timeout=30m --all --for=condition=Progressing=false
}

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

info 'Waiting up to 30m for clusteroperators to stabilize before applying MachineConfig...'
oc wait clusteroperators --timeout=30m --all --for=condition=Progressing=false

cp_machines=$(oc get machines -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=master' --no-headers -o custom-columns=NAME:.metadata.name)
cp_count=$(echo "${cp_machines}" | wc -l)
info "Found ${cp_count} control plane machines"

# The create-local-etcd.service uses a discovery script instead of a fixed
# device path. On AWS NVMe instances the extra EBS volume can appear as
# /dev/nvme1n1, /dev/xvdf, etc. — finding the single blank (unformatted)
# block device is the most reliable approach.
info 'Creating 98-var-lib-etcd MachineConfig...'
oc create -f - <<'EOF'
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
          Description=Create local-etcd filesystem on the extra blank disk
          DefaultDependencies=no
          After=local-fs-pre.target
          ConditionPathIsSymbolicLink=!/dev/disk/by-label/local-etcd

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/bin/bash -c '\
            BLANK=""; \
            for dev in $(lsblk -dpno NAME | grep -v loop); do \
              if ! blkid "$dev" 2>/dev/null | grep -q .; then \
                BLANK="$dev"; break; \
              fi; \
            done; \
            if [ -z "$BLANK" ]; then \
              echo "No blank disk found" >&2; exit 1; \
            fi; \
            echo "Formatting $BLANK as local-etcd"; \
            /usr/sbin/mkfs.xfs -f -L local-etcd "$BLANK"'

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

info "etcd on new disk configuration is complete and the cluster is healthy."
