#!/bin/bash


set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ----------------------------------------------------------------------
# C2S apply metadata patch
# https://bugzilla.redhat.com/show_bug.cgi?id=1923956#c3
# https://github.com/yunjiang29/c2s-instance-metadata
# ----------------------------------------------------------------------


if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi

registry_host=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
instance_metadata_repo=${registry_host}/yunjiang/c2s-instance-metadata

REGION=${LEASED_RESOURCE}

function create_mco_config_for_c2s_instance_metadata() {
    local to_file=$1
    local master_or_worker=$2
    cat <<EOF > ${to_file}
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${master_or_worker}
  name: c2s-instance-metadata-${master_or_worker}
spec:
  config:
    ignition:
      version: 3.1.0
    systemd:
      units:
      - name: c2s-instance-metadata-setup.service
        enabled: true
        contents: |
          [Unit]
          Description=Setup for C2S Instance Metadata Emulator
          [Service]
          Type=oneshot
          RemainAfterExit=true
          ExecStart=/usr/bin/sh -c 'if ! id metadata &>/dev/null; then useradd -p "*" -U -m metadata -G sudo; fi; mkdir /var/home/metadata/.docker ; cp /var/lib/kubelet/config.json /var/home/metadata/.docker/ ; chown -R metadata:metadata /var/home/metadata/.docker'
          ExecStart=iptables -t nat -I OUTPUT -p tcp -m owner ! --uid-owner metadata --dst 169.254.169.254 --dport 80 -j REDIRECT --to-ports 4000
          [Install]
          WantedBy=multi-user.target
      - name: c2s-instance-metadata.service
        enabled: true
        contents: |
          [Unit]
          Description=C2S Instance Metadata Emulator
          Wants=c2s-instance-metadata-setup.service
          After=c2s-instance-metadata-setup.service
          [Service]
          User=metadata
          ExecStart=podman run --userns keep-id  --net host ${instance_metadata_repo} --emulatedRegion ${REGION}
          Restart=always
          [Install]
          WantedBy=multi-user.target
EOF
}

create_mco_config_for_c2s_instance_metadata "${SHARED_DIR}/manifest_instance_metadata_master.yaml" master
create_mco_config_for_c2s_instance_metadata "${SHARED_DIR}/manifest_instance_metadata_worker.yaml" worker
