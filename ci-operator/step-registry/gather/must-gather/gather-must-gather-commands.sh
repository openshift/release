#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function xmlescape() {
  echo -n "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

function createInstallJunit() {
  EXIT_CODE_CONFIG=3
  EXIT_CODE_INFRA=4
  EXIT_CODE_BOOTSTRAP=5
  EXIT_CODE_CLUSTER=6
  EXIT_CODE_OPERATORS=7
  EXIT_CODE_PRECONFIG=100
  EXIT_CODE_POSTCHECK=101
  INSTALL_INFRA_FAILURE_LOGFILE="${SHARED_DIR}/install_infrastructure_failure.log"
  local failure_output

  # Check pre-config status
  HAS_PRECONFIG=false
  PRECONFIG_PASSED=false
  if test -f "${SHARED_DIR}/install-pre-config-status.txt"; then
    HAS_PRECONFIG=true
    if [ "$(<"${SHARED_DIR}/install-pre-config-status.txt")" != "${EXIT_CODE_PRECONFIG}" ]; then
      PRECONFIG_PASSED=true
    fi
  fi

  # Check install status
  if test -f "${SHARED_DIR}/install-status.txt"
  then
    EXIT_CODE=`tail -n1 "${SHARED_DIR}/install-status.txt" | awk '{print $1}'`
    cp "${SHARED_DIR}/install-status.txt" "${ARTIFACT_DIR}/"
    set +o errexit
    grep -q "^$EXIT_CODE_INFRA$" "${SHARED_DIR}/install-status.txt"
    PREVIOUS_INFRA_FAILURE=$((1-$?))
    set -o errexit
  fi

  # Check post-check status
  HAS_POSTCHECK=false
  POSTCHECK_PASSED=false
  if test -f "${SHARED_DIR}/install-post-check-status.txt"; then
    HAS_POSTCHECK=true
    if ! grep -q "^$EXIT_CODE_POSTCHECK$" "${SHARED_DIR}/install-post-check-status.txt"; then
      POSTCHECK_PASSED=true
    fi
  fi

  # Calculate total tests and failures
  local test_count=0
  local failure_count=0

  # Pre-config contributes 1 test
  if [ "$HAS_PRECONFIG" = true ]; then
    test_count=$((test_count + 1))
    if [ "$PRECONFIG_PASSED" = false ]; then
      failure_count=$((failure_count + 1))
    fi
  fi

  # Install contributes tests based on exit code (overall is added separately)
  if test -f "${SHARED_DIR}/install-status.txt"; then
    if [ "$EXIT_CODE" == 0 ]; then
      test_count=$((test_count + 6 + PREVIOUS_INFRA_FAILURE))
      failure_count=$((failure_count + PREVIOUS_INFRA_FAILURE))
    elif [ "$EXIT_CODE" == "$EXIT_CODE_CONFIG" ]; then
      test_count=$((test_count + 2))
      failure_count=$((failure_count + 1))
    elif [ "$EXIT_CODE" == "$EXIT_CODE_INFRA" ]; then
      test_count=$((test_count + 3))
      failure_count=$((failure_count + 1))
    elif [ "$EXIT_CODE" == "$EXIT_CODE_BOOTSTRAP" ]; then
      test_count=$((test_count + 4))
      failure_count=$((failure_count + 1))
    elif [ "$EXIT_CODE" == "$EXIT_CODE_CLUSTER" ]; then
      test_count=$((test_count + 5))
      failure_count=$((failure_count + 1))
    elif [ "$EXIT_CODE" == "$EXIT_CODE_OPERATORS" ]; then
      test_count=$((test_count + 6))
      failure_count=$((failure_count + 1))
    else
      test_count=$((test_count + 1))
      failure_count=$((failure_count + 1))
    fi
  fi

  # Post-check contributes 1 test
  if [ "$HAS_POSTCHECK" = true ]; then
    test_count=$((test_count + 1))
    if [ "$POSTCHECK_PASSED" = false ]; then
      failure_count=$((failure_count + 1))
    fi
  fi

  # Overall contributes 1 test (always present if any phase ran)
  if [ "$HAS_PRECONFIG" = true ] || test -f "${SHARED_DIR}/install-status.txt" || [ "$HAS_POSTCHECK" = true ]; then
    test_count=$((test_count + 1))
    # Overall fails if any phase failed
    if ([ "$PRECONFIG_PASSED" = false ] && [ "$HAS_PRECONFIG" = true ]) || \
       ([ "$EXIT_CODE" != 0 ] && test -f "${SHARED_DIR}/install-status.txt") || \
       ([ "$POSTCHECK_PASSED" = false ] && [ "$HAS_POSTCHECK" = true ]); then
      failure_count=$((failure_count + 1))
    fi
  fi

  # Generate junit file
  if [ "$test_count" -gt 0 ]
  then
    cat >"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      <testsuite name="cluster install" tests="$test_count" failures="$failure_count">
EOF

    # Append pre-config test case
    if [ "$HAS_PRECONFIG" = true ]; then
      if [ "$PRECONFIG_PASSED" = true ]; then
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: pre configuration"/>
EOF
      else
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: pre configuration">
          <failure message="">pre configuration failed</failure>
        </testcase>
EOF
      fi
    fi

    # Append install test cases based on exit code
    if test -f "${SHARED_DIR}/install-status.txt"; then
      if [ "$EXIT_CODE" == 0 ]; then
        # Successful install
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap"/>
        <testcase name="install should succeed: cluster creation"/>
        <testcase name="install should succeed: cluster operator stability"/>
EOF
        # If we encountered infra failure but ultimately succeeded
        if [ "$PREVIOUS_INFRA_FAILURE" = 1 ]; then
          failure_output="openshift cluster install failed with infrastructure setup"
          if [ -s "${INSTALL_INFRA_FAILURE_LOGFILE}" ]; then
            failure_output=$(cat "${INSTALL_INFRA_FAILURE_LOGFILE}")
          fi
          cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: infrastructure">
          <failure message="">$( xmlescape "${failure_output}" )</failure>
        </testcase>
EOF
        fi
      elif [ "$EXIT_CODE" == "$EXIT_CODE_CONFIG" ]; then
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration">
          <failure message="">openshift cluster install failed with config validation error</failure>
        </testcase>
EOF
      elif [ "$EXIT_CODE" == "$EXIT_CODE_INFRA" ]; then
        failure_output="openshift cluster install failed with infrastructure setup"
        if [ -s "${INSTALL_INFRA_FAILURE_LOGFILE}" ]; then
          failure_output=$(cat "${INSTALL_INFRA_FAILURE_LOGFILE}")
        fi
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure">
          <failure message="">$( xmlescape "${failure_output}" )</failure>
        </testcase>
EOF
      elif [ "$EXIT_CODE" == "$EXIT_CODE_BOOTSTRAP" ]; then
        failure_output="openshift cluster install failed with cluster bootstrap"
        if [ -s "${INSTALL_INFRA_FAILURE_LOGFILE}" ]; then
          failure_output=$(cat "${INSTALL_INFRA_FAILURE_LOGFILE}")
        fi
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap">
          <failure message="">$( xmlescape "${failure_output}" )</failure>
        </testcase>
EOF
      elif [ "$EXIT_CODE" == "$EXIT_CODE_CLUSTER" ]; then
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap"/>
        <testcase name="install should succeed: cluster creation">
          <failure message="">openshift cluster install failed with cluster creation</failure>
        </testcase>
EOF
      elif [ "$EXIT_CODE" == "$EXIT_CODE_OPERATORS" ]; then
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other"/>
        <testcase name="install should succeed: configuration"/>
        <testcase name="install should succeed: infrastructure"/>
        <testcase name="install should succeed: cluster bootstrap"/>
        <testcase name="install should succeed: cluster creation"/>
        <testcase name="install should succeed: cluster operator stability">
          <failure message="">openshift cluster install failed with cluster operator stability failure</failure>
        </testcase>
EOF
      else
        # Other/unknown install failure
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: other">
          <failure message="">openshift cluster install failed with other errors</failure>
        </testcase>
EOF
      fi
    fi

    # Append post-check test case
    if [ "$HAS_POSTCHECK" = true ]; then
      if [ "$POSTCHECK_PASSED" = true ]; then
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: post check"/>
EOF
      else
        cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: post check">
          <failure message="">openshift cluster install succeeded, but failed at post check steps</failure>
        </testcase>
EOF
      fi
    fi

    # Append overall test case
    if [ "$failure_count" -gt 0 ]; then
      cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: overall">
          <failure message="">openshift cluster install failed overall</failure>
        </testcase>
EOF
    else
      cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
        <testcase name="install should succeed: overall"/>
EOF
    fi

    # Close testsuite
    cat >>"${ARTIFACT_DIR}/junit_install.xml" <<EOF
      </testsuite>
EOF
  fi
}

