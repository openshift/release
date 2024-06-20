#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating manifests for br-ex configuration on masters and workers"

MASTER_MANIFEST="${SHARED_DIR}/manifest_nmstate-br-ex-master.yaml"
WORKER_MANIFEST="${SHARED_DIR}/manifest_nmstate-br-ex-worker.yaml"

cat > "${MASTER_MANIFEST}" <<EOF
  apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: master
    name: 10-br-ex-master
  spec:
    config:
      ignition:
        version: 3.2.0
      storage:
        files:
EOF

cat > "${WORKER_MANIFEST}" <<EOF
  apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: worker
    name: 10-br-ex-worker
  spec:
    config:
      ignition:
        version: 3.2.0
      storage:
        files:
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  br_ex_configuration="
  interfaces:
  - name: ${baremetal_iface}
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false
  - name: br-ex
    type: ovs-bridge
    state: up
    ipv4:
      enabled: false
      dhcp: false
    ipv6:
      enabled: false
      dhcp: false
    bridge:
      port:
      - name: ${baremetal_iface}
      - name: br-ex
  - name: br-ex
    type: ovs-interface
    state: up
    copy-mac-from: ${baremetal_iface}
    ipv4:
      enabled: true
      dhcp: true
    ipv6:
      enabled: false
      dhcp: false"
  contents_source="$(echo "${br_ex_configuration}" | base64)"
  if [[ "$name" =~ master* ]]; then
    cat >> "${MASTER_MANIFEST}" <<EOF
          - contents:
              source: data:text/plain;charset=utf-8;base64,${contents_source}
            mode: 0644
            overwrite: true
            path: /etc/nmstate/openshift/${name}.yml
EOF
  fi
  if [[ "$name" =~ worker* ]]; then
    cat >> "${WORKER_MANIFEST}" <<EOF
          - contents:
              source: data:text/plain;charset=utf-8;base64,${contents_source}
            mode: 0644
            overwrite: true
            path: /etc/nmstate/openshift/${name}.yml
EOF
  fi
done

echo "manifests for br-ex configuration on masters"
cat "${MASTER_MANIFEST}"
echo "manifests for br-ex configuration on workers"
cat "${WORKER_MANIFEST}"
