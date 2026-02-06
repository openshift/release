#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Debug artifact generation" > ${ARTIFACT_DIR}/dummy.log

# In order for openshift-tests to pull external binary images from the
# payload, we need access enabled to the images on the build farm. In
# order to do that, we need to unset the KUBECONFIG so we talk to the
# build farm, not the cluster under test.
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

echo "shared directory: ${SHARED_DIR}"
HYPERVISOR_IP=$(cat "${SHARED_DIR}/server-ip")
export HYPERVISOR_IP
export HYPERVISOR_SSH_USER="root"

# Determine the correct SSH key path
# Using equinix-ssh-key for ARM64 hosts or packet-ssh-key for others
echo "cluster profile directory: ${CLUSTER_PROFILE_DIR}"
if [[ -f "${CLUSTER_PROFILE_DIR}/equinix-ssh-key" ]]; then
    export HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/equinix-ssh-key"
else
    export HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
fi


# Starting in 4.21, we will aggressively retry test failures only in
# presubmits to determine if a failure is a flake or legitimate. This is
# to reduce the number of retests on PR's.
if [[ "$JOB_TYPE" == "presubmit" && ( "$PULL_BASE_REF" == "main" || "$PULL_BASE_REF" == "master" ) ]]; then
    if openshift-tests run --help | grep -q 'retry-strategy'; then
        TEST_ARGS+=" --retry-strategy=aggressive"
    fi
fi

function run_mirror_test_images_ssh_commands() {
        # shellcheck disable=SC2087
        ssh "${SSHOPTS[@]}" "root@${IP}" bash -ux << EOF
set -o pipefail

MAX_RETRIES=3
CURRENT_RETRY=1
SUCCESS=false

# Array of pairs (from to)
declare -a MIRRORED_IMAGES=(
  # "registry.k8s.io/pause:3.8" is excluded from the output of the "openshift-tests images" command as some of the layers arn't compressed and this isn't supported by quay.io
  # So we need to mirror it from source bypassing quay.io
  # TODO: remove when registry.k8s.io/pause:3.8 is contained in /tmp/mirror
  # https://issues.redhat.com/browse/OCPBUGS-3016
  "registry.k8s.io/pause:3.8  $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-28-registry-k8s-io-pause-3-8-aP7uYsw5XCmoDy5W"
  # until we land k8s 1.28 we need to mirror both the 3.8 (current image) and 3.9 (coming in k8s 1.28)
  "registry.k8s.io/pause:3.9  $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-27-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk"
  # after recent updates to images, we need to also mirror the new location of the image as well
  "registry.k8s.io/pause:3.9  $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-28-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk"
  # new image coming in k8s 1.31
  "registry.k8s.io/pause:3.10 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-27-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY"
  # new image coming in k8s 1.31.12
  "registry.k8s.io/pause:3.10 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-26-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY"
  # new image coming in k8s 1.32
  "registry.k8s.io/pause:3.10 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-25-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY"
  # new image coming in k8s 1.33.4
  "registry.k8s.io/pause:3.10 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-24-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY"
  # new image coming in k8s 1.34.0
  "registry.k8s.io/pause:3.10.1 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-25-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z"
  # new image coming in k8s 1.29.11. This should be removed once k8s is bumped in openshift/origin too (or https://issues.redhat.com/browse/TRT-1942 is fixed)
  "registry.k8s.io/etcd:3.5.16-0 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-11-registry-k8s-io-etcd-3-5-16-0-ExW1ETJqOZa6gx2F"
  # new image coming in k8s 1.30.5. This should be removed once k8s is bumped in openshift/origin too (or https://issues.redhat.com/browse/TRT-1942 is fixed)
  "registry.k8s.io/etcd:3.5.15-0 $DEVSCRIPTS_TEST_IMAGE_REPO:e2e-11-registry-k8s-io-etcd-3-5-15-0-W7c5qq4cz4EE20EQ"
)

function run-oc-image-mirror() {
  oc image mirror -f /tmp/mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json || return 1
  for image_pair in "\${MIRRORED_IMAGES[@]}"; do
    oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --filter-by-os="linux/${ARCHITECTURE}.*" \$image_pair || return 1
  done
}

while [ \$SUCCESS = false ] && [ \$CURRENT_RETRY -le \$MAX_RETRIES ]; do
  echo "Mirroring test images tentative \$CURRENT_RETRY"
  run-oc-image-mirror
  if [ \$? -eq 0 ]; then
      SUCCESS=true
    else
      echo "Mirroring test images tentative \$CURRENT_RETRY failed. Trying again..."
      CURRENT_RETRY=\$(( CURRENT_RETRY + 1 ))
      sleep 5
    fi
  done
  if [ \$SUCCESS = true ]; then
    echo "Mirroring test images was successful after \$CURRENT_RETRY attempts."
  else
    echo "Mirroring test images failed after \$MAX_RETRIES attempts."
    exit 1
  fi
EOF
}

