#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Debug artifact generation" > ${ARTIFACT_DIR}/dummy.log

function mirror_test_images() {
        echo "### Mirroring test images"

        DEVSCRIPTS_TEST_IMAGE_REPO=${DS_REGISTRY}/localimages/local-test-image

        openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} > /tmp/mirror
        scp "${SSHOPTS[@]}" /tmp/mirror "root@${IP}:/tmp/mirror"

        # shellcheck disable=SC2087
        ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
oc image mirror -f /tmp/mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json
# "registry.k8s.io/pause:3.8" is excluded from the output of the "openshift-tests images" command as some of the layers arn't compressed and this isn't supported by quay.io
# So we need to mirror it from source bypassing quay.io
# TODO: remove when registry.k8s.io/pause:3.8 is contained in /tmp/mirror
# https://issues.redhat.com/browse/OCPBUGS-3016
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --filter-by-os="linux/${ARCHITECTURE}.*" registry.k8s.io/pause:3.8  $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-28-registry-k8s-io-pause-3-8-aP7uYsw5XCmoDy5W
# until we land k8s 1.28 we need to mirror both the 3.8 (current image) and 3.9 (coming in k8s 1.28)
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --filter-by-os="linux/${ARCHITECTURE}.*" registry.k8s.io/pause:3.9  $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-27-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
# after recent updates to images, we need to also mirror the new location of the image as well
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --filter-by-os="linux/${ARCHITECTURE}.*" registry.k8s.io/pause:3.9  $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-28-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
# new image coming in k8s 1.31
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --filter-by-os="linux/${ARCHITECTURE}.*" registry.k8s.io/pause:3.10 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-27-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
EOF
        TEST_ARGS="--from-repository ${DEVSCRIPTS_TEST_IMAGE_REPO}"
}

function use_minimal_test_list() {
        echo "### Skipping test images mirroring, fall back to minimal tests list"

        TEST_ARGS="--file /tmp/tests"
        TEST_SKIPS=""
        echo "${TEST_MINIMAL_LIST}" > /tmp/tests
}

function set_test_provider() {
    # Currently all v6 deployments are disconnected, so we have to tell
    # openshift-tests to exclude those tests that require internet
    # access.
    if [[ "${DS_IP_STACK}" != "v6" ]];
    then
        export TEST_PROVIDER='{"type":"baremetal"}'
    else
        export TEST_PROVIDER='{"type":"baremetal","disconnected":true}'
    fi
}

function mirror_release_image_for_disconnected_upgrade() {
    # All IPv6 clusters are disconnected and
    # release image should be mirrored for upgrades.
    if [[ "${DS_IP_STACK}" == "v6" ]]; then
      # shellcheck disable=SC2087
      ssh "${SSHOPTS[@]}" "root@${IP}" bash -x - << EOF
MIRRORED_RELEASE_IMAGE=${DS_REGISTRY}/localimages/local-upgrade-image
DIGEST=\$(oc adm release info --registry-config ${DS_WORKING_DIR}/pull_secret.json ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE} --output=jsonpath="{.digest}")
RELEASE_TAG=\$(sed -e "s/^sha256://" <<< \${DIGEST})
MIRROR_RESULT_LOG=/tmp/image_mirror-\${RELEASE_TAG}.log

MIRRORCOMMAND="oc adm release mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json \
  --from=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE} \
  --to=\${MIRRORED_RELEASE_IMAGE} \
  --to-release-image=\${MIRRORED_RELEASE_IMAGE}:\${RELEASE_TAG}"

# We run this first in dry-mode to get the ImageContentSourcePolicy and apply it early
# So we don't have to wait as long for the machine-config to be applied after we do the mirroring
\$MIRRORCOMMAND --dry-run 2>&1 | tee \${MIRROR_RESULT_LOG}

echo "Create ImageContentSourcePolicy to use mirrored registry in upgrade"
UPGRADE_ICS=\$(cat \${MIRROR_RESULT_LOG} | sed -n '/repositoryDigestMirrors/,//p')

cat <<EOF1 | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: disconnected-upgrade-ics
spec:
\${UPGRADE_ICS}
EOF1

echo "Mirroring release images for disconnected environment"
\$MIRRORCOMMAND

echo "Waiting for the new ImageContentSourcePolicy to be updated on machines"
oc wait clusteroperators/machine-config --for=condition=Upgradeable=true --timeout=15m

EOF

      TEST_UPGRADE_ARGS="--from-repository ${DS_REGISTRY}/localimages/local-test-image"
    fi
}

