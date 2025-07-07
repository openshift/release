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
./scripts/devenv-builder/configure-vm.sh --force-firewall --pull-images ${configure_vm_args} /tmp/pull-secret
EOF
chmod +x /tmp/install.sh

if "${SRC_FROM_GIT}"; then
  branch=$(echo ${JOB_SPEC} | jq -r '.refs.base_ref')
  # MicroShift repo is recent enough to use main instead of master.
  if [ "${branch}" == "master" ]; then
    branch="main"
  fi
  CLONEREFS_OPTIONS=$(jq -n --arg branch "${branch}" '{
    "src_root": "/go",
    "log":"/dev/null",
    "git_user_name": "ci-robot",
    "git_user_email": "ci-robot@openshift.io",
    "fail": true,
    "refs": [
      {
        "org": "openshift",
        "repo": "microshift",
        "base_ref": $branch,
        "workdir": true
      }
    ]
  }')
  export CLONEREFS_OPTIONS
fi
ci_clone_src

# Track whether rebase succeeded
REBASE_SUCCEEDED=false

# RELEASE_IMAGE_INITIAL is set in the job spec for payload testing. This
# variable holds the pullspec of the release image. If it is present this means
# we need to perform a rebase and then proceed with tests.
if [[ -n "${RELEASE_IMAGE_INITIAL:-}" ]]; then
  export PATH="${HOME}/.local/bin:${PATH}"
  python3 -m ensurepip --upgrade
  pip3 install setuptools-rust cryptography pyyaml pygithub gitpython

  cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/.pull-secret.json

  cd /go/src/github.com/openshift/microshift/
  DEST_DIR="${HOME}"/.local/bin ./scripts/fetch_tools.sh yq
  # Extract the ARM release image from the last_rebase.sh file (third parameter)
  ARM_RELEASE_IMAGE=$(grep -o 'registry\.ci\.openshift\.org/ocp-arm64/release-arm64:[^[:space:]]*' /go/src/github.com/openshift/microshift/scripts/auto-rebase/last_rebase.sh | head -1)
  if [[ -z "${ARM_RELEASE_IMAGE}" ]]; then
    echo "Failed to extract ARM release image from last_rebase.sh"
    exit 1
  fi
  # Bail out without error if the rebase fails. Next steps should be skipped if this happens.
  PULLSPEC_RELEASE_AMD64="${RELEASE_IMAGE_INITIAL}" \
    PULLSPEC_RELEASE_ARM64="${ARM_RELEASE_IMAGE}" \
    DRY_RUN=y \
    ./scripts/auto-rebase/rebase_job_entrypoint.sh || { echo "rebase failed" > "${SHARED_DIR}"/rebase_failure; exit 0; }
  REBASE_SUCCEEDED=true
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

ssh "${INSTANCE_PREFIX}" "/tmp/install.sh" || {
  # If the rebase succeeded but the build fails we also need to skip next steps
  # as it could be that the rebase needs manual intervention.
  if [[ "${REBASE_SUCCEEDED}" == "true" ]]; then
    echo "build failed after successful rebase" > "${SHARED_DIR}"/rebase_failure
    exit 0
  fi
  exit 1
}
