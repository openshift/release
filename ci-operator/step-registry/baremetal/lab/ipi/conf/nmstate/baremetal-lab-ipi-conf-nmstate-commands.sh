#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating manifests for br-ex configuration on masters and workers"
##### debug on
MASTER_NM_CONF="${SHARED_DIR}/manifest_nm-conf-master.yaml"
cat > "${MASTER_NM_CONF}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 11-nm-conf-master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,W2xvZ2dpbmddCmxldmVsPVRSQUNFCmRvbWFpbnM9QUxMCg==
        mode: 0644
        overwrite: true
        path: /etc/NetworkManager/conf.d/debug.conf
EOF
##### debug off
MASTER_BR_MANIFEST="${SHARED_DIR}/manifest_nmstate-br-ex-master.yaml"
WORKER_BR_MANIFEST="${SHARED_DIR}/manifest_nmstate-br-ex-worker.yaml"
MASTER_IGNORE_MANIFEST="${SHARED_DIR}/manifest_ignore-iface-master.yaml"
WORKER_IGNORE_MANIFEST="${SHARED_DIR}/manifest_ignore-iface-worker.yaml"

cat > "${MASTER_BR_MANIFEST}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 10-br-ex-master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
EOF

cat > "${WORKER_BR_MANIFEST}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 10-br-ex-worker
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
EOF

cat > "${MASTER_IGNORE_MANIFEST}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 10-ignore-iface-master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
EOF

cat > "${WORKER_IGNORE_MANIFEST}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 10-ignore-iface-worker
spec:
  config:
    ignition:
      version: 3.4.0
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
  br_ex_contents_source="$(echo "${br_ex_configuration}" | base64 -w0)"

  ignore_iface_configuration="
  [device-${baremetal_iface}]
  match-device=interface-name:${baremetal_iface}
  keep-configuration=no"
  ignore_iface_configuration="$(echo "${ignore_iface_configuration}" | base64 -w0)"

  if [[ "$name" =~ master* ]]; then
    cat >> "${MASTER_BR_MANIFEST}" <<EOF
      - contents:
          source: data:text/plain;charset=utf-8;base64,${br_ex_contents_source}
        mode: 0644
        overwrite: true
        path: /etc/nmstate/openshift/${name}.yml
EOF
    cat >> "${MASTER_IGNORE_MANIFEST}" <<EOF
      - contents:
          source: data:text/plain;charset=utf-8;base64,${ignore_iface_configuration}
        mode: 0644
        overwrite: true
        path: /etc/NetworkManager/conf.d/10-ignore-${baremetal_iface}.conf
EOF
  fi

  if [[ "$name" =~ worker* ]]; then
    cat >> "${WORKER_BR_MANIFEST}" <<EOF
      - contents:
          source: data:text/plain;charset=utf-8;base64,${br_ex_contents_source}
        mode: 0644
        overwrite: true
        path: /etc/nmstate/openshift/${name}.yml
EOF
    cat >> "${WORKER_IGNORE_MANIFEST}" <<EOF
      - contents:
          source: data:text/plain;charset=utf-8;base64,${ignore_iface_configuration}
        mode: 0644
        overwrite: true
        path: /etc/NetworkManager/conf.d/10-ignore-${baremetal_iface}.conf
EOF
  fi
done

echo "manifests for br-ex configuration on masters"
cat "${MASTER_BR_MANIFEST}"
echo "manifests for br-ex configuration on workers"
cat "${WORKER_BR_MANIFEST}"
echo "manifests for ignore iface on masters"
cat "${MASTER_IGNORE_MANIFEST}"
echo "manifests for ignore iface on workers"
cat "${WORKER_IGNORE_MANIFEST}"
