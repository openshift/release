#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function check_hub_cluster_is_alive {

  echo "************ telcov10n Checking if the Hub cluster is available ************"

  echo
  set -x
  oc get node,clusterversion
  set +x
  echo
}

function run_script_in_the_hub_cluster {
  local helper_img="${GITEA_HELPER_IMG}"
  local script_file=$1
  shift && local ns=$1
  [ $# -gt 1 ] && shift && local pod_name="${1}"

  set -x
  if [[ "${pod_name:="--rm hub-script"}" != "--rm hub-script" ]]; then
    oc -n ${ns} get pod ${pod_name} 2> /dev/null || {
      oc -n ${ns} run ${pod_name} \
        --image=${helper_img} --restart=Never -- sleep infinity ; \
      oc -n ${ns} wait --for=condition=Ready pod/${pod_name} --timeout=10m ;
    }
    oc -n ${ns} exec -i ${pod_name} -- \
      bash -s -- <<EOF
$(cat ${script_file})
EOF
  [ $# -gt 1 ] && oc -n ${ns} delete pod ${pod_name}
  else
    oc -n ${ns} run -i ${pod_name} \
      --image=${helper_img} --restart=Never -- \
        bash -s -- <<EOF
$(cat ${script_file})
EOF
  fi
  set +x
}

function generate_site_config_local {

  echo "************ telcov10n Generate SiteConfig file from template ************"

  site_config_file=$(mktemp --dry-run)

  cat << EOF > ${site_config_file}
apiVersion: ran.openshift.io/v1
kind: SiteConfig
metadata:
  name: "site-plan-${SPOKE_CLUSTER_NAME}"
  namespace: ${SPOKE_CLUSTER_NAME}
spec:
  baseDomain: "${SPOKE_BASE_DOMAIN}"
  pullSecretRef:
    name: "${SPOKE_CLUSTER_NAME}-pull-secret"
  clusterImageSetNameRef: "${CLUSTER_IMG_SET_REF}"
  sshPublicKey: "${SSH_PUB_KEY}"
  clusters:
  - clusterName: "${SPOKE_CLUSTER_NAME}"
    networkType: "OVNKubernetes"
    # installConfigOverrides: '${INSTALL_CONFIG_OVERRIDES}'
    extraManifestPath: sno-extra-manifest/
    clusterType: sno
    clusterProfile: du
    clusterLabels:
      du-profile: "${DU_PROFILE}"
      group-du-sno: ""
      common: true
      sites : "${SPOKE_CLUSTER_NAME}"
    clusterNetwork:
      - cidr: "10.128.0.0/14"
        hostPrefix: 23
    machineNetwork:
      - cidr: 10.1.153.0/24
    serviceNetwork:
      - "172.30.0.0/16"
    additionalNTPSources:
      - ${NTP_SRC}
    ignitionConfigOverride: '${GLOBAL_IGNITION_CONF_OVERRIDE}'
    cpuPartitioningMode: AllNodes
    nodes:
      - hostName: "worker-a-00.${SPOKE_CLUSTER_NAME}.${SPOKE_BASE_DOMAIN}"
        bmcAddress: "redfish-virtualmedia://192.168.70.127/redfish/v1/Systems/System.Embedded.1"
        bmcCredentialsName:
          name: "${SPOKE_CLUSTER_NAME}-bmc-secret"
        bootMACAddress: "${BOOT_MAC}"
        bootMode: "UEFI"
        rootDeviceHints:
          deviceName: /dev/sda
        # cpuset: "0-1,20-21"    # OCPBUGS-13301 - may require ACM 2.9
        ignitionConfigOverride: '${NODE_IGNITION_CONF_OVERRIDE}'
        nodeNetwork:
          interfaces:
            - name: "${NODE_NIC}"
              macAddress: "${NODE_MAC}"
          config:
            interfaces:
              - name: ${NODE_NIC}
                type: ethernet
                state: up
                ipv4:
                  enabled: true
                  dhcp: true
                ipv6:
                  enabled: true
                  dhcp: true
EOF

}

function generate_site_config {

  echo "************ telcov10n Generate SiteConfig file from template ************"

  # site_config_file=$(mktemp --dry-run)
  site_config_file=/tmp/site-config.yaml

  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/master.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')

    SPOKE_CLUSTER_NAME=${NAMESPACE}
    SPOKE_BASE_DOMAIN=$(cat ${SHARED_DIR}/bastion_public_address)

    cat << EOF > ${site_config_file}
apiVersion: ran.openshift.io/v1
kind: SiteConfig
metadata:
  name: "site-plan-${SPOKE_CLUSTER_NAME}"
  namespace: ${SPOKE_CLUSTER_NAME}
spec:
  baseDomain: "${SPOKE_BASE_DOMAIN}"
  pullSecretRef:
    name: "${SPOKE_CLUSTER_NAME}-pull-secret"
  # CLUSTER_IMG_SET_REF: img4.15.24-x86-64-appsub
  clusterImageSetNameRef: "${CLUSTER_IMG_SET_REF}"
  sshPublicKey: "$(cat ${SHARED_DIR}/ssh-key-ztp-gitea.pub)"
  clusters:
  - clusterName: "${SPOKE_CLUSTER_NAME}"
    networkType: "OVNKubernetes"
    # installConfigOverrides: '${INSTALL_CONFIG_OVERRIDES}'
    extraManifestPath: sno-extra-manifest/
    clusterType: sno
    clusterProfile: du
    clusterLabels:
      du-profile: "${DU_PROFILE}"
      group-du-sno: ""
      common: true
      sites : "${SPOKE_CLUSTER_NAME}"
    clusterNetwork:
      - cidr: "10.128.0.0/14"
        hostPrefix: 23
    machineNetwork:
      - cidr: ${INTERNAL_NET_CIDR}
    serviceNetwork:
      - "172.30.0.0/16"
    additionalNTPSources:
      - ${AUX_HOST}
    ignitionConfigOverride: '${GLOBAL_IGNITION_CONF_OVERRIDE}'
    cpuPartitioningMode: AllNodes
    nodes:
      - hostName: "${name}.${SPOKE_CLUSTER_NAME}.${SPOKE_BASE_DOMAIN}"
        bmcAddress: "${redfish_scheme}://${bmc_address}${redfish_base_uri}"
        bmcCredentialsName:
          name: "${SPOKE_CLUSTER_NAME}-bmc-secret"
        bootMACAddress: "${provisioning_mac}"
        bootMode: "UEFI"
        rootDeviceHints:
          deviceName: ${root_device}
        # cpuset: "0-1,20-21"    # OCPBUGS-13301 - may require ACM 2.9
        ignitionConfigOverride: '${NODE_IGNITION_CONF_OVERRIDE}'
        nodeNetwork:
          interfaces:
            - name: "${baremetal_iface}"
              macAddress: "${mac}"
          config:
            interfaces:
              - name: ${baremetal_iface}
                type: ethernet
                state: up
                ipv4:
                  enabled: true
                  # address:
                  # - ip: 10.1.153.100
                  #   prefix-length: 24
                  # dhcp: false
                  dhcp: true
                ipv6:
                  enabled: false
                  # enabled: true
                  # dhcp: true

            # dns-resolver:
            #   config:
            #     server:
            #       - 10.46.0.32
            # routes:
            #   config:
            #     - destination: 0.0.0.0/0
            #       next-hop-address: 10.1.153.254
            #       next-hop-interface: "${NODE_NIC}"
            #       table-id: 254
EOF

  cat $site_config_file

  done
}

function push_site_config {

  echo "************ telcov10n Pushing SiteConfig file ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea-ssh-uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-ztp-gitea

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

echo "$(cat ${ssh_pri_key_file})" > /tmp/ssh-prikey
chmod 0400 /tmp/ssh-prikey

set -x
ztp_repo_dir=\$(mktemp -d --dry-run)
git config --global user.email "ztp-spoke-cluster@telcov10n.com"
git config --global user.name "ZTP Spoke Cluster Telco Verification"
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}
mkdir -pv \${ztp_repo_dir}/site-configs/sno-extra-manifest
mkdir -pv \${ztp_repo_dir}/site-policies
echo "$(cat ${site_config_file})" > \${ztp_repo_dir}/site-configs/site-config.yaml
cat <<EOK > \${ztp_repo_dir}/site-configs/kustomization.yaml
generators:
  - site-config.yaml
EOK
touch \${ztp_repo_dir}/site-configs/sno-extra-manifest/.placeholder
touch \${ztp_repo_dir}/site-policies/.placeholder

cd \${ztp_repo_dir}
git add .
git commit -m 'Generated SiteConfig file'
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main
EOF

  gitea_project="ztp-gitea"
  run_script_in_the_hub_cluster ${run_script} ${gitea_project}
}

function get_openshift_baremetal_install_tool {

  echo "************ telcov10n Extract RHCOS images: Getting openshift-baremetal-install tool ************"

# INFO[2024-07-22T17:31:16Z] Importing release image latest.
# INFO[2024-07-22T17:31:16Z] Requesting a release from https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4.15.0-0.nightly/latest
# INFO[2024-07-22T17:31:16Z] Resolved release latest to registry.ci.openshift.org/ocp/release:4.15.0-0.nightly-2024-07-22-104333
# INFO[2024-07-22T17:31:35Z] Importing release 4.15.0-0.nightly-2024-07-22-104333 created at 2024-07-22 10:45:17 +0000 UTC with 191 images to tag release:latest ...
# INFO[2024-07-22T17:33:11Z] Imported release 4.15.0-0.nightly-2024-07-22-104333 created at 2024-07-22 10:45:17 +0000 UTC with 191 images to tag release:latest
  set -x
  pull_secret=${SHARED_DIR}/pull-secret
  oc adm release extract -a ${pull_secret} --command=openshift-baremetal-install ${RELEASE_IMAGE_LATEST}
  attempts=0
  while sleep 5s ; do
    ./openshift-baremetal-install version && break
    [ $(( attempts=${attempts} + 1 )) -lt 2 ] || exit 1
  done
  set +x
}

function extract_rhcos_images {

  echo "************ telcov10n Extract RHCOS images ************"
  get_openshift_baremetal_install_tool

  # ./openshift-baremetal-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.metal'
  openshift_release=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.release')
  rootfs_url=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')
  iso_url=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location')

}

# function create_persistent_volumes_for_assisted_installer_service {

#   echo "************ telcov10n Create PVs for the assisted install service to be deployed by AgentServiceConfig CR ************"
#   cat << EOF | oc apply -f -
# apiVersion: local.storage.openshift.io/v1
# kind: LocalVolume
# metadata:
#   name: assisted-service
#   namespace: openshift-local-storage
# spec:
#   logLevel: Normal
#   managementState: Managed
#   storageClassDevices:
#     - devicePaths:
#         - /dev/vdb
#       storageClassName: assisted-service
#       volumeMode: Filesystem
# EOF

#   set -x
#   oc wait localvolume -n openshift-local-storage assisted-service --for condition=Available --timeout 10m
#   oc get sc,pv
#   set +x
# }

function generate_agent_service_config {

  echo "************ telcov10n Generate and Deploy AgentServiceConfig CR ************"

  echo "Enabling assisted installer service on bare metal"
  cat <<EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  preProvisioningOSDownloadURLs: {}
  provisioningNetwork: Disabled
  watchAllNamespaces: true
EOF

  set -x
  oc get Provisioning provisioning-configuration -oyaml
  set +x

  sc_name=$(oc get sc -ojsonpath='{.items[0].metadata.name}')

  cat << EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
 name: agent
spec:
  databaseStorage:
    storageClassName: ${sc_name}
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
  filesystemStorage:
    storageClassName: ${sc_name}
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
  imageStorage:
    storageClassName: ${sc_name}
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 50Gi
  osImages:
  - cpuArchitecture: x86_64
    openshiftVersion: "4.15"
    rootFSUrl: ${rootfs_url}
    url: ${iso_url}
    version: ${openshift_release}
EOF

  set -x
  oc get AgentServiceConfig agent -oyaml
  set +x

  echo "Wait until Multicluster Engine PODs are avaliable..."
  # oc -n openshift-local-storage wait localvolume localstorage-disks --for condition=Available --timeout 10m
  set -x
  attempts=0 ;
  while sleep 10s ; do
    [ $(( attempts=${attempts} + 1 )) -lt 60 ] || exit 1;
    assisted_service_pod_name=$( \
      oc -n multicluster-engine get pods --no-headers -o custom-columns=":metadata.name" | \
      grep "^assisted-service" || echo)
    [ -n "${assisted_service_pod_name}" ] && \
    oc -n multicluster-engine get pod assisted-image-service-0 ${assisted_service_pod_name} && break ;
  done ;
  oc -n multicluster-engine wait --for=condition=Ready pod/assisted-image-service-0 pod/${assisted_service_pod_name} --timeout=30m
  oc -n multicluster-engine get sc,pv,pod,pvc
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  check_hub_cluster_is_alive
  extract_rhcos_images
  generate_agent_service_config
  # generate_site_config_local
  generate_site_config
  push_site_config
}

main
