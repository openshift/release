#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function mirror_test_images() {
        echo "### Mirroring test images"

        DEVSCRIPTS_TEST_IMAGE_REPO=${DS_REGISTRY}/localimages/local-test-image
        
        openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} > /tmp/mirror
        scp "${SSHOPTS[@]}" /tmp/mirror "root@${IP}:/tmp/mirror"

        # shellcheck disable=SC2087
        ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
oc image mirror -f /tmp/mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json
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
      ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
MIRRORED_RELEASE_IMAGE=${DS_REGISTRY}/localimages/local-release-image
DIGEST=\$(oc adm release info --registry-config ${DS_WORKING_DIR}/pull_secret.json ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE} --output=jsonpath="{.digest}")
echo "Mirroring release images for disconnected environment"
oc adm release mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --from=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE} --to=\${MIRRORED_RELEASE_IMAGE} --apply-release-image-signature
echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=\${MIRRORED_RELEASE_IMAGE}@\${DIGEST}" >> /tmp/disconnected_mirror.conf
EOF

      # shellcheck source=/dev/null
      source <(ssh "${SSHOPTS[@]}" "root@${IP}" "cat /tmp/disconnected_mirror.conf")
      echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is overridden to ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"

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

case "${CLUSTER_TYPE}" in
packet)
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

        # Skipping proxy related tests ([Skipped:Proxy]) is supported only for version  greater than or equal to 4.10
        # For lower versions they must be skipped manually
        if ! is_openshift_version_gte "4.10"; then
            TEST_SKIPS="${TEST_SKIPS}
${TEST_SKIPS_PROXY}"
        fi
    else
        export TEST_PROVIDER='{"type":"skeleton"}'
        use_minimal_test_list
    fi
    ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"; exit 1;;
esac

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
    if [[ -n "${TEST_SKIPS}" ]]; then       
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
    echo "$(date) - node count ($NODECOUNT) now matches or exceeds machine count ($MACHINECOUNT)"
    break
  fi
  echo "$(date) - $MACHINECOUNT Machines - $NODECOUNT Nodes"
  sleep 30
  ((i++))
  if [ $i -gt 20 ]; then
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
  non_imported_imagestreams=$(oc -n openshift get is -o go-template='{{range .items}}{{$namespace := .metadata.namespace}}{{$name := .metadata.name}}{{range .status.tags}}{{if not .items}}{{$namespace}}/{{$name}}:{{.tag}}{{"\n"}}{{end}}{{end}}{{end}}')
  if [ -z "${non_imported_imagestreams}" ]
  then
    break
  fi
  echo "The following image streams are yet to be imported (attempt #${count}):"
  echo "${non_imported_imagestreams}"

  count=$((count+1))
  if (( count > 20 )); then
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
