#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# ROSAENG-67586: compose the customer-facing FVT (ocm-backend-tests) cases as a
# validation tail against a cluster provisioned by any matrix head via the
# SHARED_DIR contract (ROSAENG-67580). Compose, don't migrate: the FVT suite and
# its harness (ocmtest) stay owned by CS/OCM QE; this ref wires only the
# existing-cluster handoff and the case selection.
#
# DRAFT / harness contract to confirm with CS/OCM QE before merge:
#  - the test phase honoring a pre-seeded cluster state under output/ (cluster.ini
#    ID/State=ready + .datainfo/kube-configs/<cluster-id>.kubeconfig), symmetric
#    to --justClean consuming recorded state (which rosa-e2e-ocm-fvt-clean
#    already relies on), or a first-class existing-cluster mode if preferred.
#    (--justTest does not exist in ocmtest; test-only execution comes from
#    OCM_FVT_DEFER_CLEAN=true, confirmed by the 87743 rehearsal CLI help.)

# Apply Gangway override before any use of OCM_FVT_EXTRA_ENVS (same as
# rosa-e2e-ocm-fvt).
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OCM_FVT_EXTRA_ENVS:-}" ]]; then
  echo "Applying Gangway override: OCM_FVT_EXTRA_ENVS (from MULTISTAGE_PARAM_OVERRIDE_OCM_FVT_EXTRA_ENVS)"
  export OCM_FVT_EXTRA_ENVS="${MULTISTAGE_PARAM_OVERRIDE_OCM_FVT_EXTRA_ENVS}"
fi

if [[ -z "${OCM_FVT_JOB_NAME:-}" ]]; then
  echo "ERROR: OCM_FVT_JOB_NAME is required but not set (selects the FVT profile / case set)" >&2
  exit 1
fi

# ---- SHARED_DIR contract (provisioner-to-validator, ROSAENG-67580) ----
if [[ ! -s "${SHARED_DIR}/cluster-id" ]]; then
  echo "ERROR: ${SHARED_DIR}/cluster-id is missing; run a provisioner head before this ref" >&2
  exit 1