function mirror_test_images() {
        echo "### Mirroring test images"

        DEVSCRIPTS_TEST_IMAGE_REPO=${DS_REGISTRY}/localimages/local-test-image

        openshift-tests images --to-repository ${DEVSCRIPTS_TEST_IMAGE_REPO} | grep ${DEVSCRIPTS_TEST_IMAGE_REPO}  > /tmp/mirror
        scp "${SSHOPTS[@]}" /tmp/mirror "root@${IP}:/tmp/mirror"

        MIRROR_RESULT=$(run_mirror_test_images_ssh_commands || echo "fail")

        JUNIT_IMAGE_FILE="$ARTIFACT_DIR/junit_image-mirroring.xml"

        if [[ "$MIRROR_RESULT" == "fail" ]]; then
            cat > "$JUNIT_IMAGE_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="Image Mirroring" tests="1" failures="1">
    <testcase name="[sig-metal] release payload images should be mirrored successfully">
        <failure message="Image mirroring failed"></failure>
    </testcase>
</testsuite>
EOF
            echo "JUnit failing result written to ${JUNIT_IMAGE_FILE}"
            exit 1
        else
            cat > "$JUNIT_IMAGE_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="Image Mirroring" tests="1" failures="0">
    <testcase name="[sig-metal] release payload images should be mirrored successfully">
    </testcase>
</testsuite>
EOF
            echo "JUnit result written to ${JUNIT_IMAGE_FILE}"
        fi

        TEST_ARGS="${TEST_ARGS:-} --from-repository ${DEVSCRIPTS_TEST_IMAGE_REPO}"
}

function use_minimal_test_list() {
        echo "### Skipping test images mirroring, fall back to minimal tests list"

        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
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

function run_mirror_release_image_for_disconnected_upgrade_ssh_commands() {
  # shellcheck disable=SC2087
      ssh "${SSHOPTS[@]}" "root@${IP}" bash -ux - << EOF
set -o pipefail

MIRRORED_RELEASE_IMAGE=${DS_REGISTRY}/localimages/local-upgrade-image
DIGEST=\$(oc adm release info --registry-config ${DS_WORKING_DIR}/pull_secret.json ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE} --output=jsonpath="{.digest}")
RELEASE_TAG=\$(sed -e "s/^sha256://" <<< \${DIGEST})
MIRROR_RESULT_LOG=/tmp/image_mirror-\${RELEASE_TAG}.log

MIRRORCOMMAND="oc adm release mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json \
  --keep-manifest-list \
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

#Retry logic for the real release mirror command
MAX_RETRIES=3
CURRENT_RETRY=1
SUCCESS=false
while [ \$SUCCESS = false ] && [ \$CURRENT_RETRY -le \$MAX_RETRIES ]; do
  echo "Mirroring release images for disconnected environment tentative \$CURRENT_RETRY"
  \$MIRRORCOMMAND
  if [ \$? -eq 0 ]; then
    SUCCESS=true
  else
    echo "Mirroring release images for disconnected environment tentative \$CURRENT_RETRY failed. Trying again..."
    CURRENT_RETRY=\$(( CURRENT_RETRY + 1 ))
    sleep 5
  fi
done

if [ \$SUCCESS = true ]; then
  echo "Mirroring release images for disconnected environment was successful after \$CURRENT_RETRY attempts."
else
  echo "Mirroring release images for disconnected environment failed after \$MAX_RETRIES attempts."
  exit 1
fi

EOF
}

