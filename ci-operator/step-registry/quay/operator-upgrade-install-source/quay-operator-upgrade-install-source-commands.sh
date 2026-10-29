#!/bin/bash
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-install-source"
mkdir -p "${ARTIFACT_DIR}"
SOURCE_IMAGE="${QUAY_UPGRADE_SOURCE_CATALOG_IMAGE:-}"
# When no explicit source catalog image is provided, fall back to the ART FBC
# digest resolved by quay-enable-catalogsource-art (written to
# ${SHARED_DIR}/quay_index_image). One ART FBC carries every Quay channel, so the
# same immutable digest serves both the n-1 source and the n target.
if [[ -z "${SOURCE_IMAGE}" && -s "${SHARED_DIR}/quay_index_image" ]]; then
  SOURCE_IMAGE="$(<"${SHARED_DIR}/quay_index_image")"
fi
SOURCE_CHANNEL="${QUAY_UPGRADE_SOURCE_CHANNEL:-}"
TARGET_CHANNEL="${QUAY_UPGRADE_TARGET_CHANNEL:-}"
SOURCE_CATALOG="${QUAY_UPGRADE_SOURCE_CATALOG_NAME:-quay-upgrade-source}"
# Released-catalog mode: subscribe from an existing cluster CatalogSource (e.g.
# redhat-operators) instead of creating one from an immutable catalog image.
RELEASED_CATALOG="${QUAY_UPGRADE_CATALOG_SOURCE:-}"
if [[ -n "${RELEASED_CATALOG}" ]]; then
  SOURCE_CATALOG="${RELEASED_CATALOG}"
  SOURCE_IMAGE=""
fi
CATALOG_NS="${QUAY_UPGRADE_CATALOG_NAMESPACE:-openshift-marketplace}"
OPERATOR_NS="${QUAY_UPGRADE_OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION="${QUAY_UPGRADE_SUBSCRIPTION_NAME:-quay-operator}"
TIMEOUT="${QUAY_UPGRADE_CATALOG_TIMEOUT:-10m}"

valid_name() { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; }
valid_channel() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
valid_digest_image() { [[ "$1" =~ ^[^[:space:]@]+@sha256:[a-f0-9]{64}$ ]]; }
duration_seconds() {
  [[ "$1" =~ ^([1-9][0-9]*)([smh])$ ]] || return 1
  case "${BASH_REMATCH[2]}" in s) echo "${BASH_REMATCH[1]}";; m) echo "$((BASH_REMATCH[1] * 60))";; h) echo "$((BASH_REMATCH[1] * 3600))";; esac
}
fail() { echo "ERROR: $*" >&2; exit 1; }

if [[ -n "${RELEASED_CATALOG}" ]]; then
  valid_channel "${TARGET_CHANNEL}" || fail "QUAY_UPGRADE_TARGET_CHANNEL is required and malformed in released-catalog mode"
else
  valid_digest_image "${SOURCE_IMAGE}" || fail "QUAY_UPGRADE_SOURCE_CATALOG_IMAGE must be image@sha256:<64 hex>"
fi
valid_channel "${SOURCE_CHANNEL}" || fail "QUAY_UPGRADE_SOURCE_CHANNEL is required and malformed"
for name in "${SOURCE_CATALOG}" "${CATALOG_NS}" "${OPERATOR_NS}" "${SUBSCRIPTION}"; do
  valid_name "${name}" || fail "invalid Kubernetes resource name: ${name}"
done
WAIT_SECONDS="$(duration_seconds "${TIMEOUT}")" || fail "QUAY_UPGRADE_CATALOG_TIMEOUT must be a positive Ns, Nm, or Nh duration"

diagnostics() {
  local rc=$?
  [[ ${rc} -eq 0 ]] && return
  {
    echo '=== source install diagnostics ==='
    oc get catalogsource -n "${CATALOG_NS}" "${SOURCE_CATALOG}" -o yaml 2>&1 || true
    oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o yaml 2>&1 || true
    oc get csv -n "${OPERATOR_NS}" -o yaml 2>&1 || true
    oc get installplan -n "${OPERATOR_NS}" -o yaml 2>&1 || true
    oc get events -n "${CATALOG_NS}" --sort-by=.lastTimestamp 2>&1 || true
    oc get events -n "${OPERATOR_NS}" --sort-by=.lastTimestamp 2>&1 || true
  } >"${ARTIFACT_DIR}/diagnostics.txt"
}
trap diagnostics EXIT

wait_catalog() {
  local deadline=$(( $(date +%s) + WAIT_SECONDS )) state
  while (( $(date +%s) < deadline )); do
    state="$(oc get catalogsource -n "${CATALOG_NS}" "$1" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
    [[ "${state}" == READY ]] && return 0
    sleep 10
  done
  fail "CatalogSource $1 did not become READY within ${TIMEOUT}"
}

