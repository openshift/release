#!/bin/bash

set -o nounset
set +o errexit
set +o pipefail

function populate_artifact_dir() {
  # https://bash.cyberciti.biz/bash-reference-manual/Programmable-Completion-Builtins.html
  if compgen -G "${dir}/log-bundle-*.tar.gz" > /dev/null; then
    echo "Copying log bundle..."
    cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  fi
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${SHARED_DIR}/installation_stats.log" > "${ARTIFACT_DIR}/installation_stats.log"
  case "${CLUSTER_TYPE}" in
    powervs*)
      # We don't want debugging in this section
      unset TF_LOG_PROVIDER
      unset TF_LOG
      unset TF_LOG_PATH
      unset IBMCLOUD_TRACE

      echo "8<--------8<--------8<--------8<-------- Instance names, ids, and MAC addresses 8<--------8<--------8<--------8<--------"
      ibmcloud pi instances --json | jq -r '.pvmInstances[] | select (.serverName|test("'${CLUSTER_NAME}'")) | [.serverName, .pvmInstanceID, .addresses[].ip, .addresses[].macAddress]'
      echo "8<--------8<--------8<--------8<-------- DONE! 8<--------8<--------8<--------8<--------"
      ;;
    *)
      >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}' to collect machine IDs"
      ;;
  esac
}

function prepare_next_steps() {
  #Save exit code for must-gather to generate junit
  echo "$?" > "${SHARED_DIR}/install-status.txt"
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
  echo "Finished prepare_next_steps"
}

