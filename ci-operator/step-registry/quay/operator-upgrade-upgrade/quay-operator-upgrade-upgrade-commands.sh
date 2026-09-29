#!/bin/bash
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade"
mkdir -p "${ARTIFACT_DIR}"
SOURCE_IMAGE="${QUAY_UPGRADE_SOURCE_CATALOG_IMAGE:-}"
SOURCE_CHANNEL="${QUAY_UPGRADE_SOURCE_CHANNEL:-}"
SOURCE_CATALOG="${QUAY_UPGRADE_SOURCE_CATALOG_NAME:-quay-upgrade-source}"
TARGET_IMAGE="${QUAY_UPGRADE_TARGET_CATALOG_IMAGE:-}"
# When no explicit catalog images are provided, fall back to the ART FBC digest
# resolved by quay-enable-catalogsource-art (${SHARED_DIR}/quay_index_image). A
# single ART FBC carries every Quay channel, so the same immutable digest backs
# both the n-1 source (stable-3.17) and the n target (stable-3.18); only the
# Subscription channel differs, so this is still a genuine OLM upgrade edge.
if [[ -s "${SHARED_DIR}/quay_index_image" ]]; then
  art_index_image="$(<"${SHARED_DIR}/quay_index_image")"
  SOURCE_IMAGE="${SOURCE_IMAGE:-${art_index_image}}"
  TARGET_IMAGE="${TARGET_IMAGE:-${art_index_image}}"
fi
TARGET_CHANNEL="${QUAY_UPGRADE_TARGET_CHANNEL:-}"
TARGET_CATALOG="${QUAY_UPGRADE_TARGET_CATALOG_NAME:-quay-upgrade-target}"
CATALOG_NS="${QUAY_UPGRADE_CATALOG_NAMESPACE:-openshift-marketplace}"
OPERATOR_NS="${QUAY_UPGRADE_OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION="${QUAY_UPGRADE_SUBSCRIPTION_NAME:-quay-operator}"
QUAY_NS="${QUAY_UPGRADE_QUAY_NAMESPACE:-quay}"
QUAY_REGISTRY="${QUAY_UPGRADE_QUAY_REGISTRY:-quay}"
UPGRADE_TIMEOUT="${QUAY_UPGRADE_TIMEOUT:-30m}"
CATALOG_TIMEOUT="${QUAY_UPGRADE_CATALOG_TIMEOUT:-10m}"

valid_name() { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; }
valid_channel() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
valid_digest_image() { [[ "$1" =~ ^[^[:space:]@]+@sha256:[a-f0-9]{64}$ ]]; }
duration_seconds() {
  [[ "$1" =~ ^([1-9][0-9]*)([smh])$ ]] || return 1
  case "${BASH_REMATCH[2]}" in s) echo "${BASH_REMATCH[1]}";; m) echo "$((BASH_REMATCH[1] * 60))";; h) echo "$((BASH_REMATCH[1] * 3600))";; esac
}
fail() { echo "ERROR: $*" >&2; exit 1; }

valid_digest_image "${SOURCE_IMAGE}" || fail "QUAY_UPGRADE_SOURCE_CATALOG_IMAGE must be image@sha256:<64 hex>"
valid_digest_image "${TARGET_IMAGE}" || fail "QUAY_UPGRADE_TARGET_CATALOG_IMAGE must be image@sha256:<64 hex>"
valid_channel "${SOURCE_CHANNEL}" || fail "QUAY_UPGRADE_SOURCE_CHANNEL is required and malformed"
valid_channel "${TARGET_CHANNEL}" || fail "QUAY_UPGRADE_TARGET_CHANNEL is required and malformed"
for name in "${SOURCE_CATALOG}" "${TARGET_CATALOG}" "${CATALOG_NS}" "${OPERATOR_NS}" "${SUBSCRIPTION}" "${QUAY_NS}" "${QUAY_REGISTRY}"; do
  valid_name "${name}" || fail "invalid Kubernetes resource name: ${name}"
done
[[ "${SOURCE_IMAGE}" != "${TARGET_IMAGE}" || "${SOURCE_CHANNEL}" != "${TARGET_CHANNEL}" ]] || fail "source and target catalog/channel are identical; refusing a non-upgrade"
UPGRADE_SECONDS="$(duration_seconds "${UPGRADE_TIMEOUT}")" || fail "QUAY_UPGRADE_TIMEOUT must be a positive Ns, Nm, or Nh duration"
CATALOG_SECONDS="$(duration_seconds "${CATALOG_TIMEOUT}")" || fail "QUAY_UPGRADE_CATALOG_TIMEOUT must be a positive Ns, Nm, or Nh duration"