# Catalog preflight: fail naming each requested channel the catalog's
# quay-operator package lacks, so a stream absent from it stops before install.
preflight_channels() {
  local catalog="$1" deadline=$(( $(date +%s) + WAIT_SECONDS )) channels="" missing=() channel
  shift
  while (( $(date +%s) < deadline )); do
    channels="$(oc get packagemanifests -n "${CATALOG_NS}" -l "catalog=${catalog}" \
      -o jsonpath='{range .items[?(@.metadata.name=="quay-operator")]}{range .status.channels[*]}{.name}{"\n"}{end}{end}' 2>/dev/null || true)"
    [[ -n "${channels}" ]] && break
    sleep 10
  done
  printf '%s\n' "${channels}" >"${ARTIFACT_DIR}/catalog-channels.txt"
  [[ -n "${channels}" ]] || fail "CatalogSource ${CATALOG_NS}/${catalog} served no quay-operator package within ${TIMEOUT}"
  for channel in "$@"; do
    grep -Fxq "${channel}" <<<"${channels}" || missing+=("${channel}")
  done
  (( ${#missing[@]} == 0 )) || fail "quay-operator in CatalogSource ${CATALOG_NS}/${catalog} lacks channel(s): ${missing[*]}; it has: $(paste -sd ' ' <<<"${channels}")"
}

oc get namespace "${CATALOG_NS}" >/dev/null
oc get namespace "${OPERATOR_NS}" >/dev/null
if [[ -z "${RELEASED_CATALOG}" ]] && oc get catalogsource -n "${CATALOG_NS}" "${SOURCE_CATALOG}" >/dev/null 2>&1; then
  owner="$(oc get catalogsource -n "${CATALOG_NS}" "${SOURCE_CATALOG}" -o jsonpath='{.metadata.labels.quay-operator-upgrade\.openshift\.io/managed}' 2>/dev/null || true)"
  [[ "${owner}" == true ]] || fail "CatalogSource ${CATALOG_NS}/${SOURCE_CATALOG} exists but is not owned by this step"
fi
if oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" >/dev/null 2>&1; then
  owner="$(oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o jsonpath='{.metadata.labels.quay-operator-upgrade\.openshift\.io/managed}' 2>/dev/null || true)"
  [[ "${owner}" == true ]] || fail "Subscription ${OPERATOR_NS}/${SUBSCRIPTION} exists but is not owned by this step"
fi

if [[ -z "${RELEASED_CATALOG}" ]]; then
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${SOURCE_CATALOG}
  namespace: ${CATALOG_NS}
  labels:
    quay-operator-upgrade.openshift.io/managed: "true"
spec:
  sourceType: grpc
  image: ${SOURCE_IMAGE}
  displayName: Quay n-1 upgrade source
  publisher: openshift-ci
EOF
fi
wait_catalog "${SOURCE_CATALOG}"
[[ -z "${RELEASED_CATALOG}" ]] || preflight_channels "${SOURCE_CATALOG}" "${SOURCE_CHANNEL}" "${TARGET_CHANNEL}"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION}
  namespace: ${OPERATOR_NS}
  labels:
    quay-operator-upgrade.openshift.io/managed: "true"
spec:
  name: quay-operator
  channel: ${SOURCE_CHANNEL}
  source: ${SOURCE_CATALOG}
  sourceNamespace: ${CATALOG_NS}
  installPlanApproval: Automatic
EOF

deadline=$(( $(date +%s) + WAIT_SECONDS ))
csv=""
phase=""
while (( $(date +%s) < deadline )); do
  csv="$(oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  phase="$(oc get csv -n "${OPERATOR_NS}" "${csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ -n "${csv}" && "${phase}" == Succeeded ]] && break
  sleep 10
done
[[ -n "${csv}" && "${phase}" == Succeeded ]] || fail "source Quay CSV did not reach Succeeded within ${TIMEOUT}"

printf '%s\n' "${csv}" >"${SHARED_DIR}/quay-upgrade-source.csv"
cat >"${SHARED_DIR}/quay-upgrade-source-identity" <<EOF
catalog_name=${SOURCE_CATALOG}
catalog_namespace=${CATALOG_NS}
catalog_image=${SOURCE_IMAGE}
channel=${SOURCE_CHANNEL}
subscription_namespace=${OPERATOR_NS}
subscription_name=${SUBSCRIPTION}
installed_csv=${csv}
EOF
cp "${SHARED_DIR}/quay-upgrade-source-identity" "${ARTIFACT_DIR}/source-identity.txt"
echo "Installed source Quay operator CSV ${csv} from channel ${SOURCE_CHANNEL}."
