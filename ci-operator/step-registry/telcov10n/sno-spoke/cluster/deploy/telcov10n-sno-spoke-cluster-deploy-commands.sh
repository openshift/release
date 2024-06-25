#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"
  oc_hub="oc --kubeconfig ${SHARED_DIR}/hub-kubeconfig"
}

function check_hub_cluster_is_alive {

  echo "************ telcov10n Checking if the Hub cluster is available ************"

  echo
  set -x
  $oc_hub get node,clusterversion
  set +x
  echo
}

function generate_image_source {

  echo "************ telcov10n Generate Image Source ************"

}

function generate_baremetal_secret {

  echo "************ telcov10n Generate Baremetal Secrets ************"
}

function clone_gitea_repo {

  echo "************ telcov10n clone Gitea repo ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea_ssh_uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-ztp-gitea

  root_ztp_repo_dir=$(mktemp -d)
  set -x
  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git clone ${gitea_ssh_uri} ${root_ztp_repo_dir}
  set +x
}

function generate_site_config {

  echo "************ telcov10n Generate SiteConfig file from template ************"

  clone_gitea_repo

  mkdir -pv ${root_ztp_repo_dir}/siteconfig/sno-extra-manifest
  site_config_file=${root_ztp_repo_dir}/siteconfig/site_config.yaml

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
    installConfigOverrides: "${INSTALL_CONFIG_OVERRIDES}"
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
    ignitionConfigOverride: "\'${GLOBAL_IGNITION_CONF_OVERRIDE}\'"
    cpuPartitioningMode: AllNodes
    nodes:
      - hostName: "sno.${SPOKE_CLUSTER_NAME}.${SPOKE_BASE_DOMAIN}"
        bmcAddress: "idrac-VirtualMedia://10.1.29.44/redfish/v1/Systems/System.Embedded.1"
        bmcCredentialsName:
          name: "${SPOKE_CLUSTER_NAME}-bmc-secret"
        bootMACAddress: "${BOOT_MAC}"
        bootMode: "UEFI"
        # cpuset: "0-1,20-21"    # OCPBUGS-13301 - may require ACM 2.9
        ignitionConfigOverride: "\'${NODE_IGNITION_CONF_OVERRIDE}\'"
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
                  address:
                    - ip: 10.1.153.100
                      prefix-length: 24
                  dhcp: false
                ipv6:
                  enabled: false

            dns-resolver:
              config:
                server:
                  - 10.46.0.32
            routes:
              config:
                - destination: 0.0.0.0/0
                  next-hop-address: 10.1.153.254
                  next-hop-interface: "${NODE_NIC}"
                  table-id: 254
EOF

  pushd .
  cd ${root_ztp_repo_dir}
  set -x
  git commit -a -m 'Generated SiteConfig file'
  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git push origin main
  cat ${site_config_file}
  set +x
  popd
}

function push_site_config {

  echo "************ telcov10n Pushing SiteConfig file ************"
}

function get_openshift_baremetal_install_tool {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"

  pull_secret=${SHARED_DIR}/pull-secret
  oc adm release extract \
    -a ${pull_secret} \
    --command=openshift-baremetal-install \
    quay.io/openshift-release-dev/ocp-release:4.15.22-x86_64
    # "${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}"
}

function extract_rhcos_images {

  echo "************ telcov10n Extract RHCOS images ************"
  # OPENSTACK_IMAGE=$(${BIN_PATH}/openshift-baremetal-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.openstack.formats."qcow2.gz".disk.location' | tr -d '"')
  # OPENSTACK_IMAGE_FILE=$(basename ${OPENSTACK_IMAGE} | tr -d '"')
  # QEMU_IMAGE=$(${BIN_PATH}/openshift-baremetal-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.qemu.formats."qcow2.gz".disk.location' | tr -d '"')
  # QEMU_IMAGE_FILE=$(basename ${QEMU_IMAGE} | tr -d '"')
  get_openshift_baremetal_install_tool

  ./openshift-baremetal-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.metal'

}

function main {
  set_hub_cluster_kubeconfig
  check_hub_cluster_is_alive
  extract_rhcos_images
  generate_image_source
  generate_baremetal_secret
  generate_site_config
  push_site_config
}

main
