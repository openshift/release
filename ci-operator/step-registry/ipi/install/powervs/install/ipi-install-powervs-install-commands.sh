#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
  case "${CLUSTER_TYPE}" in
    powervs)
      ibmcloud pi ins --json | jq -r '.Payload.pvmInstances[] | select (.serverName|test("'${CLUSTER_NAME}'")) | [.serverName, .pvmInstanceID, .addresses[].ip, .addresses[].macAddress]';;
  *) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}' to collect machine IDs"
  esac
}

function prepare_next_steps() {
  #Save exit code for must-gather to generate junit
  echo "$?" > "${SHARED_DIR}/install-status.txt"
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"

}

function log_to_file()
{
	local LOG_FILE=$1

	/bin/rm -f ${LOG_FILE}
	# Close STDOUT file descriptor
	exec 1<&-
	# Close STDERR FD
	exec 2<&-
	# Open STDOUT as $LOG_FILE file for read and write.
	exec 1<>${LOG_FILE}
	# Redirect STDERR to STDOUT
	exec 2>&1
}

function inject_promtail_service() {
  GRAFANACLOUND_USERNAME=$(cat /var/run/loki-grafanacloud-secret/client-id)
  export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"
  export PROMTAIL_IMAGE="quay.io/openshift-cr/promtail"
  export PROMTAIL_VERSION="v2.4.1"

  config_dir=/tmp/promtail
  mkdir "${config_dir}"
  cp /var/run/loki-grafanacloud-secret/client-secret "${config_dir}/grafanacom-secrets-password"
  cat >> "${config_dir}/promtail_config.yml" << EOF
clients:
  - backoff_config:
      max_period: 5m
      max_retries: 20
      min_period: 1s
    batchsize: 102400
    batchwait: 10s
    basic_auth:
      username: ${GRAFANACLOUND_USERNAME}
      password_file: /etc/promtail/grafanacom-secrets-password
    timeout: 10s
    url: https://logs-prod3.grafana.net/api/prom/push
positions:
  filename: "/run/promtail/positions.yaml"
scrape_configs:
- job_name: kubernetes-pods-static
  pipeline_stages:
  - cri: {}
  - labeldrop:
    - filename
  - pack:
      labels:
      - namespace
      - pod_name
      - container_name
      - app
  - labelallow:
      - host
      - invoker
  kubernetes_sd_configs:
  - role: pod
  relabel_configs:
  - action: drop
    regex: ''
    source_labels:
    - __meta_kubernetes_pod_uid
  - source_labels:
    - __meta_kubernetes_pod_label_name
    target_label: __service__
  - source_labels:
    - __meta_kubernetes_pod_node_name
    target_label: __host__
  - action: replace
    replacement:
    separator: "/"
    source_labels:
    - __meta_kubernetes_namespace
    - __service__
    target_label: job
  - action: replace
    source_labels:
    - __meta_kubernetes_namespace
    target_label: namespace
  - action: replace
    source_labels:
    - __meta_kubernetes_pod_name
    target_label: pod_name
  - action: replace
    source_labels:
    - __meta_kubernetes_pod_container_name
    target_label: container_name
  - replacement: /var/log/pods/*\$1/*.log
    separator: /
    source_labels:
    - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
    - __meta_kubernetes_pod_container_name
    target_label: __path__
  - action: labelmap
    regex: __meta_kubernetes_pod_label_(.+)
- job_name: journal
  journal:
    path: /var/log/journal
    labels:
      job: systemd-journal
  pipeline_stages:
  - labeldrop:
    - filename
    - stream
  - pack:
      labels:
      - boot_id
      - systemd_unit
  - labelallow:
      - host
      - invoker
  relabel_configs:
  - action: labelmap
    regex: __journal__(.+)
server:
  http_listen_port: 3101
target_config:
  sync_period: 10s
EOF

  cat >> "${config_dir}/fcct.yml" << EOF
variant: fcos
version: 1.1.0
ignition:
  config:
    merge:
      - local: bootstrap_initial.ign
storage:
  files:
    - path: /etc/promtail/grafanacom-secrets-password
      contents:
        local: grafanacom-secrets-password
      mode: 0644
    - path: /etc/promtail/config.yaml
      contents:
        local: promtail_config.yml
      mode: 0644
systemd:
  units:
    - name: promtail.service
      enabled: true
      contents: |
        [Unit]
        Description=promtail
        Wants=network-online.target
        After=network-online.target

        [Service]
        ExecStartPre=/usr/bin/podman create --rm --name=promtail -v /var/log/journal/:/var/log/journal/:z -v /etc/machine-id:/etc/machine-id -v /etc/promtail:/etc/promtail ${PROMTAIL_IMAGE}:${PROMTAIL_VERSION} -config.file=/etc/promtail/config.yaml -client.external-labels=host=%H,invoker='${OPENSHIFT_INSTALL_INVOKER}'
        ExecStart=/usr/bin/podman start -a promtail
        ExecStop=-/usr/bin/podman stop -t 10 promtail
        Restart=always
        RestartSec=60

        [Install]
        WantedBy=multi-user.target
EOF

  cp "${dir}/bootstrap.ign" "${config_dir}/bootstrap_initial.ign"
  # We're using ancient fcct as glibc in installer container is 1.28
  curl -sL https://github.com/coreos/butane/releases/download/v0.7.0/fcct-x86_64-unknown-linux-gnu >/tmp/fcct && chmod ug+x /tmp/fcct
  /tmp/fcct --pretty --strict -d "${config_dir}" "${config_dir}/fcct.yml" > "${dir}/bootstrap.ign"
}
function init_ibmcloud()
{
  if ! ibmcloud iam oauth-tokens 1>/dev/null 2>&1
  then
    ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r ${VPCREGION}
    ibmcloud target -g "${POWERVS_RESOURCE_GROUP}"
    SERVICE_INSTANCE_CRN="$(ibmcloud resource service-instances --output JSON | jq -r '.[] | select(.guid|test("'${POWERVS_SERVICE_INSTANCE_ID}'")) | .id')"
    ibmcloud pi service-target ${SERVICE_INSTANCE_CRN}
  fi
}
function check_resources(){
  #This function checks for any remaining DHCP leases/leftover/uncleaned resources and cleans them up before installing a new cluster
  set +e
  #install the tools required
  cd /tmp
  curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.9.0/IBM_Cloud_CLI_2.9.0_amd64.tar.gz
  tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz
  for I in infrastructure-service power-iaas cloud-internet-services cloud-object-storage dl-cli dns; do /tmp/Bluemix_CLI/bin/ibmcloud plugin install ${I}; done
  curl -L --output /tmp/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 && chmod +x /tmp/jq
  /tmp/jq --version

  echo "Check resource phase initiated"

  set -euo pipefail

  PATH=${PATH}:$(pwd)/bin:/tmp/:/tmp/jq:/tmp/Bluemix_CLI/bin:/tmp/Bluemix_CLI/bin/ibmcloud
  BASE64_API_KEY="$(echo -n ${IBMCLOUD_API_KEY} | base64)"
  IC_API_KEY=${IBMCLOUD_API_KEY}
  export PATH
  export BASE64_API_KEY
  export IC_API_KEY
  init_ibmcloud
  flag_destroy_resources=false

  #Uncomment for even more debugging!
  #export TF_LOG_PROVIDER=TRACE
  #export TF_LOG=TRACE
  #export TF_LOG_PATH=/tmp/tf.log
  #export IBMCLOUD_TRACE=true

  #
  # Quota check DNS
  #
  if ibmcloud cis 1>/dev/null 2>&1
  then
    # Currently, only support on x86_64 arch :(
    ibmcloud cis instance-set "$(ibmcloud cis instances --output json | jq -r '.[].name')"
    DNS_DOMAIN_ID="$(ibmcloud cis domains --output json | jq -r '.[].id')"
    export DNS_DOMAIN_ID
    RECORDS="$(ibmcloud cis dns-records ${DNS_DOMAIN_ID} --output json | jq -r '.[] | select (.name|test("'${CLUSTER_NAME}'.*")) | "\(.name) - \(.id)"')"
    if [ -n "${RECORDS}" ]
    then
      echo "${RECORDS}"
      if [ "$flag_destroy_resources" != true ] ; then
        flag_destroy_resources=true
      fi
    fi
  fi
  
  CIS_INSTANCE_CRN=$(ibmcloud cis instances --output json | jq -r '.[].id');
  export CIS_INSTANCE_CRN
  SERVICE_INSTANCE_CRN="$(ibmcloud resource service-instances --output JSON | jq -r '.[] | select(.guid|test("'${POWERVS_SERVICE_INSTANCE_ID}'")) | .crn')"
  export SERVICE_INSTANCE_CRN
  ibmcloud pi service-target ${SERVICE_INSTANCE_CRN}
  CLOUD_INSTANCE_ID="$(echo ${SERVICE_INSTANCE_CRN} | cut -d: -f8)"
  export CLOUD_INSTANCE_ID
  set +x
  BEARER_TOKEN=$(curl --silent -X POST "https://iam.cloud.ibm.com/identity/token" -H "content-type: application/x-www-form-urlencoded" -H "accept: application/json" -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${IBMCLOUD_API_KEY}" | jq -r .access_token)
  export BEARER_TOKEN
  [ -z "${BEARER_TOKEN}" ] && exit 1
  [ "${BEARER_TOKEN}" == "null" ] && exit 1
  DHCP_NETWORKS_RESULT="$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp" --header 'Content-Type: application/json' --header "CRN: ${SERVICE_INSTANCE_CRN}" --header "Authorization: Bearer ${BEARER_TOKEN}")"

  #
  # Quota check for image imports
  #
  JOBS=$(ibmcloud pi jobs --operation-action imageImport --json | jq -r '.Payload.jobs[] | select (.status.state|test("running")) | .id')
  if [ -n "${JOBS}" ]
  then
    echo "${JOBS}"
    exit 1
  fi

  echo "Check resource phase complete!"
  echo "flag_destroy_resources=${flag_destroy_resources}"
  if [ "$flag_destroy_resources" = true ] ; then
    destroy_resources
  fi
}

function destroy_resources(){

  mkdir /tmp/ocp-test
  cat > "/tmp/ocp-test/metadata.json" << EOF
{"clusterName":"${CLUSTER_NAME}","clusterID":"","infraID":"${CLUSTER_NAME}","powervs":{"BaseDomain":"${BASE_DOMAIN}","cisInstanceCRN":"${CIS_INSTANCE_CRN}","powerVSResourceGroup":"${POWERVS_RESOURCE_GROUP}","region":"${POWERVS_REGION}","vpcRegion":"","zone":"${POWERVS_ZONE}","serviceInstanceID":"${POWERVS_SERVICE_INSTANCE_ID}"}}
EOF

  [ -z "${CLOUD_INSTANCE_ID}" ] && exit 1
  echo "CLOUD_INSTANCE_ID=${CLOUD_INSTANCE_ID}"
  set +x
  BEARER_TOKEN=$(curl --silent -X POST "https://iam.cloud.ibm.com/identity/token" -H "content-type: application/x-www-form-urlencoded" -H "accept: application/json" -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${IBMCLOUD_API_KEY}" | jq -r .access_token)
  export BEARER_TOKEN
  [ -z "${BEARER_TOKEN}" ] && exit 1
  [ "${BEARER_TOKEN}" == "null" ] && exit 1
  DHCP_NETWORKS_RESULT="$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp" --header 'Content-Type: application/json' --header "CRN: ${SERVICE_INSTANCE_CRN}" --header "Authorization: Bearer ${BEARER_TOKEN}")"
  echo "${DHCP_NETWORKS_RESULT}" | jq -r '.[] | "\(.id) - \(.network.name)"'
  for i in {1..3}; do
    while read UUID
    do
      echo ${UUID}
      GET_RESULT=$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp/${UUID}" --header 'Content-Type: application/json' --header "CRN: ${SERVICE_INSTANCE_CRN}" --header "Authorization: Bearer ${BEARER_TOKEN}")
      echo "GET_RESULT=${GET_RESULT}"
      if [ "${GET_RESULT}" == "{}" ]
      then
        continue
      fi
      if [ "$(echo "${GET_RESULT}" | jq -r '.error')" == "dhcp server not found" ]
      then
        continue
      fi
      DELETE_RESULT=$(curl --silent --location --request DELETE "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp/${UUID}" --header 'Content-Type: application/json' --header "CRN: ${SERVICE_INSTANCE_CRN}" --header "Authorization: Bearer ${BEARER_TOKEN}")
      echo "DELETE_RESULT=${DELETE_RESULT}"
      sleep 2m
    done < <(echo "${DHCP_NETWORKS_RESULT}" | jq -r '.[] | .id')
  done

  # TODO: Remove after infra bugs are fixed
  # TO confirm resources are cleared properly
  set +e
  
  for i in {1..3}; do
    echo "Destroying cluster $i attempt..."
    date --utc +"%Y-%m-%dT%H:%M:%S%:z"
    date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_START_TIME_$i"
    openshift-install --dir /tmp/ocp-test destroy cluster --log-level=debug
    date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_END_TIME_$i"
  done
  set -e
}

function dump_resources(){

  init_ibmcloud

  echo "8<--------8<--------8<--------8<-------- Cloud Connection 8<--------8<--------8<--------8<--------"

  INFRA_ID=$(jq -r '.infraID' ${dir}/metadata.json)
  export INFRA_ID
  CLOUD_UUID=$(ibmcloud pi connections --json | jq -r '.Payload.cloudConnections[] | select (.name|test("'${INFRA_ID}'")) | .cloudConnectionID')

  if [ -z "${CLOUD_UUID}" ]
  then
    echo "Error: Could not find a Cloud Connection with the name ${INFRA_ID}"
  else
    ibmcloud pi connection ${CLOUD_UUID} || true
  fi

  echo "8<--------8<--------8<--------8<-------- Direct Link 8<--------8<--------8<--------8<--------"

  DL_UUID=$(ibmcloud dl gateways --output json | jq -r '.[] | select (.name|test("'${INFRA_ID}'")) | .id')

  if [ -z "${DL_UUID}" ]
  then
    echo "Error: Could not find a Direct Link with the name ${INFRA_ID}"
  else
    ibmcloud dl gateway ${DL_UUID} || true
  fi

  echo "8<--------8<--------8<--------8<-------- VPC 8<--------8<--------8<--------8<--------"

  VPC_UUID=$(ibmcloud is vpcs --output json | jq -r '.[] | select (.name|test("'${INFRA_ID}'")) | .id')

  if [ -z "${VPC_UUID}" ]
  then
    echo "Error: Could not find a VPC with the name ${INFRA_ID}"
  else
    ibmcloud is vpc ${VPC_UUID} || true
  fi

  echo "8<--------8<--------8<--------8<-------- DHCP networks 8<--------8<--------8<--------8<--------"

  BEARER_TOKEN=$(curl --silent -X POST "https://iam.cloud.ibm.com/identity/token" -H "content-type: application/x-www-form-urlencoded" -H "accept: application/json" -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${IBMCLOUD_API_KEY}" | jq -r .access_token)
  export BEARER_TOKEN
  [ -z "${BEARER_TOKEN}" ] && exit 1
  [ "${BEARER_TOKEN}" == "null" ] && exit 1
  DHCP_NETWORKS_RESULT=$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp" --header 'Content-Type: application/json' --header "CRN: ${POWERVS_SERVICE_INSTANCE_ID}" --header "Authorization: Bearer ${BEARER_TOKEN}")
  echo "${DHCP_NETWORKS_RESULT}" | jq -r '.[] | "\(.id) - \(.network.name)"'

  echo "8<--------8<--------8<--------8<-------- DHCP network information 8<--------8<--------8<--------8<--------"

  while read DHCP_UUID
  do
    RESULT=$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp/${DHCP_UUID}" --header 'Content-Type: application/json' --header "CRN: ${POWERVS_SERVICE_INSTANCE_ID}" --header "Authorization: Bearer ${BEARER_TOKEN}")
    echo "${RESULT}" | jq -r '.'

  done < <( echo "${DHCP_NETWORKS_RESULT}" | jq -r '.[] | .id' )

  echo "8<--------8<--------8<--------8<-------- Instance names, ids, and MAC addresses 8<--------8<--------8<--------8<--------"

  ibmcloud pi instances --json | jq -r '.Payload.pvmInstances[] | select (.serverName|test("'${INFRA_ID}'")) | [.serverName, .pvmInstanceID, .addresses[].ip, .addresses[].macAddress]'

  egrep '(Creation complete|level=error|: [0-9ms]*")' ${dir}/.openshift_install.log > ${SHARED_DIR}/installation_stats.log

  echo ${SHARED_DIR}/installation_stats.log

}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
IBMCLOUD_API_KEY=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_API_KEY")
IBMCLOUD_APIKEY_CCM_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_CCM_CREDS")
IBMCLOUD_APIKEY_INGRESS_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_INGRESS_CREDS")
IBMCLOUD_APIKEY_MACHINEAPI_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_MACHINEAPI_CREDS")
POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID")
POWERVS_RESOURCE_GROUP=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_RESOURCE_GROUP")
POWERVS_REGION=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_REGION")
POWERVS_USER_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_USER_ID")
POWERVS_ZONE=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_ZONE")
VPCREGION=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/VPCREGION")
CLUSTER_NAME="rdr-multiarch-ci"

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export POWERVS_SERVICE_INSTANCE_ID
export POWERVS_RESOURCE_GROUP
export POWERVS_USER_ID
export VPCREGION
export CLUSTER_NAME
export HOME=/tmp

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# Powervs requires config.json
cat > "/tmp/powervs-config.json" << EOF
{"id":"${POWERVS_USER_ID}","apikey":"${IBMCLOUD_API_KEY}","region":"${POWERVS_REGION}","zone":"${POWERVS_ZONE}"}
EOF
cp "/tmp/powervs-config.json" "${SHARED_DIR}/"
export POWERVS_AUTH_FILEPATH=${SHARED_DIR}/powervs-config.json

check_resources

case "${CLUSTER_TYPE}" in
powervs)
    export IBMCLOUD_API_KEY
    ;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

# Add ignition configs
date --utc "+%Y-%m-%dT%H:%M:%S%:z"
openshift-install --dir="${dir}" create ignition-configs

date --utc "+%Y-%m-%dT%H:%M:%S%:z"
openshift-install --dir="${dir}" create manifests

# copy ccoctl files
cat > "${dir}/manifests/openshift-cloud-controller-manager-ibm-cloud-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: ibm-cloud-credentials
  namespace: openshift-cloud-controller-manager
stringData:
  ibm-credentials.env: |-
    IBMCLOUD_AUTHTYPE=iam
    IBMCLOUD_APIKEY=${IBMCLOUD_APIKEY_CCM_CREDS}
  ibmcloud_api_key: ${IBMCLOUD_APIKEY_CCM_CREDS}
type: Opaque
EOF

cat > "${dir}/manifests/openshift-ingress-operator-cloud-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: cloud-credentials
  namespace: openshift-ingress-operator
stringData:
  ibm-credentials.env: |-
    IBMCLOUD_AUTHTYPE=iam
    IBMCLOUD_APIKEY=${IBMCLOUD_APIKEY_INGRESS_CREDS}
  ibmcloud_api_key: ${IBMCLOUD_APIKEY_INGRESS_CREDS}
type: Opaque
EOF

cat > "${dir}/manifests/openshift-machine-api-powervs-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: powervs-credentials
  namespace: openshift-machine-api
stringData:
  ibm-credentials.env: |-
    IBMCLOUD_AUTHTYPE=iam
    IBMCLOUD_APIKEY=${IBMCLOUD_APIKEY_MACHINEAPI_CREDS}
  ibmcloud_api_key: ${IBMCLOUD_APIKEY_MACHINEAPI_CREDS}
type: Opaque
EOF

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

if [ ! -z "${OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP:-}" ]; then
  # Inject promtail in bootstrap.ign
  date --utc "+%Y-%m-%dT%H:%M:%S%:z"
  openshift-install --dir="${dir}" create ignition-configs
  inject_promtail_service
fi

set +e
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
date --utc "+%Y-%m-%dT%H:%M:%S%:z"
TF_LOG=debug openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'

date --utc "+%Y-%m-%dT%H:%M:%S%:z"
TF_LOG=debug openshift-install wait-for install-complete --dir="${dir}" | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
ret=${PIPESTATUS[0]}
set -e

date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

dump_resources

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"
