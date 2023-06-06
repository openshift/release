#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set cluster variables
CLUSTER_NAME=$(cat "${SHARED_DIR}/CLUSTER_NAME")
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
COLLECTOR_CONF_FILE="${ARTIFACT_DIR}/containerized-data-collector.yaml"
OC_URL="https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/4.13.0/openshift-client-linux.tar.gz"
# OC_URL="https://downloads-openshift-console.apps.${CLUSTER_NAME}.${CLUSTER_DOMAIN}/amd64/linux/oc.tar"
IPV4_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
BIN_FOLDER=$(mktemp -d /tmp/bin.XXXX)

# Exports
export CLUSTER_NAME CLUSTER_DOMAIN
export PATH="${BIN_FOLDER}:${PATH}"

# Unset the following environment variables to avoid issues with oc command
unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT

cat << __EOF__ | tee "${COLLECTOR_CONF_FILE}"
data_collector_base_directory: "/${ARTIFACT_DIR}/tests-collected-info"
collect_data_function: "ocp_wrapper_data_collector.data_collector.collect_data"
collect_pod_logs: true
__EOF__

set -x
START_TIME=$(date "+%s")

# Get oc binary
curl -sL "${OC_URL}" | tar -C "${BIN_FOLDER}" -xzvf - oc

oc whoami --show-console

# Get the external IP of each node
NODES_IP_FILE="/tmp/nodes.ips"
(curl -s https://ipinfo.io/ip || /bin/true ; echo) | tee "${NODES_IP_FILE}"
oc get nodes -o name \
  | parallel oc debug {} -- curl -s https://ipinfo.io/ip \; echo \
  | tee -a "${NODES_IP_FILE}"

FWKNOPRC=${FWKNOPRC:-"${CLUSTER_PROFILE_DIR}/.fwknoprc"}

if [[ ! -f ${FWKNOPRC} ]]; then
  echo "File specified by FWKNOPRC (${FWKNOPRC}) does not exist. Using default value."
  FWKNOPRC="${CLUSTER_PROFILE_DIR}/.fwknoprc"
fi

cp "${FWKNOPRC}" /tmp/.fwknoprc
chmod 0600 /tmp/.fwknoprc
FWKNOPRC="/tmp/.fwknoprc"

# Open access to each node
grep -Eo "${IPV4_REGEX}" "${NODES_IP_FILE}" | sort -uV | while IFS= read -r NODE_IP; do
  if [[ ${NODE_IP} =~ ${IPV4_REGEX} ]]; then
    fwknop --rc-file "${FWKNOPRC}" --named-config cnv-qe-server --allow-ip "${NODE_IP}" || /bin/true
  else
    echo "Variable does not match an IPv4 address pattern."
    echo "Got => ${NODE_IP}"
  fi
done

poetry run pytest tests \
  --pytest-log-file="${ARTIFACT_DIR}/pytest.log" \
  --data-collector="${COLLECTOR_CONF_FILE}" \
  --junit-xml="${ARTIFACT_DIR}/junit_results.xml" \
  --tc-file=tests/global_config.py \
  --tc-format=python \
  --tc=check_http_server_connectivity:false \
  --tc default_storage_class:ocs-storagecluster-ceph-rbd \
  --tc default_volume_mode:Block \
  --latest-rhel \
  --tb=native \
  --storage-class-matrix=ocs-storagecluster-ceph-rbd \
  -o log_cli=true \
  -m smoke || /bin/true

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))
set +x

if [[ ${DIFF_TIME} -le 600 ]]; then
    echo ""
    echo " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    echo "  😴 😴 😴"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi
