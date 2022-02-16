#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function check_workers_updated() {
    INTERVAL=5
    CNT=5

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

CONFIG_DRIVE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: 20-mount-config 
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  osImageURL: ''
  config:
    ignition:
      version: 2.2.0
    systemd:
      units:
        - name: create-mountpoint-var-config.service
          enabled: true
          contents: |
            [Unit]
            Description=Create mountpoint /var/config
            Before=kubelet.service
            [Service]
            ExecStart=/bin/mkdir -p /var/config
            [Install]
            WantedBy=var-config.mount
        - name: var-config.mount
          enabled: true
          contents: |
            [Unit]
            Before=local-fs.target
            [Mount]
            Where=/var/config
            What=/dev/disk/by-label/config-2
            [Install]
            WantedBy=local-fs.target
EOF
)
echo "Created \"$CONFIG_DRIVE\" MachineConfig"

check_workers_updated

echo "MachineConfig for config-drive was successfully applied to the worker config"
