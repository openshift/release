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

function generate_network_config {

  baremetal_iface=$1 ; shift
  [ $# -gt 0 ] && ipi_disabled_ifaces=$1 && shift

  network_config="interfaces:
              - name: ${baremetal_iface}
                type: ethernet
                state: up
                ipv4:
                  enabled: true
                  dhcp: true
                ipv6:
                  enabled: true
                  dhcp: true"

  # # split the ipi_disabled_ifaces semi-comma separated list into an array
  # IFS=';' read -r -a disabled_ifaces <<< "${ipi_disabled_ifaces}"
  # for iface in "${disabled_ifaces[@]}"; do
  #   # Take care of the indentation when adding the disabled interfaces to the above yaml
  #   network_config+="
  #             - name: ${iface}
  #               type: ethernet
  #               state: up
  #               ipv4:
  #                 enabled: false
  #                 dhcp: false
  #               ipv6:
  #                 enabled: false
  #                 dhcp: false"
  #   done
}

function generate_site_config {

  echo "************ telcov10n Generate SiteConfig file from template ************"

  site_config_file=$(mktemp --dry-run)

  # From ${SHARED_DIR}/hosts.yaml file are retrived the following values:
  #   - name
  #   - redfish_scheme
  #   - bmc_address
  #   - redfish_base_uri
  #   - mac
  #   - root_device
  #   - deviceName
  #   - root_device
  #   - root_dev_hctl
  #   - hctl
  #   - baremetal_iface
  #   - ipi_disabled_ifaces

  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')

    if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ] || [ ${#ipv6} -eq 0 ]; then
      echo "[ERROR] Unable to parse the Bare Metal Host metadata"
      exit 1
    fi

    SPOKE_CLUSTER_NAME=${NAMESPACE}
    SPOKE_BASE_DOMAIN=$(cat ${SHARED_DIR}/base_domain)

    generate_network_config ${baremetal_iface} ${ipi_disabled_ifaces}

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
  clusterImageSetNameRef: "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)"
  sshPublicKey: "$(cat ${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE}.pub)"
  clusters:
  - clusterName: "${SPOKE_CLUSTER_NAME}"
    networkType: "OVNKubernetes"
    # installConfigOverrides: '$(echo ${B64_INSTALL_CONFIG_OVERRIDES} | base64 -d)'
    extraManifestPath: sno-extra-manifest/
    clusterType: sno
    clusterProfile: du
    clusterLabels:
      du-profile: "${DU_PROFILE}"
      group-du-sno: ""
      common: true
      sites: "${SPOKE_CLUSTER_NAME}"
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
        # disableCertificateVerification: true
        bmcCredentialsName:
          name: "${SPOKE_CLUSTER_NAME}-bmc-secret"
        bootMACAddress: "${mac}"
        bootMode: "UEFI"
        rootDeviceHints:
          ${root_device:+deviceName: ${root_device}}
          ${root_dev_hctl:+hctl: ${root_dev_hctl}}
        # cpuset: "0-1,20-21"    # OCPBUGS-13301 - may require ACM 2.9
        # ignitionConfigOverride: '$(echo ${B64_NODE_IGNITION_CONF_OVERRIDE} | base64 -d)'
        nodeNetwork:
          interfaces:
            - name: "${baremetal_iface}"
              macAddress: "${mac}"
          config:
            ${network_config}
EOF

  cat $site_config_file

  done
}

function push_site_config {

  echo "************ telcov10n Pushing SiteConfig file ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea-ssh-uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE}

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

  gitea_project="${GITEA_NAMESPACE}"
  run_script_in_the_hub_cluster ${run_script} ${gitea_project}
}

function get_openshift_baremetal_install_tool {

  echo "************ telcov10n Extract RHCOS images: Getting openshift-baremetal-install tool ************"

  set -x
  pull_secret=${SHARED_DIR}/pull-secret
  oc adm release extract -a ${pull_secret} --command=openshift-baremetal-install ${RELEASE_IMAGE_LATEST}
  attempts=0
  while sleep 5s ; do
    ./openshift-baremetal-install version && break
    [ $(( attempts=${attempts} + 1 )) -lt 2 ] || exit 1
  done

  echo -n "$(./openshift-baremetal-install version | head -1 | awk '{print $2}')" > ${SHARED_DIR}/cluster-image-set-ref.txt
  set +x
}

function extract_rhcos_images {

  echo "************ telcov10n Extract RHCOS images ************"
  get_openshift_baremetal_install_tool

  openshift_release=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.release')
  rootfs_url=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')
  iso_url=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location')

}

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

  agent_serv_conf=$(oc get AgentServiceConfig agent 2>/dev/null || echo)

  if [ -z "${agent_serv_conf}" ]; then

    echo "AgentServiceConfig 'agent' not found. Deploying it..." ;

    cat << EOF | oc create -f -
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
    openshiftVersion: "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)"
    rootFSUrl: ${rootfs_url}
    url: ${iso_url}
    version: ${openshift_release}
EOF
  else
    echo "AgentServiceConfig 'agent' already exists. Patching it..." ;

    oc patch AgentServiceConfig/agent --type=merge --patch-file=/dev/stdin <<-EOF
spec:
  osImages:
  - cpuArchitecture: x86_64
    openshiftVersion: "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)"
    rootFSUrl: ${rootfs_url}
    url: ${iso_url}
    version: ${openshift_release}
EOF
  fi

  set -x
  oc get AgentServiceConfig agent -oyaml
  set +x

  echo "Wait until Multicluster Engine PODs are avaliable..."
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
  generate_site_config
  push_site_config
}

main
