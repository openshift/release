#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/spoke-common-functions.sh

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

function get_storage_class_name {

  echo "************ telcov10n Get the Storage Class name to be used ************"

  if [ -n "$(oc get pod -A | grep 'openshift-storage.*lvms-operator')" ];then
    cat <<EOF | oc create -f - 2>/dev/null || { set -x ; oc -n openshift-storage get LVMCluster lvmcluster -oyaml ; set +x ; }
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - fstype: xfs
      name: vg1
      thinPoolConfig:
        chunkSizeCalculationPolicy: Static
        name: thin-pool-1
        overprovisionRatio: 10
        sizePercent: 90
EOF
    set -x
    attempts=0
    while sleep 10s ; do
      oc -n openshift-storage wait lvmcluster/lvmcluster --for=jsonpath='{.status.state}'=Ready --timeout 10m && break
      [ $(( attempts=${attempts} + 1 )) -lt 3 ] || exit 1
    done
    set +x
    oc -n openshift-storage get lvmcluster/lvmcluster -oyaml

    sc_name=$(oc get sc -ojsonpath='{range .items[]}{.metadata.name}{"\n"}{end}'| grep '^lvms-' | head -1 || echo "lvms-vg1")
  else
    sc_name=$(oc get sc -ojsonpath='{.items[0].metadata.name}')
  fi

  oc get sc
  echo
  echo "Using ${sc_name} Storage Class name"
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

    if [ "${root_device}" != "" ]; then
      ignition_config_override='{\"ignition\":{\"version\":\"3.2.0\"},\"storage\":{\"disks\":[{\"device\":\"'${root_device}'\",\"wipeTable\":true, \"partitions\": []}]}}'
    fi

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
    # See: oc get clusterversion version -o json | jq -rc .status.capabilities
    # installConfigOverrides: '$(jq --compact-output '.[]' <<< "${INSTALL_CONFIG_OVERRIDES}")'
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
    # ignitionConfigOverride: '${GLOBAL_IGNITION_CONF_OVERRIDE}'
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
        # ${ignition_config_override:+ignitionConfigOverride: "'${ignition_config_override}'"}
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
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}
mkdir -pv \${ztp_repo_dir}/site-configs/${SPOKE_CLUSTER_NAME}/sno-extra-manifest
mkdir -pv \${ztp_repo_dir}/site-policies
cat <<EOS > \${ztp_repo_dir}/site-configs/${SPOKE_CLUSTER_NAME}/site-config.yaml
$(cat ${site_config_file})
EOS
cat <<EOK > \${ztp_repo_dir}/site-configs/${SPOKE_CLUSTER_NAME}/kustomization.yaml
generators:
  - site-config.yaml
EOK

ts="$(date -u +%s%N)"
echo "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)" >| \${ztp_repo_dir}/site-configs/${SPOKE_CLUSTER_NAME}/sno-extra-manifest/.cluster-image-set-used.\${ts}
echo "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)" >| \${ztp_repo_dir}/site-policies/.cluster-image-set-used.\${ts}

if [ -f \${ztp_repo_dir}/site-configs/kustomization.yaml ]; then
  if [ "\$(grep "${SPOKE_CLUSTER_NAME}" \${ztp_repo_dir}/site-configs/kustomization.yaml)" == "" ]; then
    sed -i '/^resources:$/a\  - ${SPOKE_CLUSTER_NAME}' \${ztp_repo_dir}/site-configs/kustomization.yaml
  fi
else
  cat <<EOK > \${ztp_repo_dir}/site-configs/kustomization.yaml
resources:
  - ${SPOKE_CLUSTER_NAME}
EOK
fi

cd \${ztp_repo_dir}
git add .
git commit -m 'Generated SiteConfig file by ${SPOKE_CLUSTER_NAME}'
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main || {
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git pull -r origin main &&
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main ; }
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

function upload_iso_url_to_http_hub_pod {

  echo "************ ISO image cache ************"

  src_iso_url="${1}"
  http_listen_port="8080"
  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

iso_path=/tmp/live-iso/$(basename ${src_iso_url})

set -x
if [ -d \$(dirname \${iso_path}) ]; then
  echo "Waiting for the server to start up..."
  for ((attempts = 0 ; attempts < 10 ; attempts++)); do
    response=\$(curl -sSkL -w "%{http_code}" -o /dev/null http://localhost:${http_listen_port}/$(basename ${src_iso_url}) || echo)
    [[ \${response} -eq 200 ]] && exit 0
    sleep 30s
  done
  exit 1
fi

mkdir -pv \$(dirname \${iso_path})
curl -sSkL -o \${iso_path} ${src_iso_url}

cat <<EOP > /tmp/server.py
from http.server import SimpleHTTPRequestHandler, HTTPServer
import os

FILE_PATH = "\${iso_path}"
HOST = "0.0.0.0"
PORT = ${http_listen_port}

class CustomHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/$(basename ${src_iso_url})":
            if os.path.exists(FILE_PATH):
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f"attachment; filename={os.path.basename(FILE_PATH)}")
                self.send_header("Content-Length", str(os.path.getsize(FILE_PATH)))
                self.end_headers()

                with open(FILE_PATH, "rb") as file:
                    self.wfile.write(file.read())
            else:
                self.send_error(404, "File Not Found")
        else:
            self.send_error(404, "Not Found")

if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), CustomHandler)
    print(f"Serving {FILE_PATH} on http://{HOST}:{PORT}/$(basename ${src_iso_url})")
    server.serve_forever()