diagnostics() {
  local rc=$?
  [[ ${rc} -eq 0 ]] && return
  {
    echo '=== Quay OLM upgrade diagnostics ==='
    oc get catalogsource -n "${CATALOG_NS}" "${SOURCE_CATALOG}" "${TARGET_CATALOG}" -o yaml 2>&1 || true
    oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o yaml 2>&1 || true
    oc get csv -n "${OPERATOR_NS}" -o yaml 2>&1 || true
    oc get installplan -n "${OPERATOR_NS}" -o yaml 2>&1 || true
    oc get quayregistry -n "${QUAY_NS}" "${QUAY_REGISTRY}" -o yaml 2>&1 || true
    oc get deployment -n "${QUAY_NS}" -o wide 2>&1 || true
    oc get pods -n "${QUAY_NS}" -o wide 2>&1 || true
    oc get events -n "${CATALOG_NS}" --sort-by=.lastTimestamp 2>&1 || true
    oc get events -n "${OPERATOR_NS}" --sort-by=.lastTimestamp 2>&1 || true
    oc get events -n "${QUAY_NS}" --sort-by=.lastTimestamp 2>&1 || true
  } >"${ARTIFACT_DIR}/diagnostics.txt"
}
trap diagnostics EXIT

wait_catalog() {
  local deadline=$(( $(date +%s) + CATALOG_SECONDS )) state
  while (( $(date +%s) < deadline )); do
    state="$(oc get catalogsource -n "${CATALOG_NS}" "$1" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
    [[ "${state}" == READY ]] && return 0
    sleep 10
  done
  fail "CatalogSource $1 did not become READY within ${CATALOG_TIMEOUT}"
}

app_images() {
  oc get deployment -n "${QUAY_NS}" -l quay-component=quay-app \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .spec.template.spec.containers[?(@.name=="quay-app")]}{.image}{end}{"\n"}{end}' 2>/dev/null || true
}

[[ -s "${SHARED_DIR}/quay-upgrade-source-identity" ]] || fail "missing source identity from quay-operator-upgrade-install-source"
source_identity="$(cat "${SHARED_DIR}/quay-upgrade-source-identity")"
grep -Fxq "catalog_name=${SOURCE_CATALOG}" <<<"${source_identity}" || fail "source catalog name does not match recorded identity"
grep -Fxq "catalog_namespace=${CATALOG_NS}" <<<"${source_identity}" || fail "source catalog namespace does not match recorded identity"
grep -Fxq "catalog_image=${SOURCE_IMAGE}" <<<"${source_identity}" || fail "source catalog image does not match recorded identity"
grep -Fxq "channel=${SOURCE_CHANNEL}" <<<"${source_identity}" || fail "source channel does not match recorded identity"
grep -Fxq "subscription_namespace=${OPERATOR_NS}" <<<"${source_identity}" || fail "source subscription namespace does not match recorded identity"
grep -Fxq "subscription_name=${SUBSCRIPTION}" <<<"${source_identity}" || fail "source subscription name does not match recorded identity"

pre_csv="$(oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
[[ -n "${pre_csv}" ]] || fail "Subscription ${OPERATOR_NS}/${SUBSCRIPTION} has no installedCSV"
grep -Fxq "installed_csv=${pre_csv}" <<<"${source_identity}" || fail "Subscription installedCSV changed after the source installation"
pre_phase="$(oc get csv -n "${OPERATOR_NS}" "${pre_csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "${pre_phase}" == Succeeded ]] || fail "pre-upgrade CSV ${pre_csv} is not Succeeded (phase ${pre_phase:-empty})"
actual_source="$(oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o jsonpath='{.spec.source}' 2>/dev/null || true)"
actual_channel="$(oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o jsonpath='{.spec.channel}' 2>/dev/null || true)"
[[ "${actual_source}" == "${SOURCE_CATALOG}" && "${actual_channel}" == "${SOURCE_CHANNEL}" ]] || fail "Subscription does not match the requested n-1 source identity"
app_images >"${ARTIFACT_DIR}/quay-app-images-before.txt"

