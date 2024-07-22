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

function generate_image_source {

  echo "************ telcov10n Generate Image Source ************"

}

function generate_baremetal_secret {

  echo "************ telcov10n Generate Baremetal Secrets ************"
}

function run_script_in_the_hub_cluster {
  local helper_img="quay.io/centos/centos:stream9"
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

function generate_site_config {

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
# TODO: Use a image that already have Git package installed
dnf install -y git

ztp_repo_dir=\$(mktemp -d --dry-run)
git config --global user.email "ztp-spoke-cluster@telcov10n.com"
git config --global user.name "ZTP Spoke Cluster Telco Verification"
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}
mkdir -pv \${ztp_repo_dir}/siteconfig/sno-extra-manifest
echo "$(cat ${site_config_file})" > \${ztp_repo_dir}/siteconfig/site_config.yaml

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
  set +x
}

function extract_rhcos_images {

  echo "************ telcov10n Extract RHCOS images ************"
  # get_openshift_baremetal_install_tool

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
  set -x
  oc patch provisioning provisioning-configuration --type merge -p '{"spec":{"watchAllNamespaces": true }}'
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
  # oc -n openshift-local-storage wait localvolume localstorage-disks --for condition=Available --timeout 10m
  assisted_service_pod_name=$(oc -n multicluster-engine get pods --no-headers -o custom-columns=":metadata.name" | grep "^assisted-service")
  oc -n multicluster-engine wait --for=condition=Ready pod/assisted-image-service-0 pod/${assisted_service_pod_name}
  oc -n multicluster-engine get sc,pv,pod,pvc
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  check_hub_cluster_is_alive
  extract_rhcos_images
  generate_agent_service_config
  generate_image_source
  generate_baremetal_secret
  generate_site_config
  push_site_config
}

main
