#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n cluster setup via agent command ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

}

function check_hub_cluster_is_alive {

  echo "************ telcov10n Checking if the Hub cluster is available ************"

  echo
  set -x
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s --  \
  "${EXPIRATION_TIME_FILE}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

set +x
shared_exp_time_ns_file_sym_link=${1}
test -f ${shared_exp_time_ns_file_sym_link} || exit 1
EOF

  set +x
  echo
}

function get_cluster_profile_artifacts {

  echo "************ telcov10n Get Hub cluster artifacts that were stored during Hub deployments ************"

  # hub_to_spoke_artifacts=(
  #   "${KUBECONFIG}"
  #   "${KUBEADMIN_PASSWORD_FILE}"
  #   "${CLUSTER_PROFILE_DIR}"
  # )

  hub_cluster_profile=hub-cluster-profile-artifacts

  echo
  set -x
  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "root@${AUX_HOST}":${SHARED_HUB_CLUSTER_PROFILE} \
    ${hub_cluster_profile}
  set +x
  echo
}

function generate_image_source {

  echo "************ telcov10n Generate Image Source ************"

}

function generate_baremetal_secret {

  echo "************ telcov10n Generate Baremetal Secrets ************"
}

function generate_site_config {

  echo "************ telcov10n Generate SiteConfig file from template ************"

  site_config_file=site_config.yaml

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

  cat ${site_config_file}
}

function push_site_config {

  echo "************ telcov10n Pushing SiteConfig file ************"
}

function extract_rhcos_images {

  echo "************ telcov10n Extract RHCOS images ************"
  # OPENSTACK_IMAGE=$(${BIN_PATH}/openshift-baremetal-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.openstack.formats."qcow2.gz".disk.location' | tr -d '"')
  # OPENSTACK_IMAGE_FILE=$(basename ${OPENSTACK_IMAGE} | tr -d '"')
  # QEMU_IMAGE=$(${BIN_PATH}/openshift-baremetal-install coreos print-stream-json | jq '.architectures.x86_64.artifacts.qemu.formats."qcow2.gz".disk.location' | tr -d '"')
  # QEMU_IMAGE_FILE=$(basename ${QEMU_IMAGE} | tr -d '"')

}

function main {
  setup_aux_host_ssh_access
  check_hub_cluster_is_alive
  get_cluster_profile_artifacts
  extract_rhcos_images
  generate_image_source
  generate_baremetal_secret
  generate_site_config
  push_site_config
}

function pull_request_debug {

  echo "Using pull request ${PULL_NUMBER}... DO NOT preserve the hub cluster"

  echo "######################################################################"
  echo "# From here WIP changes"
  echo "######################################################################"
  echo " To quit, run the following command from POD shell: "
  echo " $ touch debug.done"
  echo "######################################################################"
  echo

  # set -x
  # oc get no,clusterversion,mcp,co,sc,pv
  # oc get subscriptions.operators,OperatorGroup,pvc -A
  # oc whoami --show-console
  # set +x
  echo "Current namespace is ${NAMESPACE} for Spoke deployment"

  generate_site_config

  set -x
  while sleep 1m; do
    date
    test -f debug.done && exit 0
  done

}

if [ -n "${PULL_NUMBER:-}" ]; then
  pull_request_debug
else
  main
fi
