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

# >>> determine_rebase_to BEGIN (behavioral tests extract this block; keep it
# self-contained and side-effect free apart from stdout/stderr and the return
# code so hack/tests/openshift-microshift-infra-rpm-install-aws-commands_test.sh
# can source and exercise it directly).
#
# determine_rebase_to decides whether this run should rebase MicroShift onto an
# OCP release payload before building the RPMs, and if so prints the pullspec to
# rebase to on stdout. Diagnostics go to stderr; stdout carries only the
# pullspec (empty means "do not rebase"). A non-zero return means "fail closed":
# an explicit retest asked for a rebase but the provided input is missing or is
# not the canonical trusted exact amd64 OCP nightly for this job's release.
#
# Two rebase paths exist and they are deliberately distinct:
#
#   1. Controller / release-payload verification (unchanged). When the
#      release-controller runs these jobs to verify a promotion candidate, it
#      names the ProwJob with the candidate version and date, so JOB_SPEC's
#      prowjobid contains "nightly". Scheduled periodics and presubmits use a
#      UUID prowjobid and therefore do not rebase. RELEASE_IMAGE_LATEST is the
#      payload under verification and is reused verbatim as the rebase target.
#
#   2. Explicit opt-in manual retest (new, default-off). A human triggers one of
#      the MicroShift 4.21 amd64 conformance periodics through Gangway:
#        * periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance        (parallel)
#        * periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance-serial  (serial)
#      with an exact, already-published amd64 OCP nightly provided as
#      RELEASE_IMAGE_LATEST and sets
#      MULTISTAGE_PARAM_OVERRIDE_MICROSHIFT_EXACT_PAYLOAD_RETEST=true.
#      ci-operator injects MULTISTAGE_PARAM_OVERRIDE_* env vars into the step
#      (see cmd/ci-operator/main.go:applyEnvOverrides) and, because
#      RELEASE_IMAGE_LATEST is passed as an input pull-spec, resolves "latest"
#      directly to it (pkg/defaults/defaults.go) and re-exports it to steps as
#      the in-cluster RELEASE_IMAGE_LATEST plus the external, human-readable
#      ORIGINAL_RELEASE_IMAGE_LATEST (pkg/steps/release/import_release.go,
#      pkg/steps/multi_stage). This path does NOT synthesize a controller
#      ProwJob identity: the prowjobid stays a UUID, so the run never claims the
#      controller gate. It fails closed unless ORIGINAL_RELEASE_IMAGE_LATEST is
#      exactly registry.ci.openshift.org/ocp/release:<this-release>.Z-0.nightly-YYYY-MM-DD-HHMMSS
#      (amd64 only; arm64 would be ocp-arm64/release-arm64). The release line is
#      taken from the job's own name, not from operator-supplied input.
#
# Observable rebase evidence: on either rebasing path this prints
# "REBASE_TO is set to ..." and the auto-rebase entrypoint runs below; a run
# with no rebase prints "REBASE_TO is not set, skipping rebase".
determine_rebase_to() {
  local retest_opt_in prowjob_id job_name expected_release original trusted_pattern
  retest_opt_in="${MULTISTAGE_PARAM_OVERRIDE_MICROSHIFT_EXACT_PAYLOAD_RETEST:-false}"

  # Path 1: controller / release-payload verification (unchanged behavior).
  prowjob_id=$(echo "${JOB_SPEC}" | jq -r '.prowjobid // empty')
  if [[ -n "${prowjob_id}" && "${prowjob_id}" =~ nightly ]]; then
    echo "${RELEASE_IMAGE_LATEST}"
    return 0
  fi

  # Default: no explicit opt-in -> no rebase (unchanged behavior for scheduled
  # periodics and presubmits).
  if [[ "${retest_opt_in}" != "true" ]]; then
    return 0
  fi

  # Path 2: explicit opt-in manual retest. This is NOT controller verification.
  echo "Explicit exact-payload retest requested: manual run, not release-controller verification" >&2

  # The intended release line comes from the job's own name
  # (e.g. periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance),
  # so a trigger cannot widen it to a different release.
  job_name=$(echo "${JOB_SPEC}" | jq -r '.job // empty')
  if [[ "${job_name}" =~ release-([0-9]+\.[0-9]+) ]]; then
    expected_release="${BASH_REMATCH[1]}"
  else
    echo "ERROR: cannot determine intended release line from job name '${job_name}'; refusing to rebase" >&2
    return 1
  fi

  # Validate the external, human-readable pullspec; restrict to the canonical
  # trusted exact amd64 OCP nightly for this release line.
  original="${ORIGINAL_RELEASE_IMAGE_LATEST:-}"
  if [[ -z "${original}" ]]; then
    echo "ERROR: ORIGINAL_RELEASE_IMAGE_LATEST is not set; cannot verify an exact nightly, refusing to rebase" >&2
    return 1
  fi
  trusted_pattern="^registry[.]ci[.]openshift[.]org/ocp/release:${expected_release//./[.]}[.][0-9]+-0[.]nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$"
  if [[ ! "${original}" =~ ${trusted_pattern} ]]; then
    echo "ERROR: '${original}' is not a canonical trusted exact amd64 OCP ${expected_release} nightly pullspec" >&2
    echo "       (expected registry.ci.openshift.org/ocp/release:${expected_release}.Z-0.nightly-YYYY-MM-DD-HHMMSS); refusing to rebase" >&2
    return 1
  fi

  # Reuse the in-cluster RELEASE_IMAGE_LATEST as the actual rebase target, exactly
  # as the controller path does; it is what the downstream rebase can pull.
  if [[ -z "${RELEASE_IMAGE_LATEST:-}" ]]; then
    echo "ERROR: RELEASE_IMAGE_LATEST is not set; cannot rebase" >&2
    return 1
  fi

  echo "Validated exact amd64 OCP ${expected_release} nightly for manual retest: ${original}" >&2
  echo "${RELEASE_IMAGE_LATEST}"
  return 0
}
# <<< determine_rebase_to END

REBASE_TO=""
if ! REBASE_TO=$(determine_rebase_to); then
  # Fail closed: an explicit retest requested a rebase with missing or untrusted
  # input. Do not fall back to a non-rebased run that would silently misreport.
  trap_install_status_exit_code "$EXIT_CODE_REBASE_FAILURE"
  exit 1
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