EOP

  cat << EOP >| /tmp/run.py
import subprocess

process = subprocess.Popen(["python3", "/tmp/server.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f"Server started in the background with PID {process.pid}")
EOP

  exec python3 /tmp/run.py
EOF

  gitea_project="${GITEA_NAMESPACE}"
  pod_name="$(basename ${src_iso_url} | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  run_script_in_the_hub_cluster ${run_script} ${gitea_project} ${pod_name}

  pod_ip=$(oc -n ${gitea_project} get po ${pod_name} -ojsonpath='{.status.podIP}')
  iso_url="http://${pod_ip}:${http_listen_port}/$(basename ${src_iso_url})"
  echo
  echo "The ISO is served on '${iso_url}' inside the Hub cluster"
  echo
}

function extract_rhcos_images {

  echo "************ telcov10n Extract RHCOS images ************"
  get_openshift_baremetal_install_tool

  openshift_release=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.release')
  if [ -z "${RHCOS_ISO_URL:-}" ]; then
    iso_url=$(./openshift-baremetal-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location')
  else
    iso_url=""
    upload_iso_url_to_http_hub_pod "${RHCOS_ISO_URL}"
  fi
}

function wait_until_assisted_service_is_ready {

  echo "Wait until Multicluster Engine PODs are avaliable..."

  set -x
  attempts=0 ;
  while sleep 10s ; do
    [ $(( attempts=${attempts} + 1 )) -lt 60 ] || {
      oc -n multicluster-engine get sc,pv,deploy,pod,pvc ;
      exit 1 ;
    }
    assisted_service_pod_name=$( \
      oc -n multicluster-engine get pods -l app=assisted-service | \
      grep "^assisted-service.*Running" | \
      awk '{print $1}' || echo)
    [ -n "${assisted_service_pod_name}" ] && \
      oc -n multicluster-engine get pod assisted-image-service-0 ${assisted_service_pod_name} --ignore-not-found && \
      break
  done ;
  {
    oc -n multicluster-engine wait --for=condition=Ready pod/assisted-image-service-0 --timeout=30m &&
    oc -n multicluster-engine wait --for=condition=Available deployment/assisted-service --timeout=30m ;
  } || {
    oc -n multicluster-engine get sc,pv,deploy,pod,pvc ;
    oc -n multicluster-engine logs assisted-image-service-0 assisted-image-service | grep "${iso_url}" ;
    exit 1 ;
  }
  set +x
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

  get_storage_class_name

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
    url: ${iso_url}
    version: ${openshift_release}
EOF
  else

    set -x
    openshift_version="$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)"
    if [ "$(oc get AgentServiceConfig/agent -oyaml|grep "${openshift_version}")" == "" ] ; then
      echo "AgentServiceConfig 'agent' already exists. Patching it..." ;

      oc get AgentServiceConfig/agent -ojsonpath='{.spec.osImages}' >| /tmp/AgentServiceConfig-agent.spec.osImages.json

      yq -o json >| /tmp/AgentServiceConfig-agent.spec.osImages.patch.json <<-EOF
- cpuArchitecture: x86_64
  openshiftVersion: "${openshift_version}"
  url: ${iso_url}
  version: ${openshift_release}
EOF
      oc patch AgentServiceConfig/agent --type=merge --patch-file=/dev/stdin <<-EOF
$(jq -s '.[0] + .[1]' /tmp/AgentServiceConfig-agent.spec.osImages.json /tmp/AgentServiceConfig-agent.spec.osImages.patch.json | yq -o=yaml -I=2 -P '. | {"spec": {"osImages": .}}')
EOF
    else
      echo
      echo "'${openshift_version}' openshiftVersion already exists. Do nothing..."
      echo
    fi
  fi

  set -x
  oc get AgentServiceConfig agent -oyaml
  set +x

  wait_until_assisted_service_is_ready

  set -x
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
