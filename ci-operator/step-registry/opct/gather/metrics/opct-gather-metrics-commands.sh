#!/bin/bash

set -o nounset

export KUBECONFIG=${SHARED_DIR}/kubeconfig
EXIT_CODE=0

BIN_PATH=/tmp/bin
export PATH=$PATH:${BIN_PATH}
mkdir -p $BIN_PATH

echo "$(date -u --rfc-3339=seconds) - Installing tools..."

function install_tools() {
  # install newest oc
  curl -sL https://openshift-provider-certification.s3.us-west-2.amazonaws.com/bin/opct-linux-amd64-devel > /tmp/bin/opct
  chmod ug+x $BIN_PATH/opct
}

function collect_parse_metrics() {
  OUTPUT_DIR="${ARTIFACT_DIR}/monitoring-metrics/"

  echo "$(date -u --rfc-3339=seconds) - Gathering monitoring metrics"

  oc adm must-gather --image=quay.io/opct/must-gather-monitoring:v0.2.0 --dest-dir=/tmp/must-gather-montioring
  tar cfJ "${OUTPUT_DIR}"/must-gather-monitoring.tar.xz /tmp/must-gather-montioring

  echo "$(date -u --rfc-3339=seconds) - Gathering monitoring metrics complete"

  echo "$(date -u --rfc-3339=seconds) - Parsing monitoring metrics"

  $BIN_PATH/opct adm parse-metrics --input "${OUTPUT_DIR}"/must-gather-monitoring.tar.xz --output "${OUTPUT_DIR}/"

  echo "$(date -u --rfc-3339=seconds) - Parsing monitoring metrics complete"
}

install_tools
collect_parse_metrics

exit "${EXIT_CODE}"
