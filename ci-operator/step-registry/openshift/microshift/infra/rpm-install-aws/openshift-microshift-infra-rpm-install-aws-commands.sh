#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_RPM_INSTALL_FAILURE

cat << EOF > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
telemetry:
  status: Disabled
EOF

configure_vm_args=""
if "${OPTIONAL_RPMS}"; then
  configure_vm_args="--optional-rpms"

  # install all the optional RPMs except those specified in ${SKIPPED_OPTIONAL_RPMS}
  if [ -n "${SKIPPED_OPTIONAL_RPMS}" ]; then
    configure_vm_args="${configure_vm_args} --skip-optional-rpms ${SKIPPED_OPTIONAL_RPMS}"
  fi
fi

cat <<EOF > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register

sudo mkdir -p /etc/microshift
sudo mv /tmp/config.yaml /etc/microshift/config.yaml
if [[ "${JOB_NAME_SAFE}" =~ .*ocp-conformance-optional.* ]]; then
  # Increase pull QPS for conformance with optional RPMs
  sudo mkdir -p /etc/microshift/config.d/
  sudo tee /etc/microshift/config.d/kubelet-qps.yaml >/dev/null <<2EOF2
kubelet:
  registryPullQPS: 10

2EOF2
fi
tar -xf /tmp/microshift.tgz -C ~ --strip-components 4
cd ~/microshift

# Check if --skip-dnf-update is available
SKIP_DNF_UPDATE_OPT=""
if grep -q -- '--skip-dnf-update' ./scripts/devenv-builder/configure-vm.sh; then
  SKIP_DNF_UPDATE_OPT="--skip-dnf-update"
fi

./scripts/devenv-builder/configure-vm.sh \${SKIP_DNF_UPDATE_OPT} --force-firewall --pull-images ${configure_vm_args} /tmp/pull-secret
EOF
chmod +x /tmp/install.sh

ci_clone_src "${SRC_FROM_GIT}"

REBASE_TO=""
# RELEASE_IMAGE_LATEST is always set by the release-controller, whether this is
# a payload job, a periodic, or a presubmit. In order to distinguish between
# payload/not payload, we inspect the prow job id, which includes the word "nightly"
# among the version and the date for the promotion candidate if its a payload test
# and a UUID otherwise.
# Should we find any errors, we simply proceed without rebasing.
PROWJOB_ID=$(echo "${JOB_SPEC}" | jq -r '.prowjobid // empty')
if [[ -n "${PROWJOB_ID}" && "${PROWJOB_ID}" =~ .*nightly.* ]]; then

  REBASE_TO="${RELEASE_IMAGE_LATEST}"
fi

if [ -n "${REBASE_TO}" ]; then
  # Under this condition we need to force traps at the last moment to not override the one above.
  echo "REBASE_TO is set to ${REBASE_TO}"
  export PATH="${HOME}/.local/bin:${PATH}"
  python3 -m ensurepip --upgrade
  pip3 install setuptools-rust cryptography pyyaml pygithub gitpython

  cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/.pull-secret.json

  cd /go/src/github.com/openshift/microshift/
  DEST_DIR="${HOME}"/.local/bin ./scripts/fetch_tools.sh yq

  # Get the ARM64 release tag from the imported image
  # The internal pullspec differs from the external one, so we extract the tag and rebuild it
  oc registry login --to=/tmp/registry.json
  ARM64_TAG=$(oc image info --registry-config=/tmp/registry.json "${OPENSHIFT_RELEASE_IMAGE_ARM}" -o json | jq -r '.config.config.Labels."io.openshift.release" // empty')
  if [[ -z "${ARM64_TAG}" ]]; then
    echo "Failed to extract ARM64 release tag from image: ${OPENSHIFT_RELEASE_IMAGE_ARM}"
    trap_install_status_exit_code "$EXIT_CODE_REBASE_FAILURE"
    exit 1
  fi

  # Derive the ARM64 pullspec from the AMD64 one (REBASE_TO)
  # Transform: release -> release-arm64
  BASE_IMAGE=$(echo "${REBASE_TO}" | cut -d: -f1)
  REGISTRY=$(echo "${BASE_IMAGE}" | cut -d/ -f1)
  NAMESPACE=$(echo "${BASE_IMAGE}" | cut -d/ -f2)
  IMAGE=$(echo "${BASE_IMAGE}" | cut -d/ -f3)
  ARM_RELEASE_IMAGE="${REGISTRY}/${NAMESPACE}-arm64/${IMAGE}-arm64:${ARM64_TAG}"
  echo "ARM64 release image: ${ARM_RELEASE_IMAGE}"
  # Bail out without error if the rebase fails. Next steps should be skipped if this happens.
  PULLSPEC_RELEASE_AMD64="${REBASE_TO}" \
  PULLSPEC_RELEASE_ARM64="${ARM_RELEASE_IMAGE}" \
  DRY_RUN=y \
  ./scripts/auto-rebase/rebase_job_entrypoint.sh || {
    echo "Rebase failed"
    trap_install_status_exit_code "$EXIT_CODE_REBASE_FAILURE"
    exit 1
  }
else
  echo "REBASE_TO is not set, skipping rebase"
fi

tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
  "${SHARED_DIR}/ci-functions.sh" \
  /tmp/install.sh \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  /tmp/microshift.tgz \
  /tmp/config.yaml \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/install.sh"
