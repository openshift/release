#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TEMP until figure out issues in deployment when declaring release:initial in workflow
if [[ -n "${PLATFORM_EXTERNAL_OVERRIDE_RELEASE-}" ]]; then
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${PLATFORM_EXTERNAL_OVERRIDE_RELEASE}"
fi
echo "Using release image ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-external.yaml.patch

STEP_WORKDIR=${STEP_WORKDIR:-/tmp}
INSTALL_DIR=${STEP_WORKDIR}/install-dir
mkdir -vp "${INSTALL_DIR}"

# export PATH=${PATH}:/tmp

# function echo_date() {
#   echo "$(date -u --rfc-3339=seconds) - $*"
# }

# echo_date "Checking/installing yq..."
# if ! [ -x "$(command -v yq4)" ]; then
#   wget -q -O /tmp/yq4 https://github.com/mikefarah/yq/releases/download/v4.34.1/yq_linux_amd64
#   chmod u+x /tmp/yq4
# fi
# which yq4

source "${SHARED_DIR}/init-fn.sh" || true
install_yq4

# echo_date "Checking/installing butane..."
# if ! [ -x "$(command -v butane)" ]; then
#   wget -q -O /tmp/butane "https://github.com/coreos/butane/releases/download/v0.18.0/butane-x86_64-unknown-linux-gnu"
#   chmod u+x /tmp/butane
# fi
# which butane

#SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

log "Creating install-config.yaml patch"
cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  external:
    platformName: ${PROVIDER_NAME}
compute:
- name: worker
  replicas: 3
  architecture: amd64
controlPlane:
  name: master
  replicas: 3
  architecture: amd64
publish: External
#sshKey: |
#  {SSH_PUB_KEY}
EOF

log "Patching install-config.yaml"
yq4 eval-all '. as $item ireduce ({}; . *+ $item)' "${CONFIG}" "${PATCH}" | tee "${CONFIG}.new"
mv -v "${CONFIG}.new" "${CONFIG}"

# cp -vp "${CONFIG}" "${SHARED_DIR}"/install-config.yaml

# echo_date "Copying to install dir"
# cp -vp "${CONFIG}" "${INSTALL_DIR}"/install-config.yaml
# grep -v "password\|username\|pullSecret\|{\"auths\":{" "${CONFIG}" | tee "${ARTIFACT_DIR}"/install-config.yaml || true

# echo_date "Creating manifests"
# openshift-install create manifests --dir "${INSTALL_DIR}"

# function create_machineconfig_kubelet() {
#     local node_role=$1
#     # shellcheck disable=SC1039
#     cat << EOF > "$STEP_WORKDIR/mc-kubelet-${node_role}.bu"
# variant: openshift
# version: 4.13.0
# metadata:
#   name: 00-$node_role-kubelet-providerid
#   labels:
#     machineconfiguration.openshift.io/role: $node_role
# storage:
#   files:
#   - mode: 0755
#     path: "/usr/local/bin/kubelet-providerid"
#     contents:
#       inline: |
#         #!/bin/bash
#         set -e -o pipefail
#         NODECONF=/etc/systemd/system/kubelet.service.d/20-providerid.conf
#         if [ -e "\${NODECONF}" ]; then
#             echo "Not replacing existing \${NODECONF}"
#             exit 0
#         fi

#         PROVIDER_ID=${PROVIDER_ID_COMMAND}

#         if [[ -z "\${PROVIDER_ID}" ]]; then
#             echo "Can not obtain provider-id from the metadata service."
#             exit 1
#         fi 

#         cat > "\${NODECONF}" <<EOF
#         [Service]
#         Environment="KUBELET_PROVIDERID=\${PROVIDER_ID}"
#         EOF
# systemd:
#   units:
#   - name: kubelet-providerid.service
#     enabled: true
#     contents: |
#       [Unit]
#       Description=Fetch kubelet provider id from Metadata
#       After=NetworkManager-wait-online.service
#       Before=kubelet.service
#       [Service]
#       ExecStart=/usr/local/bin/kubelet-providerid
#       Type=oneshot
#       [Install]
#       WantedBy=network-online.target
# EOF

# }

# function process_butane() {
#     local src_file=$1; shift
#     local dest_file=$1

#     butane "$src_file" -o "$dest_file"
# }

# if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" == "yes" ]]; then
#   echo "Creating MachineConfig for Provider ID"
#   case $PROVIDER_NAME in
#       "aws") PROVIDER_ID_COMMAND="aws:///\$(curl -fSs http://169.254.169.254/2022-09-24/meta-data/placement/availability-zone)/\$(curl -fSs http://169.254.169.254/2022-09-24/meta-data/instance-id)" ;;
#       "oci") PROVIDER_ID_COMMAND="\$(curl -H \"Authorization: Bearer Oracle\" -sL http://169.254.169.254/opc/v2/instance/ | jq -r .id)" ;;
#       *) echo "Unkonwn Provider: ${PROVIDER_NAME}"; exit 1;;
#   esac

#   create_machineconfig_kubelet "master"
#   create_machineconfig_kubelet "worker"

#   process_butane "$STEP_WORKDIR/mc-kubelet-master.bu" "${INSTALL_DIR}/openshift/99_openshift-machineconfig_00-master-kubelet-providerid.yaml"
#   process_butane "$STEP_WORKDIR/mc-kubelet-worker.bu" "${INSTALL_DIR}/openshift/99_openshift-machineconfig_00-worker-kubelet-providerid.yaml"

#   yq4 ea -i '.status.platformStatus.external.cloudControllerManager.state="External"' \
#     "${INSTALL_DIR}"/manifests/cluster-infrastructure-02-config.yml

#   cp -vf "${INSTALL_DIR}"/openshift/99_openshift-machineconfig_00-*-kubelet-providerid.yaml ${ARTIFACT_DIR}/
# fi

# cp -vf "${INSTALL_DIR}"/manifests/cluster-infrastructure-02-config.yml "${ARTIFACT_DIR}"/cluster-infrastructure-02-config.yml

# rm -vf "${INSTALL_DIR}"/openshift/99_openshift-cluster-api_master-machines-*.yaml
# rm -vf "${INSTALL_DIR}"/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
# rm -vf "${INSTALL_DIR}"/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml

# echo_date "Creating ignition configs"
# openshift-install --dir="${INSTALL_DIR}" create ignition-configs &
# wait "$!"

# cp -vf "${INSTALL_DIR}"/*.ign "${SHARED_DIR}"/
# cp -vf "${INSTALL_DIR}"/auth/* "${SHARED_DIR}"/
# cp -rvf "${INSTALL_DIR}"/auth "${SHARED_DIR}"/
# cp -vf "${INSTALL_DIR}"/metadata.json "${SHARED_DIR}"/