function mirror_release_image_for_disconnected_upgrade() {
    # All IPv6 clusters are disconnected and
    # release image should be mirrored for upgrades.
    if [[ "${DS_IP_STACK}" == "v6" ]]; then
      echo "### Mirroring release images for disconnected upgrade ###"

      MIRROR_RESULT=$(run_mirror_release_image_for_disconnected_upgrade_ssh_commands || echo "fail")

      JUNIT_IMAGE_FILE="$ARTIFACT_DIR/junit_image-mirroring-disconnected-upgrade.xml"

        if [[ "$MIRROR_RESULT" == "fail" ]]; then
            cat > "$JUNIT_IMAGE_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="Image Mirroring for Disconnected Upgrade" tests="1" failures="1">
    <testcase name="[sig-metal] release payload images should be mirrored successfully for disconnected upgrade">
        <failure message="Image mirroring for Disconnected Upgrade failed"></failure>
    </testcase>
</testsuite>
EOF
            echo "JUnit failing result written to ${JUNIT_IMAGE_FILE}"
            exit 1
        else
            cat > "$JUNIT_IMAGE_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="Image Mirroring for Disconnected Upgrade" tests="1" failures="0">
    <testcase name="[sig-metal] release payload images should be mirrored successfully for disconnected upgrade">
    </testcase>
</testsuite>
EOF
            echo "JUnit result written to $JUNIT_IMAGE_FILE"
        fi

        echo "Waiting for the new ImageContentSourcePolicy to be updated on machines"
        oc wait clusteroperators/machine-config --for=condition=Upgradeable=true --timeout=15m

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

function build_hypervisor_config() {
    # Build hypervisor SSH configuration for tests that need to interact with the hypervisor.
    # This is also required for tests to interact with VM hosted on the hypervisor.
    if [[ ! -f "${SHARED_DIR}/server-ip" ]]; then
        echo "Warning: Hypervisor IP file ${SHARED_DIR}/server-ip not found"
        return
    fi

    HYPERVISOR_IP=$(cat "${SHARED_DIR}/server-ip")
    export HYPERVISOR_IP
    export HYPERVISOR_SSH_USER="root"

    # Determine the correct SSH key path
    # Using equinix-ssh-key for ARM64 hosts or packet-ssh-key for others
    if [[ -f "${CLUSTER_PROFILE_DIR}/equinix-ssh-key" ]]; then
        export HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/equinix-ssh-key"
    else
        export HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
    fi

    if [[ ! -f "${HYPERVISOR_SSH_KEY}" ]]; then
        echo "Warning: SSH key not found at ${HYPERVISOR_SSH_KEY}"
        unset HYPERVISOR_IP HYPERVISOR_SSH_USER HYPERVISOR_SSH_KEY
        return
    fi

    echo "Hypervisor SSH configuration: IP=${HYPERVISOR_IP}, User=${HYPERVISOR_SSH_USER}, Key=${HYPERVISOR_SSH_KEY}"
}

function build_hypervisor_vm_config() {
  build_hypervisor_config

  if [[ ! -f "${SHARED_DIR}/vm-ip" ]]; then
      echo "Warning: Hypervisor VM IP file ${SHARED_DIR}/vm-ip not found"
      return
  fi

  VM_IP=$(cat "${SHARED_DIR}/vm-ip")
  export VM_IP

  if [[ ! -f "${SHARED_DIR}/vm-private-key" ]]; then
    echo "WARNING: ${SHARED_DIR}/vm-private-key file not found"
    return
  fi

  if [[ ! -f "${SHARED_DIR}/vm-public-key" ]]; then
    echo "WARNING: ${SHARED_DIR}/vm-public-key file not found"
    return
  fi

    # Prepare SSH configuration directory
    mkdir -p ~/.ssh

    # Setup ssh keys.
    cp "${HYPERVISOR_SSH_KEY}" ~/.ssh/hypervisor-ssh-key
    chmod 600 ~/.ssh/hypervisor-ssh-key
    cp "${SHARED_DIR}/vm-private-key" ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    cp "${SHARED_DIR}/vm-public-key" ~/.ssh/id_ed25519.pub
    chmod 644 ~/.ssh/id_ed25519.pub

    # Configure SSH client - use the copied key with correct permissions
    cat > ~/.ssh/config <<EOF
Host hypervisor
    HostName ${HYPERVISOR_IP}
    User root
    ServerAliveInterval 120
    IdentityFile ~/.ssh/hypervisor-ssh-key

Host 192.168.122.*
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyCommand ssh -W %h:%p hypervisor
EOF
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

function suite_in_container() {
    # Setup SSHOPTS for remote server access using the mounted SSH key
    SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "${HYPERVISOR_SSH_KEY}")

    mkdir -p ~/.ssh
    mkdir -p ~/.kcli

    cat >> ~/.ssh/config <<EOF
Host hypervisor
    HostName ${IP}
    User root
    ServerAliveInterval 120
    IdentityFile ${HYPERVISOR_SSH_KEY}
EOF

    cat >> ~/.kcli/config.yml <<EOF
twix:
  host: hypervisor
  pool: default
  protocol: ssh
  type: kvm
  user: root
EOF

    echo "Connect kcli with remote hypervisor"
    kcli switch host twix

    echo "Ensuring clean state for VM creation"
    kcli delete vm ovn-kubernetes-e2e -y 2>/dev/null || true

    echo "Creating test VM with Docker"
    kcli create vm -i fedora42 ovn-kubernetes-e2e --wait -P "cmds=['dnf install -y docker','systemctl enable --now docker']"

    echo "Verifying Docker installation in VM"
    if ! kcli ssh ovn-kubernetes-e2e -- sudo docker version; then
      echo "ERROR: Docker installation failed in VM"
      exit 1
    fi

    if [[ -n "${TEST_SKIPS}" && ("${TEST_SUITE}" == "openshift/conformance/parallel" || "${TEST_SUITE}" == "openshift/auth/external-oidc") ]]; then
        TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")" &&
        echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
        echo "Skipping tests:" &&
        echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; } &&
        TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
        scp "${SSHOPTS[@]}" /tmp/tests "root@${IP}:/tmp/tests"
    fi

    set -x
    if [[ "${ENABLE_HYPERVISOR_SSH_CONFIG:-false}" == "true" ]]; then
        openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
            --provider "${TEST_PROVIDER:-}" \
            --with-hypervisor-json="{\"hypervisorIP\":\"${HYPERVISOR_IP}\", \"sshUser\":\"${HYPERVISOR_SSH_USER}\", \"privateKeyPath\":\"${HYPERVISOR_SSH_KEY}\"}" \
            -o "${ARTIFACT_DIR}/e2e.log" \
            --junit-dir "${ARTIFACT_DIR}/junit"
    else
        openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
            --provider "${TEST_PROVIDER:-}" \
            -o "${ARTIFACT_DIR}/e2e.log" \
            --junit-dir "${ARTIFACT_DIR}/junit"
    fi
    set +x
}

