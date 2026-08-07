#!/bin/bash

set -euo pipefail

wait_for_csv() {
  local ns="$1" sub="$2" csv phase
  echo "Waiting for CSV of subscription ${sub} in ${ns} ..."
  for _ in $(seq 1 90); do
    csv="$(oc get subscription "${sub}" -n "${ns}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    if [[ -n "${csv}" ]]; then
      phase="$(oc get csv "${csv}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      echo "  ${csv} phase: ${phase:-<none>}"
      [[ "${phase}" == "Succeeded" ]] && return 0
    fi
    sleep 10
  done
  echo "ERROR: CSV for ${sub} did not reach Succeeded" >&2
  oc get subscription "${sub}" -n "${ns}" -o yaml >&2 || true
  oc get csv -n "${ns}" -o yaml >&2 || true
  oc get events -n "${ns}" --sort-by='.lastTimestamp' | tail -30 >&2 || true
  return 1
}

apply_idms_if_configured() {
  if [[ -z "${CRO_MIRROR_OPERATOR_IMAGE}" && -z "${CRO_MIRROR_OPERAND_IMAGE}" ]]; then
    echo "=== Skipping ImageDigestMirrorSet (no mirror images configured) ==="
    return 0
  fi

  echo "=== Applying ImageDigestMirrorSet ${CRO_IDMS_NAME} (image source change) ==="
  {
    echo "apiVersion: config.openshift.io/v1"
    echo "kind: ImageDigestMirrorSet"
    echo "metadata:"
    echo "  name: ${CRO_IDMS_NAME}"
    echo "spec:"
    echo "  imageDigestMirrors:"
    if [[ -n "${CRO_MIRROR_OPERATOR_IMAGE}" ]]; then
      echo "  - source: ${CRO_SOURCE_OPERATOR_IMAGE}"
      echo "    mirrors:"
      echo "    - ${CRO_MIRROR_OPERATOR_IMAGE}"
    fi
    if [[ -n "${CRO_MIRROR_OPERAND_IMAGE}" ]]; then
      echo "  - source: ${CRO_SOURCE_OPERAND_IMAGE}"
      echo "    mirrors:"
      echo "    - ${CRO_MIRROR_OPERAND_IMAGE}"
    fi
  } | oc apply -f -
}

echo "=== Ensuring operator namespace ${CRO_NAMESPACE} ==="
oc get ns "${CRO_NAMESPACE}" >/dev/null 2>&1 || oc create ns "${CRO_NAMESPACE}"

apply_idms_if_configured

echo "=== Waiting for PackageManifest ${CRO_PACKAGE_NAME} from ${CRO_CATALOG_SOURCE} ==="
for i in $(seq 1 36); do
  if oc get packagemanifest -n openshift-marketplace "${CRO_PACKAGE_NAME}" >/dev/null 2>&1; then
    echo "PackageManifest found."
    break
  fi
  echo "Waiting for PackageManifest... (${i}/36)"
  sleep 10
done

if ! oc get packagemanifest -n openshift-marketplace "${CRO_PACKAGE_NAME}" >/dev/null 2>&1; then
  echo "ERROR: PackageManifest '${CRO_PACKAGE_NAME}' not found in openshift-marketplace" >&2
  oc get packagemanifest -n openshift-marketplace 2>/dev/null | grep -i clusterresource || true
  oc get catalogsource -n "${CRO_CATALOG_SOURCE_NAMESPACE}" -o wide >&2 || true
  exit 1
fi

echo "=== Creating OperatorGroup and Subscription ==="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: clusterresourceoverride-operator
  namespace: ${CRO_NAMESPACE}
spec:
  targetNamespaces:
  - ${CRO_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${CRO_SUBSCRIPTION_NAME}
  namespace: ${CRO_NAMESPACE}
spec:
  channel: ${CRO_CHANNEL}
  installPlanApproval: Automatic
  name: ${CRO_PACKAGE_NAME}
  source: ${CRO_CATALOG_SOURCE}
  sourceNamespace: ${CRO_CATALOG_SOURCE_NAMESPACE}
EOF

wait_for_csv "${CRO_NAMESPACE}" "${CRO_SUBSCRIPTION_NAME}"

echo "=== Waiting for operator Deployment Available ==="
oc wait --for=condition=Available deployment/clusterresourceoverride-operator \
  -n "${CRO_NAMESPACE}" --timeout=600s
oc get deployment,pods -n "${CRO_NAMESPACE}"

if [[ "${CRO_CREATE_CR}" == "true" ]]; then
  echo "=== Creating ClusterResourceOverride CR ==="
  cat <<EOF | oc apply -f -
apiVersion: operator.autoscaling.openshift.io/v1
kind: ClusterResourceOverride
metadata:
  name: cluster
  namespace: ${CRO_NAMESPACE}
spec:
  podResourceOverride:
    spec:
      memoryRequestToLimitPercent: 50
      cpuRequestToLimitPercent: 25
      limitCPUToMemoryPercent: 200
EOF
  oc get clusterresourceoverride cluster -n "${CRO_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/clusterresourceoverride-cr.yaml" || true
fi

echo "=== ClusterResourceOverride operator install complete ==="
