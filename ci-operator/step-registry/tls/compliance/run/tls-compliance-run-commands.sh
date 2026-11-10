#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Clusters behind a bastion (e.g. baremetal dev-scripts) are only reachable
# through the proxy configured by the install steps. The CRD manifests live on
# GitHub, which must bypass that proxy.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
  NO_PROXY="${NO_PROXY:+${NO_PROXY},}raw.githubusercontent.com,github.com,quay.io"
  no_proxy="${no_proxy:+${no_proxy},}raw.githubusercontent.com,github.com,quay.io"
  export NO_PROXY no_proxy
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
SHARED_DIR="${SHARED_DIR:-/tmp/shared}"
SCANNER_NAMESPACE="${SCANNER_NAMESPACE:-tls-compliance-scan}"
SCAN_TIMEOUT_SECONDS="${SCAN_TIMEOUT_SECONDS:-1800}"
KEEPER_IMAGE="${KEEPER_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"
MANIFEST_REF="${TLS_COMPLIANCE_MANIFEST_REF:-v1.2.0}"
SCANNER_IMAGE="${TLS_COMPLIANCE_OPERATOR_IMAGE:?TLS_COMPLIANCE_OPERATOR_IMAGE must be supplied by ci-operator; the consuming config needs a base_images entry named tls-compliance-operator-tool}"

SCAN_NAMESPACES="${SCAN_NAMESPACES:-}"
SCAN_ALL_PORTS="${SCAN_ALL_PORTS:-false}"
REQUIRE_PQC="${REQUIRE_PQC:-false}"
EXPECTED_GROUPS="${EXPECTED_GROUPS:-}"
EXPECTED_GROUPS_MODE="${EXPECTED_GROUPS_MODE:-contains}"
FAIL_ON_GROUP_MISMATCH="${FAIL_ON_GROUP_MISMATCH:-false}"
SCANNER_CPU_REQUEST="${SCANNER_CPU_REQUEST:-500m}"
SCANNER_CPU_LIMIT="${SCANNER_CPU_LIMIT:-4}"
SCANNER_MEM_REQUEST="${SCANNER_MEM_REQUEST:-1Gi}"
SCANNER_MEM_LIMIT="${SCANNER_MEM_LIMIT:-4Gi}"

JOB_NAME="tls-compliance-scan"
REPORT_DIR="${ARTIFACT_DIR}/tls-compliance"
REPORT_FILE="${ARTIFACT_DIR}/junit_tls_compliance_scan.xml"
CRD_BASE_URL="https://raw.githubusercontent.com/sebrandon1/tls-compliance-operator/${MANIFEST_REF}/config/crd/bases"
# "<crd name>|<manifest file>" pairs, as published at the pinned tag.
CRD_SPECS=(
  "tlscompliancereports.security.telco.openshift.io|security.telco.openshift.io_tlscompliancereports.yaml"
  "tlscompliancetargets.security.telco.openshift.io|security.telco.openshift.io_tlscompliancetargets.yaml"
  "tlssecurityprofiles.security.telco.openshift.io|security.telco.openshift.io_tlssecurityprofiles.yaml"
)

_CLEANUP_POD=""
_CRDS_TO_DELETE=()

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ -n "${_CLEANUP_POD}" ]]; then
    oc logs "${_CLEANUP_POD}" -c scanner -n "${SCANNER_NAMESPACE}" 2>/dev/null >> "${REPORT_DIR}/scan.log" || true
  fi
  oc delete job "${JOB_NAME}" -n "${SCANNER_NAMESPACE}" --ignore-not-found --wait=false || true
  # The cluster-admin binding is cluster-scoped and outlives the namespace.
  oc adm policy remove-cluster-role-from-user cluster-admin -z default -n "${SCANNER_NAMESPACE}" || true
  oc delete namespace "${SCANNER_NAMESPACE}" --ignore-not-found --wait=false || true
  if (( ${#_CRDS_TO_DELETE[@]} > 0 )); then
    # Only remove the CRDs this step installed. Deleting a CRD also deletes every
    # cluster-scoped TLSComplianceReport, so never touch one we did not create.
    for crd in "${_CRDS_TO_DELETE[@]}"; do
      oc delete crd "${crd}" --ignore-not-found --wait=false || true
    done
  fi
  exit "${status}"
}

require_bool() {
  case "$2" in
    true|false) ;;
    *) echo "Invalid $1='$2' (expected literal \"true\" or \"false\")" >&2; exit 1 ;;
  esac
}

# Validate before touching the cluster.
require_bool SCAN_ALL_PORTS "${SCAN_ALL_PORTS}"
require_bool REQUIRE_PQC "${REQUIRE_PQC}"
require_bool FAIL_ON_GROUP_MISMATCH "${FAIL_ON_GROUP_MISMATCH}"
if [[ "${FAIL_ON_GROUP_MISMATCH}" == "true" && -z "${EXPECTED_GROUPS}" ]]; then
  echo "FAIL_ON_GROUP_MISMATCH=true requires EXPECTED_GROUPS to be set" >&2
  exit 1