function suite() {
    # Determine SSH key path (same logic as build_hypervisor_config)
    # Reuse HYPERVISOR_SSH_KEY if already set, otherwise determine it
    if [[ -z "${HYPERVISOR_SSH_KEY:-}" ]]; then
        if [[ -f "${CLUSTER_PROFILE_DIR}/equinix-ssh-key" ]]; then
            HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/equinix-ssh-key"
        else
            HYPERVISOR_SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
        fi
    fi

    # Locate openshift-tests binary in the current (outer) container
    OPENSHIFT_TESTS_BIN=$(which openshift-tests || true)
    if [[ -n "${OPENSHIFT_TESTS_BIN}" ]]; then
        echo "Found openshift-tests at: ${OPENSHIFT_TESTS_BIN}"
    else
        echo "Warning: openshift-tests binary not found in PATH, skipping mount"
    fi

    # Prepare podman volume mounts as array
    PODMAN_MOUNTS=(-v "${KUBECONFIG}:/tmp/kubeconfig:ro")
    PODMAN_MOUNTS+=(-v "${ARTIFACT_DIR}:/tmp/artifacts")
    PODMAN_MOUNTS+=(-v "${HYPERVISOR_SSH_KEY}:/tmp/ssh-key:ro")

    # Only mount openshift-tests if it was found
    if [[ -n "${OPENSHIFT_TESTS_BIN}" ]]; then
        PODMAN_MOUNTS+=(-v "${OPENSHIFT_TESTS_BIN}:/usr/bin/openshift-tests:ro")
    fi

    # Prepare environment variables to pass to container as array
    PODMAN_ENV=(-e "KUBECONFIG=/tmp/kubeconfig")
    PODMAN_ENV+=(-e "ARTIFACT_DIR=/tmp/artifacts")
    PODMAN_ENV+=(-e "TEST_SUITE=${TEST_SUITE}")
    PODMAN_ENV+=(-e "TEST_PROVIDER=${TEST_PROVIDER:-}")
    PODMAN_ENV+=(-e "TEST_ARGS=${TEST_ARGS:-}")
    PODMAN_ENV+=(-e "TEST_SKIPS=${TEST_SKIPS:-}")
    PODMAN_ENV+=(-e "IP=${IP}")
    PODMAN_ENV+=(-e "HYPERVISOR_SSH_KEY=/tmp/ssh-key")

    # Add hypervisor-specific configuration if enabled
    if [[ -n "${HYPERVISOR_IP:-}" ]]; then
        PODMAN_ENV+=(-e "HYPERVISOR_IP=${HYPERVISOR_IP}")
        PODMAN_ENV+=(-e "HYPERVISOR_SSH_USER=${HYPERVISOR_SSH_USER}")
    fi

    echo "PODMAN_MOUNTS: ${PODMAN_MOUNTS[*]}"
    echo "PODMAN_ENV: ${PODMAN_ENV[*]}"

    set -x
    podman run --network host --rm -i \
        "${PODMAN_ENV[@]}" \
        "${PODMAN_MOUNTS[@]}" \
        "quay.io/karmab/kcli" \
        bash -c "$(declare -f suite_in_container); suite_in_container"
    set +x
}