# camgi is a tool that creates an html document for investigating an OpenShift cluster
# see https://github.com/elmiko/camgi.rs for more information
function installCamgi() {
    CAMGI_VERSION="0.10.0"
    pushd /tmp

    # no internet access in C2S/SC2S env, disable proxy
    if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
      if [ ! -f "${SHARED_DIR}/unset-proxy.sh" ]; then
        echo "ERROR, unset-proxy.sh does not exist."
        return 1
      fi
      source "${SHARED_DIR}/unset-proxy.sh"
    fi

    curl -L -o camgi.tar https://github.com/elmiko/camgi.rs/releases/download/v"$CAMGI_VERSION"/camgi-"$CAMGI_VERSION"-linux-x86_64.tar
    tar xvf camgi.tar
    sha256sum -c camgi.sha256
    echo "camgi version $CAMGI_VERSION downloaded"

    if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
      if [ ! -f "${SHARED_DIR}/proxy-conf.sh" ]; then
        echo "ERROR, proxy-conf.sh does not exist."
        return 1
      fi
      source "${SHARED_DIR}/proxy-conf.sh"
    fi

    popd
}

createInstallJunit

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

MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"15m"}

# Download the binary from mirror
curl -sL "https://mirror.openshift.com/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
chmod +x /tmp/mco-sanitize

