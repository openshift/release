#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function check_workers_updated() {
    # Wait up to 2 minutes for PAO to update the worker config
    INTERVAL=5
    CNT=24

    old_config=$(oc get mcp worker --no-headers | awk '{print $2}')
    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            current_config=$(echo "${i}" | awk '{print $2}')
            degraded=$(echo "${i}" | awk '{print $5}')
            degraded_machine_cnt=$(echo "${i}" | awk '{print $9}')

            if [[ "${old_config}" != "${current_config}" && "${degraded}" == "False" && $((degraded_machine_cnt)) -eq 0 ]]; then
                READY=true
            else
                echo "Waiting for mcp ${name} to rollout"
                READY=false
            fi
        done <<< "$(oc get mcp worker --no-headers)"

        if [[ "${READY}" == "true" ]]; then
            echo "Worker config has successfully rolled out"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Worker config did not successfully roll out"
            oc get mcp "${name}"
            return 1
        fi
    done
}

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

if [[ ${OPENSTACK_DPDK_NETWORK} == "" ]]; then
    echo "OPENSTACK_DPDK_NETWORK is not set"
    exit 1
fi

NETWORK_ID=$(openstack network show "${OPENSTACK_DPDK_NETWORK}" -f value -c id)
if [[ "${NETWORK_ID}" == "" ]]; then
    echo "Failed to find network ${OPENSTACK_DPDK_NETWORK}"
    exit 1
fi

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

SCRIPT_BASE64=$(curl --retry 10 https://raw.githubusercontent.com/rh-nfv-int/shift-on-stack-vhostuser/master/roles/sos-vhostuser/files/vhostuser | base64 -w 0)
SCRIPT_ARG_BASE64=$(echo "ARG=\"${NETWORK_ID}\"" | base64 -w 0)
VHOSTUSER_MC=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-vhostuser-bind
spec:
  config:
    ignition:
      version: 2.2.0
    systemd:
      units:
      - name: vhostuser-bind.service
        enabled: true
        contents: |
          [Unit]
          Description=Vhostuser Interface vfio-pci Bind
          Wants=network-online.target
          After=network-online.target ignition-firstboot-complete.service

          [Service]
          Type=oneshot
          EnvironmentFile=/etc/vhostuser-bind.conf
          ExecStart=/usr/local/bin/vhostuser \$ARG

          [Install]
          WantedBy=multi-user.target
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,dmZpby1wY2k=
        filesystem: root
        mode: 0644
        path: /etc/modules-load.d/vfio-pci.conf
      - contents:
          source: data:text/plain;charset=utf-8;base64,${SCRIPT_BASE64}
        filesystem: root
        mode: 0744
        path: //usr/local/bin/vhostuser
      - contents:
          source: data:text/plain;charset=utf-8;base64,${SCRIPT_ARG_BASE64}
        filesystem: root
        mode: 0644
        path: /etc/vhostuser-bind.conf
EOF
)
echo "Created \"$VHOSTUSER_MC\" MachineConfig"

check_workers_updated

echo "MachineConfig for vhostuser was successfully applied to the worker config"
