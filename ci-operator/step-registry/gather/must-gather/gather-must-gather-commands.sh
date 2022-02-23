#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

echo "Running must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather
oc --insecure-skip-tls-verify adm must-gather $MUST_GATHER_IMAGE --dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/must-gather.log
[ -f "${ARTIFACT_DIR}/must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather

cat >"${ARTIFACT_DIR}/junit_e2e_20220211-9871239.xml" <<EOF
<testsuite name="dgoodwin test" tests="1" failures="0">
<link type="text/css" rel="stylesheet" id="dark-mode-custom-link"/>
<link type="text/css" rel="stylesheet" id="dark-mode-general-link"/>
<style lang="en" type="text/css" id="dark-mode-custom-style"/>
<style lang="en" type="text/css" id="dark-mode-native-style"/>
<testcase name="this is a test"/>
</testsuite>
EOF