fi
if [[ -n "${EXPECTED_GROUPS}" ]]; then
  case "${EXPECTED_GROUPS_MODE}" in
    contains|exact) ;;
    *) echo "Invalid EXPECTED_GROUPS_MODE='${EXPECTED_GROUPS_MODE}' (expected contains or exact)" >&2; exit 1 ;;
  esac
fi
if [[ ! "${SCAN_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Invalid SCAN_TIMEOUT_SECONDS='${SCAN_TIMEOUT_SECONDS}' (expected a number of seconds)" >&2
  exit 1
fi
# The ref times out at 1h; leave room to collect the report before that.
if (( SCAN_TIMEOUT_SECONDS > 3000 )); then
  echo "Invalid SCAN_TIMEOUT_SECONDS='${SCAN_TIMEOUT_SECONDS}' (must be <= 3000 so artifacts can still be collected)" >&2
  exit 1
fi
if [[ -n "${SCAN_NAMESPACES}" && ! "${SCAN_NAMESPACES}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(,[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]; then
  echo "Invalid SCAN_NAMESPACES='${SCAN_NAMESPACES}' (expected comma-separated namespace names)" >&2
  exit 1
fi
# This step deletes its namespace, so only accept the names it owns.
if [[ ! "${SCANNER_NAMESPACE}" =~ ^tls-compliance-scan(-[a-z0-9]([-a-z0-9]*[a-z0-9])?)?$ ]]; then
  echo "Invalid SCANNER_NAMESPACE='${SCANNER_NAMESPACE}' (must be tls-compliance-scan or tls-compliance-scan-<suffix>)" >&2
  exit 1
fi

mkdir -p "${REPORT_DIR}"
: > "${REPORT_DIR}/scan.log"
trap cleanup EXIT

echo "=== TLS compliance scan ==="
echo "Operator image: ${SCANNER_IMAGE}"
echo "Manifest ref:   ${MANIFEST_REF}"
echo "Namespace:      ${SCANNER_NAMESPACE}"
echo "Scan scope:     ${SCAN_NAMESPACES:-<all namespaces>}"
echo "KUBECONFIG:     ${KUBECONFIG:-<unset>}"

# The operator creates TLSComplianceReport objects even in --run-once mode, so
# its CRDs must exist before the manager starts. The image is distroless and
# cannot install them itself, and step directories do not ship extra files.
echo "Installing tls-compliance-operator CRDs (${MANIFEST_REF})..."
for spec in "${CRD_SPECS[@]}"; do
  crd="${spec%%|*}"
  file="${spec##*|}"
  if ! oc get crd "${crd}" >/dev/null 2>&1; then
    _CRDS_TO_DELETE+=("${crd}")
  fi
  oc apply -f "${CRD_BASE_URL}/${file}"
  # apply returns before the API server serves the resource.
  oc wait --for=condition=Established "crd/${crd}" --timeout=120s
done

echo "Creating namespace ${SCANNER_NAMESPACE}..."
# A leftover namespace from a previous run may still be terminating.
oc delete namespace "${SCANNER_NAMESPACE}" --ignore-not-found --wait=true --timeout=120s || true
oc create namespace "${SCANNER_NAMESPACE}"

# The operator lists endpoints and workloads cluster-wide, which is the same
# cluster-admin grant tls-scanner-run uses for its scan pod.
echo "Granting cluster-admin to the namespace's default service account..."
oc adm policy add-cluster-role-to-user cluster-admin -z default -n "${SCANNER_NAMESPACE}"
# Let the SCC/RBAC binding propagate before the pod is admitted.
sleep 10

MANAGER_ARGS=(--run-once "--output-format=junit" "--output-file=/results/report")
if [[ -n "${SCAN_NAMESPACES}" ]]; then
  MANAGER_ARGS+=("--include-namespaces=${SCAN_NAMESPACES}")
fi
if [[ "${SCAN_ALL_PORTS}" == "true" ]]; then
  MANAGER_ARGS+=(--scan-all-ports)
fi
if [[ "${REQUIRE_PQC}" == "true" ]]; then
  MANAGER_ARGS+=(--require-pqc)
fi
if [[ -n "${EXPECTED_GROUPS}" ]]; then
  # Strip whitespace so a comma-separated list with spaces is still one value.
  EXPECTED_GROUPS="${EXPECTED_GROUPS//[[:space:]]/}"
  MANAGER_ARGS+=("--expected-groups=${EXPECTED_GROUPS}")
  MANAGER_ARGS+=("--expected-groups-mode=${EXPECTED_GROUPS_MODE}")
  if [[ "${FAIL_ON_GROUP_MISMATCH}" == "true" ]]; then
    MANAGER_ARGS+=(--fail-on-group-mismatch)
  fi
fi

# One YAML list item per flag: a single scalar would reach the binary as one
# malformed argument.
ARGS_YAML=""
for arg in "${MANAGER_ARGS[@]}"; do
  ARGS_YAML="${ARGS_YAML}            - ${arg}"$'\n'
done

echo "Deploying scan Job..."
oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${SCANNER_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: default
      restartPolicy: Never
      containers:
        - name: scanner
          image: ${SCANNER_IMAGE}
          imagePullPolicy: Always
          args:
${ARGS_YAML}          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: "${SCANNER_CPU_REQUEST}"
              memory: ${SCANNER_MEM_REQUEST}
            limits:
              cpu: "${SCANNER_CPU_LIMIT}"
              memory: ${SCANNER_MEM_LIMIT}
          volumeMounts:
            - name: results
              mountPath: /results
        # Reading the report needs a running container, and the emptyDir dies
        # with the pod, so keep a sidecar alive after the scanner exits. The
        # securityContext is left to the SCC-assigned UID for this namespace.
        - name: keeper
          image: ${KEEPER_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sleep", "infinity"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: results
              mountPath: /results
      volumes:
        - name: results
          emptyDir: {}
EOF

echo "Waiting for the scan pod to start..."
pod=""
for _ in {1..60}; do
  pod=$(oc get pods -n "${SCANNER_NAMESPACE}" -l "job-name=${JOB_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${pod}" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "${pod}" ]]; then
  echo "ERROR: scan pod never started" >&2
  oc get job "${JOB_NAME}" -n "${SCANNER_NAMESPACE}" -o yaml || true
  oc get events -n "${SCANNER_NAMESPACE}" --sort-by='.lastTimestamp' || true
  exit 1
fi
_CLEANUP_POD="${pod}"

echo "Waiting for the scan to finish (timeout ${SCAN_TIMEOUT_SECONDS}s)..."
scan_exit_code=""
deadline=$((SECONDS + SCAN_TIMEOUT_SECONDS))
while :; do
  scan_exit_code=$(oc get pod "${pod}" -n "${SCANNER_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="scanner")].state.terminated.exitCode}' 2>/dev/null || true)
  if [[ -n "${scan_exit_code}" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "ERROR: the scan did not finish within ${SCAN_TIMEOUT_SECONDS}s" >&2
    oc get pod "${pod}" -n "${SCANNER_NAMESPACE}" -o wide || true
    oc describe pod "${pod}" -n "${SCANNER_NAMESPACE}" || true
    exit 1
  fi
  sleep 5
done
echo "Scan exit code: ${scan_exit_code}"

oc logs "${pod}" -c scanner -n "${SCANNER_NAMESPACE}" > "${REPORT_DIR}/scan.log" 2>&1 || true

# Plain exec cat rather than oc cp: the keeper image does not necessarily carry
# tar, and every export format is text. Write to a scratch file first so a
# truncated read is never published as a JUnit report.
raw_report="${REPORT_DIR}/report.raw"
if ! oc exec -n "${SCANNER_NAMESPACE}" "${pod}" -c keeper -- cat /results/report \
  > "${raw_report}" 2>"${REPORT_DIR}/exec.err"; then
  echo "ERROR: could not read the report from ${pod}:/results/report" >&2
  cat "${REPORT_DIR}/exec.err" >&2 || true
  oc logs "${pod}" -c scanner -n "${SCANNER_NAMESPACE}" --tail=50 || true
  exit 1
fi
if [[ ! -s "${raw_report}" || "$(head -c 1 "${raw_report}")" != "<" ]]; then
  echo "ERROR: the report at ${pod}:/results/report is empty or not XML" >&2
  head -c 200 "${raw_report}" >&2 || true
  oc logs "${pod}" -c scanner -n "${SCANNER_NAMESPACE}" --tail=50 || true
  exit 1
fi
cp "${raw_report}" "${REPORT_FILE}"
echo "JUnit report written to ${REPORT_FILE}"

case "${scan_exit_code}" in
  0) verdict="compliant" ;;
  1) verdict="non-compliant" ;;
  *) verdict="error" ;;
esac
{
  echo "scan_exit_code: ${scan_exit_code}"
  echo "verdict: ${verdict}"
  echo "report: junit_tls_compliance_scan.xml"
  echo "namespaces: ${SCAN_NAMESPACES:-<all>}"
} > "${REPORT_DIR}/summary.txt"
mkdir -p "${SHARED_DIR}"
echo "${scan_exit_code}" > "${SHARED_DIR}/tls-compliance-exit-code"

echo "=== TLS compliance scan complete: ${verdict} (exit code ${scan_exit_code}) ==="

# Findings are informational: a non-compliant endpoint is a failing testcase in
# the report, not a failed job. Only a scan that could not run is an error.
case "${scan_exit_code}" in
  0|1) exit 0 ;;
  *) exit 1 ;;
esac