set -x # log the MG commands
echo "Running must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather
if [ -n "$MUST_GATHER_IMAGE" ]; then
    EXTRA_MG_ARGS="${EXTRA_MG_ARGS} ${MUST_GATHER_IMAGE}"
fi
VOLUME_PERCENTAGE_FLAG=""
if oc adm must-gather --help 2>&1 | grep -q -- '--volume-percentage'; then
   VOLUME_PERCENTAGE_FLAG="--volume-percentage=100"
fi
oc --insecure-skip-tls-verify adm must-gather $VOLUME_PERCENTAGE_FLAG --timeout="$MUST_GATHER_TIMEOUT" --dest-dir "${ARTIFACT_DIR}/must-gather" ${EXTRA_MG_ARGS} > "${ARTIFACT_DIR}/must-gather/must-gather.log"

# Sanitize MCO resources to remove sensitive information.
# If the sanitizer fails, fall back to manual redaction.
if ! /tmp/mco-sanitize --input="${ARTIFACT_DIR}/must-gather"; then
  find "${ARTIFACT_DIR}/must-gather" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "$1" && mv "$1" "$1.redacted"' _ {} \;
fi                                                                                                                     

[ -f "${ARTIFACT_DIR}/must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
installCamgi
/tmp/camgi "${ARTIFACT_DIR}/must-gather" > "${ARTIFACT_DIR}/must-gather/camgi.html"
[ -f "${ARTIFACT_DIR}/must-gather/camgi.html" ] && cp "${ARTIFACT_DIR}/must-gather/camgi.html" "${ARTIFACT_DIR}/camgi.html"
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather
set +x # stop logging commands

cat >> ${SHARED_DIR}/custom-links.txt << EOF
<script>
let kaas = document.createElement('a');
kaas.href="https://kaas.dptools.openshift.org/?search="+document.referrer;
  kaas.title="KaaS is a service to spawn a fake API service that parses must-gather data. As a result, users can pass Prow CI URL to the service, fetch generated kubeconfig and use kubectl/oc/k9s/openshift-console to investigate the state of the cluster at the time must-gather was collected. Note, on Chromium-based browsers you'll need to fill-in the Prow URL manually. Security settings prevent getting the referrer automatically."
kaas.innerHTML="KaaS";
kaas.target="_blank";
document.getElementById("wrapper").append(kaas);
</script>
EOF
