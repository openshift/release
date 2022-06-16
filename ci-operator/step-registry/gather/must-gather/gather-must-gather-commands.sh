#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function createInstallJunit() {
  EXIT_CODE_CONFIG=3
  EXIT_CODE_INFRA=4
  EXIT_CODE_BOOTSTRAP=5
  EXIT_CODE_CLUSTER=6
  if test -f "${SHARED_DIR}/install-status.txt"
  then
    EXIT_CODE=`cat ${SHARED_DIR}/install-status.txt | awk '{print $1}'`
    cp "${SHARED_DIR}/install-status.txt" ${ARTIFACT_DIR}/
    if [ "$EXIT_CODE" ==  0  ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="6" failures="0">
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap"/>
        <testcase name="install should succeed: cluster creation"/>
        <testcase name="install should succeed: overall"/>
      </testsuite>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_CONFIG" ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="3" failures="2">
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration">
          <failure message="">openshift cluster install failed with config validation error</failure>
        </testcase>
        <testcase name="install should succeed: overall">
          <failure message="">openshift cluster install failed overall</failure>
        </testcase>
      </testsuite>
EOF
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_INFRA" ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="4" failures="2">
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure">
          <failure message="">openshift cluster install failed with infrastructure setup</failure>
        </testcase>
        <testcase name="install should succeed: overall">
          <failure message="">openshift cluster install failed overall</failure>
        </testcase>
      </testsuite>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_BOOTSTRAP" ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="5" failures="2">
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap">
          <failure message="">openshift cluster install failed with cluster bootstrap</failure>
        </testcase>
        <testcase name="install should succeed: overall">
          <failure message="">openshift cluster install failed overall</failure>
        </testcase>
      </testsuite>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_CLUSTER" ]
    then
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="6" failures="2">
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap"/>
        <testcase name="install should succeed: cluster creation">
          <failure message="">openshift cluster install failed with cluster creation</failure>
        </testcase>
        <testcase name="install should succeed: overall">
          <failure message="">openshift cluster install failed overall</failure>
        </testcase>
      </testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="2" failures="2">
        <testcase name="install should succeed: other">
          <failure message="">openshift cluster install failed with other errors</failure>
        </testcase>
        <testcase name="install should succeed: overall">
          <failure message="">openshift cluster install failed overall</failure>
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
