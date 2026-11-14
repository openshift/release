#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ ! -f "${env_file}" ]]; then
    printf 'Missing runtime lease export file: %s\n' "${env_file}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${env_file}"

export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by SELECTED_LOCATION or the legacy runtime slot export file}"

# Source CPO image override if present (set by aro-hcp-hypershift-images-push)
cpo_env="${SHARED_DIR}/hypershift-cpo-override.env"
if [[ -f "${cpo_env}" ]]; then
    # shellcheck disable=SC1090
    source "${cpo_env}"
fi

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"
export ARO_HCP_CONFIG_FILE="${PWD}/config/config.yaml"
export REGION="${LOCATION}"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

unset GOFLAGS
export TEMPLATIZE_USE_PREBUILT=1

# This block prepares the environment to run the tests in.
# It runs against INFRA_SUBSCRIPTION.
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
if [[ -n "${HYPERSHIFT_V2_BINARY:-}" ]]; then
    if [[ ! -x "${HYPERSHIFT_V2_BINARY}" ]]; then
        echo "Missing executable HYPERSHIFT_V2_BINARY: ${HYPERSHIFT_V2_BINARY}" >&2
        exit 1
    fi
    # Keep management access separate from the service kubeconfig used below.
    export HYPERSHIFT_V2_MANAGEMENT_KUBECONFIG="${PWD}/hypershift-v2-mgmt.kubeconfig"
    make -C dev-infrastructure/ mgmt.aks.kubeconfig.pipeline \
      MGMT_KUBECONFIG_FILE=../hypershift-v2-mgmt.kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
    chmod 600 "${HYPERSHIFT_V2_MANAGEMENT_KUBECONFIG}"

    mkdir -p "${ARTIFACT_DIR}"
    go version -m "${HYPERSHIFT_V2_BINARY}" > "${ARTIFACT_DIR}/hypershift-v2-build-info.txt"
    ho_image=$(yq -r ".clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image | .registry + \"/\" + .repository + \"@\" + .digest" "${SHARED_DIR}/hypershift-image-overrides.yaml")
    jq -n \
      --arg test_runner_image "${ARO_HCP_TEST_RUNNER_IMAGE}" \
      --arg upstream_test_image "${HYPERSHIFT_V2_TEST_IMAGE}" \
      --arg test_binary_sha256 "$(sha256sum "${HYPERSHIFT_V2_BINARY}" | cut -d ' ' -f 1)" \
      --arg pull_refs "${PULL_REFS:-}" \
      --arg ho_image "${ho_image}" \
      --arg cpo_image "${CPO_IMAGE_OVERRIDE:?CPO image override is required for HyperShift v2}" \
      '{test_runner_image: $test_runner_image, upstream_test_image: $upstream_test_image, test_binary_sha256: $test_binary_sha256, pull_refs: $pull_refs, ho_image: $ho_image, cpo_image: $cpo_image}' \
      > "${ARTIFACT_DIR}/hypershift-v2-provenance.json"
fi
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
export AZURE_TOKEN_CREDENTIALS=prod
FRONTEND_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')"
ADMIN_API_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp-admin-api admin-api-vs -o jsonpath='{.spec.hosts[0]}')"
make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}"

# This block runs the tests against CUSTOMER_SUBSCRIPTION.
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"
echo "Selected ARO HCP e2e suite: ${ARO_HCP_E2E_SUITE:-rp-api-compat-all/parallel}"
if [[ -n "${HYPERSHIFT_V2_BINARY:-}" ]]; then
    # Ignore reports left by earlier invocations, including local reruns.
    v2_run_marker=$(mktemp "${ARTIFACT_DIR}/hypershift-v2-started.XXXXXX")
fi
make e2e-local/run -o test/aro-hcp-tests \
  FRONTEND_ADDRESS="${FRONTEND_ADDRESS}" \
  ADMIN_API_ADDRESS="${ADMIN_API_ADDRESS}" \
  SKIP_CERT_VERIFICATION=true \
  ARO_HCP_CLOUD="dev" \
  ARO_HCP_E2E_SUITE="${ARO_HCP_E2E_SUITE:-rp-api-compat-all/parallel}"

if [[ -n "${HYPERSHIFT_V2_BINARY:-}" ]]; then
    # An older promoted ARO-HCP image can ignore the v2 opt-in. Require evidence
    # independently so that rollout cannot silently pass with smoke checks only.
    python3 - "${ARTIFACT_DIR}" "${v2_run_marker}" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root, marker = map(Path, sys.argv[1:])
reports = [p for p in root.rglob("junit_hypershift_v2.xml")
           if p.stat().st_mtime_ns > marker.stat().st_mtime_ns]
if len(reports) != 1:
    sys.exit(f"Expected one fresh HyperShift v2 JUnit report, found {len(reports)}. "
             "Verify that the ARO-HCP runner image contains the v2 adapter.")
cases = list(ET.parse(reports[0]).getroot().iter("testcase"))
expected = "should have all expected conditions with correct status"
if (len(cases) != 1 or not cases[0].get("name", "").endswith(expected)
        or any(cases[0].find(tag) is not None for tag in ("skipped", "failure", "error"))):
    sys.exit(f"Expected one passing HyperShift v2 conditions testcase in {reports[0]}")
print(f"Verified HyperShift v2 execution: {reports[0]}")
PY
fi

# the make target produces a junit.xml in ARTIFACT_DIR.  We want to copy to SHARED_DIR so we can create
# direct debugging links for the individual tests that failed. Gzip it due to 3mb SHARED_DIR limit.
gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/junit-e2e.xml.gz"
