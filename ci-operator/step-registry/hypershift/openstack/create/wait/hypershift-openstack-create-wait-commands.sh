#!/bin/bash

set -euo pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -z "${CLUSTER_NAME:-}" ]; then
  CLUSTER_NAME="$(echo -n "$PROW_JOB_ID"|sha256sum|cut -c-20)"
fi
set +e
export CLUSTER_NAME
timeout 25m bash -c '
  until [[ "$(oc get -n clusters hostedcluster/${CLUSTER_NAME} -o jsonpath='"'"'{.status.version.history[?(@.state!="")].state}'"'"')" = "Completed" ]]; do
      sleep 15
  done
'
if [[ $? -ne 0 ]]; then
  cat << EOF > "${ARTIFACT_DIR}/junit_hosted_cluster.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift install" tests="1" failures="1">
  <testcase name="hosted cluster version rollout succeeds">
    <failure message="hosted cluster version rollout never completed">
      <![CDATA[
error: hosted cluster version rollout never completed, dumping relevant hosted cluster condition messages
Degraded: $(oc get -n clusters "hostedcluster/${CLUSTER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}')
ClusterVersionSucceeding: $(oc get -n clusters "hostedcluster/${CLUSTER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="ClusterVersionSucceeding")].message}')
      ]]>
    </failure>
  </testcase>
</testsuite>
EOF
  exit 1
else
  cat << EOF > "${ARTIFACT_DIR}/junit_hosted_cluster.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift install" tests="1" failures="0">
  <testcase name="hosted cluster version rollout succeeds">
    <system-out>
      <![CDATA[
info: hosted cluster version rollout completed successfully
      ]]>
    </system-out>
  </testcase>
</testsuite>
EOF
fi
set -e
echo "Hosted Cluster is healthy"
