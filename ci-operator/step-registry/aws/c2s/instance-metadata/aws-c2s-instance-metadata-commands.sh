#!/bin/bash


set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

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


# ----------------------------------------------------------------------
# C2S: workaround for C2S emulator
# https://bugzilla.redhat.com/show_bug.cgi?id=1911257#c6
# update Feb. 10
# per https://bugzilla.redhat.com/show_bug.cgi?id=1923956#c3
#   this is a fix for metadata issue on C2S emulator
# per https://bugzilla.redhat.com/show_bug.cgi?id=1926975
#   a non-empty cloud config is required for 4.9 and below
# ----------------------------------------------------------------------

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

ca_file=`mktemp`
cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" > ${ca_file}
if [[ "${SELF_MANAGED_ADDITIONAL_CA}" == "true" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt" >> ${ca_file}
else
    cat "/var/run/vault/mirror-registry/client_ca.crt" >> ${ca_file}
fi

if (( ocp_minor_version <= 9 && ocp_major_version == 4 )); then
  echo "C2S: workaround for C2S emulator (BZ#1926975)"
  cat << EOF > ${SHARED_DIR}/manifest_c2s_emulator_patch_cloud-provider-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloud-provider-config
  namespace: openshift-config
data:
  ca-bundle.pem: |
`cat ${ca_file} | sed -e 's/^/    /'`
  config: |
    [Global]
EOF
fi