function setup_proxy() {
    # For disconnected or otherwise unreachable environments, we want to
    # have steps use an HTTP(S) proxy to reach the API server. This proxy
    # configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
    # environment variables, as well as their lowercase equivalents (note
    # that libcurl doesn't recognize the uppercase variables).
    if test -f "${SHARED_DIR}/proxy-conf.sh"
    then
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

function is_openshift_version_gte() {
    printf '%s\n%s' "$1" "${DS_OPENSHIFT_VERSION}" | sort -C -V
}

function upgrade() {
    mirror_release_image_for_disconnected_upgrade
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --provider "${TEST_PROVIDER:-}" \
        ${TEST_UPGRADE_ARGS:-} \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

function suite() {
    if [[ -n "${TEST_SKIPS}" && "${TEST_SUITE}" == "openshift/conformance/parallel" ]]; then
        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")" &&
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
        echo "Skipping tests:" &&
        echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; } &&
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
        scp "${SSHOPTS[@]}" /tmp/tests "root@${IP}:/tmp/tests"
    fi

    set -x
    openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
        --provider "${TEST_PROVIDER:-}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    set +x
}

# wait for all clusteroperators to reach progressing=false to ensure that we achieved the configuration specified at installation
# time before we run our e2e tests.
function check_clusteroperators_status() {
    echo "$(date) - waiting for clusteroperators to finish progressing..."
    oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
    echo "$(date) - all clusteroperators are done progressing."
}

case "${CLUSTER_TYPE}" in
packet|equinix*)
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/ds-vars.conf"

    setup_proxy
    export KUBECONFIG=${SHARED_DIR}/kubeconfig

    echo "### Checking release version"
    if is_openshift_version_gte "4.8"; then
        # Set test provider for only versions greater than or equal to 4.8
        set_test_provider

        # Mirroring test images is supported only for versions greater than or equal to 4.8
        mirror_test_images
    else
        export TEST_PROVIDER='{"type":"skeleton"}'
        use_minimal_test_list
    fi
    ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

oc -n openshift-config patch cm admin-acks --patch '{"data":{"ack-4.8-kube-1.22-api-removals-in-4.9":"true"}}' --type=merge || echo 'failed to ack the 4.9 Kube v1beta1 removals; possibly API-server issue, or a pre-4.8 release image'

# wait for ClusterVersion to level, until https://bugzilla.redhat.com/show_bug.cgi?id=2009845 makes it back to all 4.9 releases being installed in CI
oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version

check_clusteroperators_status

# wait up to 10m for the number of nodes to match the number of machines
i=0
while true
do
  MACHINECOUNT="$(kubectl get machines -A --no-headers | wc -l)"
  NODECOUNT="$(kubectl get nodes --no-headers | wc -l)"
  if [ "${MACHINECOUNT}" -le "${NODECOUNT}" ]
  then
    cat >"${ARTIFACT_DIR}/junit_nodes.xml" <<EOF
    <testsuite name="cluster nodes" tests="1" failures="0">
      <testcase name="node count should match or exceed machine count"/>
    </testsuite>
EOF
    echo "$(date) - node count ($NODECOUNT) now matches or exceeds machine count ($MACHINECOUNT)"
    break
  fi
  echo "$(date) - $MACHINECOUNT Machines - $NODECOUNT Nodes"
  sleep 30
  i=$((i+1))
  if [ $i -gt 20 ]; then
    MACHINELIST="$(kubectl get machines -A)"
    NODELIST="$(kubectl get nodes)"
    cat >"${ARTIFACT_DIR}/junit_nodes.xml" <<EOF
    <testsuite name="cluster nodes" tests="1" failures="1">
      <testcase name="node count should match or exceed machine count">
        <failure message="">
          Timed out waiting for node count ($NODECOUNT) to equal or exceed machine count ($MACHINECOUNT).
          $MACHINELIST
          $NODELIST
        </failure>
      </testcase>
    </testsuite>
EOF
    echo "Timed out waiting for node count ($NODECOUNT) to equal or exceed machine count ($MACHINECOUNT)."
    exit 1
  fi
done

# wait for all nodes to reach Ready=true to ensure that all machines and nodes came up, before we run
# any e2e tests that might require specific workload capacity.
echo "$(date) - waiting for nodes to be ready..."
oc wait nodes --all --for=condition=Ready=true --timeout=10m
echo "$(date) - all nodes are ready"

# this works around a problem where tests fail because imagestreams aren't imported.  We see this happen for exec session.
echo "$(date) - waiting for non-samples imagesteams to import..."
count=0
while :
do

  # The local image registry isn't working in 4.6 and isn't needed for the
  # subset of tests we use for this version
  if ! is_openshift_version_gte "4.7" ; then
    echo "Skipping imagesteams wait"
    break
  fi

  non_imported_imagestreams=$(oc -n openshift get imagestreams -o go-template='{{range .items}}{{$namespace := .metadata.namespace}}{{$name := .metadata.name}}{{range .status.tags}}{{if not .items}}{{$namespace}}/{{$name}}:{{.tag}}{{"\n"}}{{end}}{{end}}{{end}}')
  if [ -z "${non_imported_imagestreams}" ]
  then
    break
  fi
  echo "The following image streams are yet to be imported (attempt #${count}):"
  echo "${non_imported_imagestreams}"

  count=$((count+1))
  if (( count > 30 )); then
    echo "Failed while waiting on imagestream import"
    exit 1
  fi

  sleep 60
done
echo "$(date) - all imagestreams are imported."

# In some cases the cluster events are processed slowly by the kube-apiservers,
# producing a late revision updates that could be missed by the previous co check.
echo "$(date) - Waiting 10 minutes before checking again clusteroperators"
sleep 10m

check_clusteroperators_status

case "${TEST_TYPE}" in
upgrade-conformance)
    upgrade
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
upgrade)
    upgrade
    ;;
suite-conformance)
    suite
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