# wait for all clusteroperators to reach progressing=false to ensure that we achieved the configuration specified at installation
# time before we run our e2e tests.
function check_clusteroperators_status() {
    echo "$(date) - waiting for clusteroperators to finish progressing..."
    oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
    echo "$(date) - all clusteroperators are done progressing."
}

TEST_ARGS="${TEST_ARGS:-} ${SHARD_ARGS:-}"

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

# Skip readiness checks intentionally when the cluster is expected
# to be in an unhealthy state (e.g., TNF in degraded mode)
if [[ "${SKIP_READINESS_CHECKS:-false}" == "true" ]]; then
    echo "$(date) - skipping clusteroperators status check"
else
    check_clusteroperators_status
fi

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
if [[ "${SKIP_READINESS_CHECKS:-false}" == "true" ]]; then
  echo "$(date) - skipping node readiness check because SKIP_READINESS_CHECKS is set to true"
else
  echo "$(date) - waiting for nodes to be ready..."
  oc wait nodes --all --for=condition=Ready=true --timeout=10m
  echo "$(date) - all nodes are ready"
fi


# Check for image registry availability
for _ in {1..11}; do
  count=$(oc get configs.imageregistry.operator.openshift.io/cluster --no-headers | wc -l)
  echo "Image registry count: ${count}"
  if [[ ${count} -gt 0 ]]; then
    break
  fi
  sleep 30
done

# Check for imagestreams availability
for _ in {1..11}; do
  if ! oc get imagestreams --all-namespaces; then
    sleep 30
  else
    echo "$(date) - Imagestreams are available"
    break
  fi
done

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
if [[ "${SKIP_READINESS_CHECKS}" == "true" ]]; then
    echo "$(date) - skipping secondary clusteroperators status check"
else
  echo "$(date) - Waiting 10 minutes before checking again clusteroperators"
  sleep 10m

  check_clusteroperators_status
fi

# Build hypervisor and VM SSH configuration
build_hypervisor_vm_config

echo "sleep for 6h"
sleep 6h

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