fi
CLUSTER_ID="$(tr -d '[:space:]' < "${SHARED_DIR}/cluster-id")"
if [[ ! -s "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: ${SHARED_DIR}/kubeconfig is missing; the head must publish the customer-plane kubeconfig" >&2
  exit 1
fi
echo "Composing FVT customer cases against cluster ${CLUSTER_ID} (profile ${OCM_FVT_JOB_NAME})"

JOB_LINK="https://prow.ci.openshift.org/view/gs/test-platform-results-public/"
if [[ -n "${PULL_NUMBER:-}" ]]; then
  JOB_LINK="${JOB_LINK}pr-logs/pull/openshift_release/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  JOB_LINK="${JOB_LINK}logs/${JOB_NAME}/${BUILD_ID}"
fi

# ---- Podman env file (credential values are never traced) ----
old_umask=$(umask)
umask 077
podman_env_file="$(mktemp /tmp/podman.env.XXXXXX)"
cleanup() {
  rm -f "${podman_env_file}"
  if [[ -n "${ocm_fvt_output:-}" ]]; then
    rm -rf -- "${ocm_fvt_output}"
  fi
}
trap cleanup EXIT
umask "${old_umask}"

{
  echo "HOME=/home/ci-user"
  echo "AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-cred"
  echo "SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-shared-vpc-credentials"
  echo "JOB_LINK=${JOB_LINK}"
  echo "SLACK_WEBHOOK_URL=$(cat /usr/local/cs-qe-credentials/slack_webhook_url)"
  echo "CONSOLE_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/console_client_secret)"
  echo "CLUSTER_ID=${CLUSTER_ID}"
  # Test phase only: teardown stays with the workflow post
  # (rosa-cluster-deprovision or the head's own teardown), never the FVT harness.
  echo "OCM_FVT_DEFER_CLEAN=true"
} > "${podman_env_file}"

if [[ -n "${OCM_FVT_OCM_ENV:-}" ]]; then
  echo "OCM_ENV=${OCM_FVT_OCM_ENV}" >> "${podman_env_file}"
fi

# Customer-facing case selection: filters the ocmtest harness honours
# (cmd/ocmtest/test/exec.go in rosa-backend-tests). CASE_LABEL_FILTER narrows
# the profile's case set via --ginkgo.label-filter (e.g. config-idp for the
# FVT IDP variants; composed with the profile's own filters via &&). ocmtest
# does not read GINKGO_FOCUS.
if [[ -n "${FVT_CASE_LABEL_FILTER:-}" ]]; then
  echo "CASE_LABEL_FILTER=${FVT_CASE_LABEL_FILTER}" >> "${podman_env_file}"
fi
if [[ -n "${FVT_GINKGO_SKIP:-}" ]]; then
  echo "GINKGO_SKIP=${FVT_GINKGO_SKIP}" >> "${podman_env_file}"
fi

if [[ -n "${OCM_FVT_EXTRA_ENVS:-}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    echo "${line}" >> "${podman_env_file}"
  done <<< "${OCM_FVT_EXTRA_ENVS}"
fi

# OCM tokens for the FVT cases that exercise the cluster-service API surface.
cred_sources='source /usr/local/cs-qe-credentials/ocm-tokens'
env -i bash --norc --noprofile -c "
  ${cred_sources}
  env | grep -v '^_='
" >> "${podman_env_file}"

# SREP service account credentials (same rationale as rosa-e2e-ocm-fvt: tests
# must not depend on expiring offline tokens for the SREP role).
if [[ -f /usr/local/cs-qe-credentials/backplane_client_id && -f /usr/local/cs-qe-credentials/backplane_client_secret ]]; then
  [[ $- == *x* ]] && WAS_TRACING_SREP=true || WAS_TRACING_SREP=false
  set +x
  echo "SREP_CLIENT_ID=$(cat /usr/local/cs-qe-credentials/backplane_client_id)" >> "${podman_env_file}"
  echo "SREP_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/backplane_client_secret)" >> "${podman_env_file}"
  $WAS_TRACING_SREP && set -x
fi

OCMCI_IMAGE="quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest"

echo "=== ocmci image digest ==="
podman pull --authfile /usr/local/cs-qe-credentials/.dockerconfigjson "${OCMCI_IMAGE}"
podman image inspect --format '{{.Digest}}' "${OCMCI_IMAGE}" || true
echo "=========================="

# ---- Seed ocmtest's recorded-cluster state with the SHARED_DIR cluster ----
# ocmtest tracks clusters under output/ (cluster.ini with ID=/State=) and
# .datainfo/kube-configs/<cluster-id>.kubeconfig; rosa-e2e-ocm-fvt-clean already
# consumes exactly this layout via --justClean. Seed the same shape so the test
# phase targets the composed cluster instead of provisioning its own. The state
# dir stays outside ARTIFACT_DIR (which bypasses sidecar censoring and would
# upload the seeded customer-plane kubeconfig); only the reports are copied
# into ARTIFACT_DIR at the end. Removed on exit by the cleanup trap.
ocm_fvt_output="$(mktemp -d /tmp/ocm-fvt-validate-results.XXXXXX)"
chmod 0777 "${ocm_fvt_output}"
state_dir="${ocm_fvt_output}/${OCM_FVT_JOB_NAME}"
mkdir -p "${state_dir}/.datainfo/kube-configs"
{
  echo "ID=${CLUSTER_ID}"
  echo "State=ready"
  echo "Composed=rosa-e2e-ocm-fvt-validate-customer"
} > "${state_dir}/cluster.ini"
cp "${SHARED_DIR}/kubeconfig" "${state_dir}/.datainfo/kube-configs/${CLUSTER_ID}.kubeconfig"
# Image USER is ci-user (uid 998); make the seeded state usable in-container.
chmod -R a+rwX "${state_dir}" 2>/dev/null || true
echo "Seeded ocmtest cluster state for ${CLUSTER_ID} under ${state_dir}"

podman_args=(
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson
  --env-file "${podman_env_file}"
  "-v" "/usr/local/cs-qe-credentials:/credentials:ro,z"
  "-v" "${ocm_fvt_output}:/ocm-backend-tests/output:z"
  --rm
)

echo "Running ocmtest against existing cluster ${CLUSTER_ID} (OCM_FVT_DEFER_CLEAN=true skips the post/clean phase)"
exit_code=0
# Do not trace secret env expansion.
[[ $- == *x* ]] && WAS_TRACING_RUN=true || WAS_TRACING_RUN=false
set +x
# No --justTest flag exists in ocmtest (only --justClean, which is post-only);
# test-only execution comes from OCM_FVT_DEFER_CLEAN=true in the env file,
# same as rosa-e2e-ocm-fvt.
podman run \
  "${podman_args[@]}" \
  "${OCMCI_IMAGE}" \
  ocmtest test --service "${OCM_FVT_SERVICE:-cms}" --job "${OCM_FVT_JOB_NAME}" || exit_code=$?
$WAS_TRACING_RUN && set -x

# Copy merged report.xml to artifacts (skip per-phase duplicates).
find "${ocm_fvt_output}" -type f -name 'report.xml' -print0 | while IFS= read -r -d '' xml_file; do
  cp "${xml_file}" "${ARTIFACT_DIR}/junit-ocm-fvt-validate-customer.xml"
done

exit "${exit_code}"