if oc get catalogsource -n "${CATALOG_NS}" "${TARGET_CATALOG}" >/dev/null 2>&1; then
  owner="$(oc get catalogsource -n "${CATALOG_NS}" "${TARGET_CATALOG}" -o jsonpath='{.metadata.labels.quay-operator-upgrade\\.openshift\\.io/scaffold}' 2>/dev/null || true)"
  [[ "${owner}" == true ]] || fail "CatalogSource ${CATALOG_NS}/${TARGET_CATALOG} exists but is not owned by this scaffold"
fi

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${TARGET_CATALOG}
  namespace: ${CATALOG_NS}
  labels:
    quay-operator-upgrade.openshift.io/scaffold: "true"
spec:
  sourceType: grpc
  image: ${TARGET_IMAGE}
  displayName: Quay n upgrade target
  publisher: openshift-ci
EOF
wait_catalog "${TARGET_CATALOG}"

oc patch subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" --type merge \
  -p "{\"spec\":{\"source\":\"${TARGET_CATALOG}\",\"sourceNamespace\":\"${CATALOG_NS}\",\"channel\":\"${TARGET_CHANNEL}\"}}"

deadline=$(( $(date +%s) + UPGRADE_SECONDS ))
post_csv=""
post_phase=""
while (( $(date +%s) < deadline )); do
  post_csv="$(oc get subscription -n "${OPERATOR_NS}" "${SUBSCRIPTION}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  post_phase="$(oc get csv -n "${OPERATOR_NS}" "${post_csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ -n "${post_csv}" && "${post_csv}" != "${pre_csv}" && "${post_phase}" == Succeeded ]]; then break; fi
  failed="$(oc get csv -n "${OPERATOR_NS}" "${post_csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${failed}" != Failed ]] || fail "target CSV ${post_csv} entered Failed phase"
  sleep 15
done
[[ -n "${post_csv}" && "${post_csv}" != "${pre_csv}" && "${post_phase}" == Succeeded ]] || fail "installedCSV did not change to a Succeeded target CSV within ${UPGRADE_TIMEOUT}"

while (( $(date +%s) < deadline )); do
  available="$(oc get quayregistry -n "${QUAY_NS}" "${QUAY_REGISTRY}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  images="$(app_images)"
  if [[ "${available}" == True && -n "${images}" ]]; then
    ready=true
    while IFS='=' read -r deployment image; do
      [[ -n "${deployment}" && -n "${image}" ]] || { ready=false; break; }
      desired="$(oc get deployment -n "${QUAY_NS}" "${deployment}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
      ready_replicas="$(oc get deployment -n "${QUAY_NS}" "${deployment}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
      [[ -n "${desired}" && "${desired}" == "${ready_replicas:-0}" ]] || { ready=false; break; }
    done <<<"${images}"
    [[ "${ready}" == true ]] && break
  fi
  sleep 15
done
[[ "${available:-}" == True && -n "${images:-}" && "${ready:-false}" == true ]] || fail "QuayRegistry and quay-app deployments did not become ready within ${UPGRADE_TIMEOUT}"
app_images >"${ARTIFACT_DIR}/quay-app-images-after.txt"

if cmp -s "${ARTIFACT_DIR}/quay-app-images-before.txt" "${ARTIFACT_DIR}/quay-app-images-after.txt"; then
  app_change='not observed (the operator CSV upgrade succeeded; no app-image change is claimed)'
else
  app_change='observed (quay-app image references changed)'
fi
cat >"${ARTIFACT_DIR}/summary.txt" <<EOF
source_catalog_image=${SOURCE_IMAGE}
source_channel=${SOURCE_CHANNEL}
source_installed_csv=${pre_csv}
target_catalog_image=${TARGET_IMAGE}
target_channel=${TARGET_CHANNEL}
target_installed_csv=${post_csv}
target_csv_phase=${post_phase}
quay_app_image_change=${app_change}
EOF
printf '%s\n' "${post_csv}" >"${SHARED_DIR}/quay-upgrade-target.csv"
printf '%s\n' "${TARGET_CHANNEL}" >"${SHARED_DIR}/quay-upgrade-target-channel"
echo "Quay operator upgrade succeeded: ${pre_csv} -> ${post_csv}; app image change ${app_change}."
