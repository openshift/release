#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds test command ************"

if [ "${SKIP_E2E_TEST:-}" = "true" ]; then
  echo "Skip e2e testing"
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

collect_artifacts() {
    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT TERM

# Copy test binaries on packet server
echo "### Copying test binaries"
scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"

# Tests execution
set +e

# Mirroring test images is supported only for versions greater than or equal to 4.7
# In such case the dev-scripts private reigstry is reused for mirroring the images.
# Current openshift version is detected through dev-scripts
# shellcheck disable=SC2046
read -d '' OPENSHIFT_VERSION DEVSCRIPTS_REGISTRY DEVSCRIPTS_WORKING_DIR <<<$(ssh "${SSHOPTS[@]}" "root@${IP}" "set +x; source /root/dev-scripts/common.sh; source /root/dev-scripts/ocp_install_env.sh; cd /root/dev-scripts; echo \$(openshift_version); echo \$LOCAL_REGISTRY_DNS_NAME:\$LOCAL_REGISTRY_PORT; echo \$WORKING_DIR")

TEST_ARGS=""
if printf '%s\n%s' "4.7" "${OPENSHIFT_VERSION}" | sort -C -V; then
  echo "### Mirroring test images"

  DEVSCRIPTS_TEST_IMAGE_REPO=${DEVSCRIPTS_REGISTRY}/localimages/local-test-image  
  # shellcheck disable=SC2087
  ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set +x

source /root/dev-scripts/common.sh
source /root/dev-scripts/ocp_install_env.sh

openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} > /tmp/mirror
oc image mirror -f /tmp/mirror --registry-config ${DEVSCRIPTS_WORKING_DIR}/pull_secret.json
EOF

  TEST_ARGS="--from-repository ${DEVSCRIPTS_TEST_IMAGE_REPO}"

  echo "### Enriching test-list cases"
  cat "${SHARED_DIR}/test-list-ext" >> "${SHARED_DIR}/test-list"
fi

# Test upgrade for workflows that requested it
if [[ "$RUN_UPGRADE_TEST" == true ]]; then
    echo "### Running Upgrade tests"
    timeout \
    --kill-after 10m \
    120m \
        ssh \
            "${SSHOPTS[@]}" \
            "root@${IP}" \
            openshift-tests \
            run-upgrade \
            ${TEST_ARGS} \
            --to-image "$OPENSHIFT_UPGRADE_RELEASE_IMAGE" \
            -o /tmp/artifacts/e2e-upgrade.log \
            --junit-dir /tmp/artifacts/junit-upgrade \
            platform
else
    if [[ -s "${SHARED_DIR}/test-list" ]]; then
        echo "### Copying test-list file"
        scp \
            "${SSHOPTS[@]}" \
            "${SHARED_DIR}/test-list" \
            "root@${IP}:/tmp/test-list"
        echo "### Running tests"
        timeout \
        --kill-after 10m \
        120m \
        ssh \
            "${SSHOPTS[@]}" \
            "root@${IP}" \
            openshift-tests \
            run \
            "openshift/conformance" \
            --dry-run \
            \| grep -Ff /tmp/test-list \|openshift-tests run ${TEST_ARGS} -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
    else
        echo "### Running tests"
        ssh \
            "${SSHOPTS[@]}" \
            "root@${IP}" \
            openshift-tests \
            run \
            "openshift/conformance/parallel" \
            --dry-run \
            \| grep 'Feature:ProjectAPI' \| openshift-tests run ${TEST_ARGS} -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
    fi
fi

rv=$?

set -e
echo "### Done! (${rv})"
exit $rv