function log_to_file() {
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

function install_required_tools() {
  #install the tools required
  cd /tmp || exit 1

  export HOME=/tmp

  if [ ! -f /tmp/IBM_CLOUD_CLI_amd64.tar.gz ]; then
    curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.21.1/IBM_Cloud_CLI_2.21.1_amd64.tar.gz
    tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz

    if [ ! -f /tmp/Bluemix_CLI/bin/ibmcloud ]; then
      echo "Error: /tmp/Bluemix_CLI/bin/ibmcloud does not exist?"
      exit 1
    fi

    PATH=${PATH}:/tmp/Bluemix_CLI/bin

    hash file 2>/dev/null && file /tmp/Bluemix_CLI/bin/ibmcloud
    echo "Checking ibmcloud version..."
    if ! ibmcloud --version; then
      echo "Error: /tmp/Bluemix_CLI/bin/ibmcloud is not working?"
      exit 1
    fi

    for I in infrastructure-service power-iaas cloud-internet-services cloud-object-storage dl-cli dns; do
      ibmcloud plugin install ${I}
    done
    ibmcloud plugin list

    for PLUGIN in cis pi; do
      if ! ibmcloud ${PLUGIN} > /dev/null 2>&1; then
        echo "Error: ibmcloud's ${PLUGIN} plugin is not installed?"
        ls -la ${HOME}/.bluemix/
        ls -la ${HOME}/.bluemix/plugins/
        exit 1
      fi
    done
  fi

  if [ ! -f /tmp/jq ]; then

    for I in $(seq 1 10)
    do
      curl -L --output /tmp/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 && chmod +x /tmp/jq

      hash file 2>/dev/null && file /tmp/jq
      echo "Checking jq version..."
      if /tmp/jq --version; then
        break
      else
        echo "Error: /tmp/jq is not working?"
        /bin/rm /tmp/jq
        sleep 30s
      fi
    done

    if [ ! -f /tmp/jq ]; then
      echo "Error: Could not successfully download jq!"
      exit 1
    fi

    #PATH=${PATH}:/tmp/:/tmp/jq
    PATH=${PATH}:/tmp
  fi

  if [ ! -f /tmp/yq ] || [ ! -f /bin/yq-go ]; then

    uname -m
    ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
    echo "ARCH=${ARCH}"
    if [ -z "${ARCH}" ]; then
      echo "Error: ARCH is empty!"
      exit 1
    fi

    for I in $(seq 1 10)
    do
      curl -L "https://github.com/mikefarah/yq/releases/download/v4.25.3/yq_linux_${ARCH}" -o /tmp/yq && chmod +x /tmp/yq

      hash file 2>/dev/null && file /tmp/yq
      echo "Checking yq version..."
      if /tmp/yq --version; then
        break
      else
        echo "Error: /tmp/yq is not working?"
        /bin/rm /tmp/yq
        sleep 30s
      fi
    done
  fi

  PATH=${PATH}:$(pwd)/bin
  export PATH
}

function init_ibmcloud() {
  IC_API_KEY=${IBMCLOUD_API_KEY}
  export IC_API_KEY

  if ! ibmcloud iam oauth-tokens 1>/dev/null 2>&1
  then
    if [ -z "${IBMCLOUD_API_KEY}" ]; then
      echo "Error: IBMCLOUD_API_KEY is empty!"
      exit 1
    fi
    if [ -z "${VPCREGION}" ]; then
      echo "Error: VPCREGION is empty!"
      exit 1
    fi
    if [ -z "${POWERVS_RESOURCE_GROUP}" ]; then
      echo "Error: POWERVS_RESOURCE_GROUP is empty!"
      exit 1
    fi
    ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r ${VPCREGION}
    ibmcloud target -g "${POWERVS_RESOURCE_GROUP}"
  fi

  CIS_INSTANCE_CRN=$(ibmcloud cis instances --output json | jq -r '.[].id');
  if [ -z "${CIS_INSTANCE_CRN}" ]; then
    echo "Error: CIS_INSTANCE_CRN is empty!"
    exit 1
  fi
  export CIS_INSTANCE_CRN

  if [ -z "${POWERVS_SERVICE_INSTANCE_ID}" ]; then
    echo "Error: POWERVS_SERVICE_INSTANCE_ID is empty!"
    exit 1
  fi

  SERVICE_INSTANCE_CRN="$(ibmcloud resource service-instances --output JSON | jq -r '.[] | select(.guid|test("'${POWERVS_SERVICE_INSTANCE_ID}'")) | .crn')"
  if [ -z "${SERVICE_INSTANCE_CRN}" ]; then
    echo "Error: SERVICE_INSTANCE_CRN is empty!"
    exit 1
  fi
  export SERVICE_INSTANCE_CRN

  ibmcloud pi service-target ${SERVICE_INSTANCE_CRN}

  CLOUD_INSTANCE_ID="$(echo ${SERVICE_INSTANCE_CRN} | cut -d: -f8)"
  if [ -z "${CLOUD_INSTANCE_ID}" ]; then
    echo "Error: CLOUD_INSTANCE_ID is empty!"
    exit 1
  fi
  export CLOUD_INSTANCE_ID
}

function check_resources() {
  #This function checks for any remaining DHCP leases/leftover/uncleaned resources and cleans them up before installing a new cluster
  echo "Check resource phase initiated"

  flag_destroy_resources=false

  #
  # Quota check DNS
  #
  if ibmcloud cis 1>/dev/null 2>&1
  then
    # Currently, only support on x86_64 arch :(
    ibmcloud cis instance-set "$(ibmcloud cis instances --output json | jq -r '.[].name')"
    DNS_DOMAIN_ID="$(ibmcloud cis domains --output json | jq -r '.[].id')"
    export DNS_DOMAIN_ID
    DNS_RECORDS="$(ibmcloud cis dns-records ${DNS_DOMAIN_ID} --output json | jq -r '.[] | select (.name|test("'${CLUSTER_NAME}'.*")) | "\(.name) - \(.id)"')"
    if [ -n "${DNS_RECORDS}" ]
    then
      echo "DNS_RECORDS=${DNS_RECORDS}"
      if [ "$flag_destroy_resources" != true ] ; then
        flag_destroy_resources=true
      fi
    fi
  fi

  #
  # Quota check for image imports
  #
  JOBS=$(ibmcloud pi jobs --operation-action imageImport --json | jq -r '.jobs[] | select (.status.state|test("running")) | .id')
  if [ -n "${JOBS}" ]
  then
    echo "JOBS=${JOBS}"
    exit 1
  fi

  echo "Check resource phase complete!"
  echo "flag_destroy_resources=${flag_destroy_resources}"
  if [ "$flag_destroy_resources" = true ] ; then
    destroy_resources
  fi
}

function delete_network() {
  NETWORK_NAME=$1
  echo "delete_network(${NETWORK_NAME})"

  (
    while read UUID
    do
      echo ibmcloud pi network-delete ${UUID}
      ibmcloud pi network-delete ${UUID}
    done
  ) < <(ibmcloud pi networks --json | jq -r '.networks[] | select(.name|test("'${NETWORK_NAME}'")) | .networkID')

  for (( TRIES=0; TRIES<20; TRIES++ ))
  do
    LINES=$(ibmcloud pi networks --json | jq -r '.networks[] | select(.name|test("'${NETWORK_NAME}'")) | .networkID' | wc -l)
    echo "LINES=${LINES}"
    if (( LINES == 0 ))
    then
      return 0
    fi
    sleep 15s
  done

  return 1
}

function destroy_resources() {
  #
  # TODO: Remove after infra bugs are fixed
  # TO confirm resources are cleared properly
  #

  #
  # Clean up DHCP networks via curl.
  # At the moment, this is the only api and 4.11 version of destroy cluster
  # only cleans up DHCP networks in use by VMs, which is not always the case.
  #
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

  #
  # Create a fake cluster metadata file
  #
  mkdir /tmp/ocp-test
  cat > "/tmp/ocp-test/metadata.json" << EOF
{"clusterName":"${CLUSTER_NAME}","clusterID":"","infraID":"${CLUSTER_NAME}","powervs":{"BaseDomain":"${BASE_DOMAIN}","cisInstanceCRN":"${CIS_INSTANCE_CRN}","powerVSResourceGroup":"${POWERVS_RESOURCE_GROUP}","region":"${POWERVS_REGION}","vpcRegion":"","zone":"${POWERVS_ZONE}","serviceInstanceID":"${POWERVS_SERVICE_INSTANCE_ID}"}}
EOF

  #
  # Call destroy cluster on fake metadata file
  #
  DESTROY_SUCCEEDED=false
  for i in {1..3}; do
    echo "Destroying cluster $i attempt..."
    echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
    date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_START_TIME_$i"
    openshift-install --dir /tmp/ocp-test destroy cluster --log-level=debug
    ret=$?
    date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_END_TIME_$i"
    echo "ret=${ret}"
    if [ ${ret} -eq 0 ]; then
      DESTROY_SUCCEEDED=true
      break
    fi
  done

  #
  # Clean up leftover networks from a previous OpenShift cluster
  #
  if ! delete_network "rdr-multiarch-${POWERVS_ZONE}"
  then
      DESTROY_SUCCEEDED=false
  fi

  #
  # Clean up the public-192_168_XXX_XX-XX-VLAN_XXXX network
  #
  if ! delete_network "public-192_168"
  then
      DESTROY_SUCCEEDED=false
  fi

  if ! ${DESTROY_SUCCEEDED}
  then
    echo "Failed to destroy cluster failed after three attempts."
    exit 1
  fi
}

function dump_resources() {
  init_ibmcloud

  # We don't want debugging in this section
  if declare -p TF_LOG_PROVIDER &>/dev/null; then
    SAVE_TF_LOG_PROVIDER=${TF_LOG_PROVIDER}
    unset TF_LOG_PROVIDER
  fi
  if declare -p TF_LOG &>/dev/null; then
    SAVE_TF_LOG=${TF_LOG}
    unset TF_LOG
  fi
  if declare -p TF_LOG_PATH &>/dev/null; then
    SAVE_TF_LOG_PATH=${TF_LOG_PATH}
    unset TF_LOG_PATH
  fi
  if declare -p IBMCLOUD_TRACE &>/dev/null; then
    SAVE_IBMCLOUD_TRACE=${IBMCLOUD_TRACE}
    unset IBMCLOUD_TRACE
  fi

  INFRA_ID=$(jq -r '.infraID' ${dir}/metadata.json)
  echo "INFRA_ID=${INFRA_ID}"
  export INFRA_ID

  echo "8<--------8<--------8<--------8<-------- Cloud Connection 8<--------8<--------8<--------8<--------"

  CLOUD_UUID=$(ibmcloud pi connections --json | jq -r '.cloudConnections[] | select (.name|test("'${INFRA_ID}'")) | .cloudConnectionID')

  if [ -z "${CLOUD_UUID}" ]
  then
    echo "Error: Could not find a Cloud Connection with the name ${INFRA_ID}"
  else
    ibmcloud pi connection ${CLOUD_UUID}
  fi

  echo "8<--------8<--------8<--------8<-------- Direct Link 8<--------8<--------8<--------8<--------"

  DL_UUID=$(ibmcloud dl gateways --output json | jq -r '.[] | select (.name|test("'${INFRA_ID}'")) | .id')

  if [ -z "${DL_UUID}" ]
  then
    echo "Error: Could not find a Direct Link with the name ${INFRA_ID}"
  else
    ibmcloud dl gateway ${DL_UUID}
  fi

# "8<--------8<--------8<--------8<-------- Load Balancers 8<--------8<--------8<--------8<--------"

(
  LB_INT_FILE=$(mktemp)
  LB_MCS_POOL_FILE=$(mktemp)
  trap '/bin/rm "${LB_INT_FILE}" "${LB_MCS_POOL_FILE}"' EXIT

  ibmcloud is load-balancers --output json | jq -r '.[] | select (.name|test("'${INFRA_ID}'-loadbalancer-int"))' > ${LB_INT_FILE}
  LB_INT_ID=$(jq -r .id ${LB_INT_FILE})
  if [ -z "${LB_INT_ID}" ]
  then
    echo "Error: LB_INT_ID is empty"
    exit
  fi

  echo "8<--------8<--------8<--------8<-------- Internal Load Balancer 8<--------8<--------8<--------8<--------"
  ibmcloud is load-balancer ${LB_INT_ID}

  LB_MCS_ID=$(jq -r '.pools[] | select (.name|test("machine-config-server")) | .id' ${LB_INT_FILE})
  if [ -z "${LB_MCS_ID}" ]
  then
    echo "Error: LB_MCS_ID is empty"
    exit
  fi

  echo "8<--------8<--------8<--------8<-------- LB Machine Config Server 8<--------8<--------8<--------8<--------"
  ibmcloud is load-balancer-pool ${LB_INT_ID} ${LB_MCS_ID}

  echo "8<--------8<--------8<--------8<-------- LB MCS Pool 8<--------8<--------8<--------8<--------"
  ibmcloud is load-balancer-pool ${LB_INT_ID} ${LB_MCS_ID} --output json > ${LB_MCS_POOL_FILE}
  while read UUID
  do
    ibmcloud is load-balancer-pool-member ${LB_INT_ID} ${LB_MCS_ID} ${UUID}
  done < <(jq -r '.members[].id' ${LB_MCS_POOL_FILE})
)

  echo "8<--------8<--------8<--------8<-------- VPC 8<--------8<--------8<--------8<--------"

  VPC_UUID=$(ibmcloud is vpcs --output json | jq -r '.[] | select (.name|test("'${INFRA_ID}'")) | .id')

  if [ -z "${VPC_UUID}" ]
  then
    echo "Error: Could not find a VPC with the name ${INFRA_ID}"
  else
    ibmcloud is vpc ${VPC_UUID}
  fi

  echo "8<--------8<--------8<--------8<-------- DHCP networks 8<--------8<--------8<--------8<--------"

  BEARER_TOKEN=$(curl --silent -X POST "https://iam.cloud.ibm.com/identity/token" -H "content-type: application/x-www-form-urlencoded" -H "accept: application/json" -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${IBMCLOUD_API_KEY}" | jq -r .access_token)
  export BEARER_TOKEN
  [ -z "${BEARER_TOKEN}" ] && exit 1
  [ "${BEARER_TOKEN}" == "null" ] && exit 1
  DHCP_NETWORKS_RESULT=$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp" --header 'Content-Type: application/json' --header "CRN: ${SERVICE_INSTANCE_CRN}" --header "Authorization: Bearer ${BEARER_TOKEN}")
  echo "${DHCP_NETWORKS_RESULT}" | jq -r '.[] | "\(.id) - \(.network.name)"'
  if [ $? -gt 0 ]
  then
    echo "DHCP_NETWORKS_RESULT=${DHCP_NETWORKS_RESULT}"
  fi

  echo "8<--------8<--------8<--------8<-------- DHCP network information 8<--------8<--------8<--------8<--------"

  while read DHCP_UUID
  do
    DHCP_UUID_RESULT=$(curl --silent --location --request GET "https://${POWERVS_REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/services/dhcp/${DHCP_UUID}" --header 'Content-Type: application/json' --header "CRN: ${SERVICE_INSTANCE_CRN}" --header "Authorization: Bearer ${BEARER_TOKEN}")
    echo "${DHCP_UUID_RESULT}" | jq -r '.'
    if [ $? -gt 0 ]
    then
      echo "DHCP_UUID_RESULT=${DHCP_UUID_RESULT}"
    fi

  done < <( echo "${DHCP_NETWORKS_RESULT}" | jq -r '.[] | .id' )

  echo "8<--------8<--------8<--------8<-------- oc get clusterversion 8<--------8<--------8<--------8<--------"

  (
    DEBUG=true

    CV_FILE=$(mktemp)
    F_FILE=$(mktemp)
    trap '/bin/rm "${CV_FILE}" "${F_FILE}"' EXIT

    export KUBECONFIG=${dir}/auth/kubeconfig

    oc --request-timeout=5s get clusterversion -o json > ${CV_FILE} 2>/dev/null
    RC=$?
    echo "oc --request-timeout=5s get clusterversion -o json"
    echo "RC=${RC}"
    if ${DEBUG}
    then
      oc --request-timeout=5s get clusterversion 2>/dev/null > ${ARTIFACT_DIR}/get-clusterversion.output
    fi
    if [ ${RC} -gt 0 ]
    then
      exit 1
    fi
    if ${DEBUG}
    then
      echo "===== BEGIN: oc get clusterversion: CV_FILE =====" >> ${ARTIFACT_DIR}/get-clusterversion.output
      cat ${CV_FILE} >> ${ARTIFACT_DIR}/get-clusterversion.output
      echo "===== END: oc get clusterversion: CV_FILE =====" >> ${ARTIFACT_DIR}/get-clusterversion.output
    fi
    jq -r '.items[].status.conditions[] | select (.status|test("False"))' ${CV_FILE} > ${F_FILE}
    RC=$?
    echo "jq -r '.items[].status.conditions[] | ..."
    echo "RC=${RC}"
    if ${DEBUG}
    then
      echo "===== BEGIN: oc get clusterversion: F_FILE =====" >> ${ARTIFACT_DIR}/get-clusterversion.output
      cat ${F_FILE} >> ${ARTIFACT_DIR}/get-clusterversion.output
      echo "===== END: oc get clusterversion: F_FILE =====" >> ${ARTIFACT_DIR}/get-clusterversion.output
    fi
    if [ ${RC} -gt 0 ]
    then
      exit 1
    fi
    echo "Select ALL, where \"status\": \"False\" returns:"
    cat ${F_FILE}
    echo
    echo "Select \"type\": \"Available\", where \"status\": \"False\" returns:"
    jq -r 'select (.type|test("Available"))' ${F_FILE}
  )

  echo "8<--------8<--------8<--------8<-------- oc get co 8<--------8<--------8<--------8<--------"
  (
    export KUBECONFIG=${dir}/auth/kubeconfig
    oc --request-timeout=5s get co
  )

  echo "8<--------8<--------8<--------8<-------- oc get nodes 8<--------8<--------8<--------8<--------"
  (
    export KUBECONFIG=${dir}/auth/kubeconfig
    oc --request-timeout=5s get nodes -o=wide
  )

  echo "8<--------8<--------8<--------8<-------- oc get pods not running nor completed 8<--------8<--------8<--------8<--------"
  (
    export KUBECONFIG=${dir}/auth/kubeconfig
    oc --request-timeout=5s get pods -A -o=wide | sed -e '/\(Running\|Completed\)/d'
  )

  echo "8<--------8<--------8<--------8<-------- Instance names, health 8<--------8<--------8<--------8<--------"
  ibmcloud pi instances --json | jq -r '.pvmInstances[] | select (.serverName|test("'${CLUSTER_NAME}'")) | " \(.serverName) - \(.status) - health: \(.health.reason) - \(.health.status)"'

  echo "8<--------8<--------8<--------8<-------- Running jobs 8<--------8<--------8<--------8<--------"
  ibmcloud pi jobs --json | jq -r '.jobs[] | select (.status.state|test("running"))'

  echo "8<--------8<--------8<--------8<-------- DONE! 8<--------8<--------8<--------8<--------"

  # Restore any debugging if saved
  if declare -p SAVE_TF_LOG_PROVIDER &>/dev/null; then
    export TF_LOG_PROVIDER=${SAVE_TF_LOG_PROVIDER}
    unset SAVE_TF_LOG_PROVIDER
  fi
  if declare -p SAVE_TF_LOG &>/dev/null; then
    export TF_LOG=${SAVE_TF_LOG}
    unset SAVE_TF_LOG
  fi
  if declare -p SAVE_TF_LOG_PATH &>/dev/null; then
    export TF_LOG_PATH=${SAVE_TF_LOG_PATH}
    unset SAVE_TF_LOG_PATH
  fi
  if declare -p SAVE_IBMCLOUD_TRACE &>/dev/null; then
    export IBMCLOUD_TRACE=${SAVE_IBMCLOUD_TRACE}
    unset SAVE_IBMCLOUD_TRACE
  fi
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

install_required_tools

IBMCLOUD_API_KEY=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_API_KEY")
IBMCLOUD_APIKEY_CCM_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_CCM_CREDS")
IBMCLOUD_APIKEY_INGRESS_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_INGRESS_CREDS")
IBMCLOUD_APIKEY_MACHINEAPI_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_MACHINEAPI_CREDS")
IBMCLOUD_APIKEY_CSI_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_APIKEY_CSI_CREDS")
IBMCLOUD_REGISTRY_INSTALLER_CREDS=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/IBMCLOUD_REGISTRY_INSTALLER_CREDS")
POWERVS_RESOURCE_GROUP=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_RESOURCE_GROUP")
POWERVS_USER_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_USER_ID")
POWERVS_SERVICE_INSTANCE_ID=$(yq eval '.POWERVS_SERVICE_INSTANCE_ID' "${SHARED_DIR}/powervs-conf.yaml")
POWERVS_REGION=$(yq eval '.POWERVS_REGION' "${SHARED_DIR}/powervs-conf.yaml")
POWERVS_ZONE=$(yq eval '.POWERVS_ZONE' "${SHARED_DIR}/powervs-conf.yaml")
VPCREGION=$(yq eval '.VPCREGION' "${SHARED_DIR}/powervs-conf.yaml")
CLUSTER_NAME=$(yq eval '.CLUSTER_NAME' "${SHARED_DIR}/powervs-conf.yaml")

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export POWERVS_SERVICE_INSTANCE_ID
export POWERVS_RESOURCE_GROUP
export POWERVS_USER_ID
export VPCREGION
export CLUSTER_NAME

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# Powervs requires config.json
cat > "/tmp/powervs-config.json" << EOF
{"id":"${POWERVS_USER_ID}","apikey":"${IBMCLOUD_API_KEY}","region":"${POWERVS_REGION}","zone":"${POWERVS_ZONE}","serviceinstance":"${POWERVS_SERVICE_INSTANCE_ID}","resourcegroup":"${POWERVS_RESOURCE_GROUP}"}
EOF
cp "/tmp/powervs-config.json" "${SHARED_DIR}/"
export POWERVS_AUTH_FILEPATH=${SHARED_DIR}/powervs-config.json

init_ibmcloud

#
# Don't call check_resources.  Always call destroy_resources since it is safe.
#
destroy_resources

case "${CLUSTER_TYPE}" in
powervs*)
    export IBMCLOUD_API_KEY
    ;;
*)
    >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
    ;;
esac

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

echo "POWERVS_REGION=${POWERVS_REGION}"
echo "POWERVS_ZONE=${POWERVS_ZONE}"

openshift-install version

# Add ignition configs
echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
openshift-install --dir="${dir}" create ignition-configs
if [ ! -z "${OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP:-}" ]; then
  echo "Inject promtail in bootstrap.ign"
  inject_promtail_service
fi

# Create installation manifests
echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
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

cat > "${dir}/manifests/openshift-cluster-csi-drivers-ibm-powervs-cloud-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: ibm-powervs-cloud-credentials
  namespace: openshift-cluster-csi-drivers
stringData:
  ibm-credentials.env: |-
    IBMCLOUD_AUTHTYPE=iam
    IBMCLOUD_APIKEY=${IBMCLOUD_APIKEY_CSI_CREDS}
  ibmcloud_api_key: ${IBMCLOUD_APIKEY_CSI_CREDS}
type: Opaque
EOF

cat > "${dir}/manifests/openshift-image-registry-installer-cloud-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: installer-cloud-credentials
  namespace: openshift-image-registry
stringData:
  ibm-credentials.env: |-
    IBMCLOUD_AUTHTYPE=iam
    IBMCLOUD_APIKEY=${IBMCLOUD_REGISTRY_INSTALLER_CREDS}
  ibmcloud_api_key: ${IBMCLOUD_REGISTRY_INSTALLER_CREDS}
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

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

export TF_LOG=debug
# Uncomment for even more debugging!
#export TF_LOG_PROVIDER=TRACE
#export TF_LOG=TRACE
#export TF_LOG_PATH=/tmp/tf.log
#export IBMCLOUD_TRACE=true

echo "8<--------8<--------8<--------8<-------- BEGIN: create cluster 8<--------8<--------8<--------8<--------"
echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
ret=${PIPESTATUS[0]}
echo "ret=${ret}"
echo "8<--------8<--------8<--------8<-------- END: create cluster 8<--------8<--------8<--------8<--------"

if [ ${ret} -gt 0 ]; then
  echo "8<--------8<--------8<--------8<-------- BEGIN: wait-for install-complete 8<--------8<--------8<--------8<--------"
  echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
  openshift-install wait-for install-complete --dir="${dir}" | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
  ret=${PIPESTATUS[0]}
  echo "ret=${ret}"
  echo "8<--------8<--------8<--------8<-------- END: wait-for install-complete 8<--------8<--------8<--------8<--------"
fi

date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

dump_resources

egrep '(Creation complete|level=error|: [0-9ms]*")' ${dir}/.openshift_install.log > ${SHARED_DIR}/installation_stats.log

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

echo "Exiting with ret=${ret}"
exit "${ret}"
