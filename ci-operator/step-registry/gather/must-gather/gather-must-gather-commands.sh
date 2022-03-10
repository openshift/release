#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function createInstallJunit() {
  if test -f "${SHARED_DIR}/install-status.txt"
  then
    EXIT_CODE=`cat ${SHARED_DIR}/install-status.txt | awk '{print $1}'`
    INSTALL_STATUS=`cat ${SHARED_DIR}/install-status.txt | awk '{print $2}'`
    if [ "$EXIT_CODE" ==  0  ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="2" failures="0">
        <testcase name="cluster bootstrap should succeed"/>
        <testcase name="cluster install should succeed"/>
      </testsuite>
EOF
    elif [ $INSTALL_STATUS == "bootstrap_successful" ] || [ $INSTALL_STATUS == "cluster_creation_successful" ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="2" failures="1">
        <testcase name="cluster bootstrap should succeed"/>
        <testcase name="cluster install should succeed">
          <failure message="">openshift cluster install failed after stage $INSTALL_STATUS with exit code $EXIT_CODE</failure>
        </testcase>
      </testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="2" failures="2">
        <testcase name="cluster bootstrap should succeed">
          <failure message="">cluster bootstrap failed</failure>
        </testcase>
        <testcase name="cluster install should succeed">
          <failure message="">openshift cluster install failed after stage $INSTALL_STATUS with exit code $EXIT_CODE</failure>
        </testcase>
      </testsuite>
EOF
    fi
  fi
}

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling must-gather."
	exit 0
fi

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

# Allow a job to override the must-gather image, this is needed for
# disconnected environments prior to 4.8.
if test -f "${SHARED_DIR}/must-gather-image.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/must-gather-image.sh"
else
	MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-""}
fi

createInstallJunit

echo "Running must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather
oc --insecure-skip-tls-verify adm must-gather $MUST_GATHER_IMAGE --dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/must-gather.log
[ -f "${ARTIFACT_DIR}/must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather

cat >> ${SHARED_DIR}/custom-links.txt << EOF
<script>
let kaas = document.createElement('a');
kaas.href="https://kaas.dptools.openshift.org/?search="+document.referrer;
kaas.title="KaaS is a service to spawn a fake API service that parses must-gather data. As a result, users can pass Prow CI URL to the service, fetch generated kubeconfig and use kubectl/oc/k9s/openshift-console to investigate the state of the cluster at the time must-gather was collected."
kaas.innerHTML="KaaS";
kaas.target="_blank";
document.getElementById("wrapper").append(kaas);
</script>
EOF
