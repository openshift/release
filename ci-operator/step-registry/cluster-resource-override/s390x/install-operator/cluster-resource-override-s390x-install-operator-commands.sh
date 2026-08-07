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
    echo "=== Skipping ImageDigestMirrorSet (no mirror repositories configured) ==="
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

patch_operator_images() {
  local csv
  if [[ -z "${CRO_OPERATOR_IMAGE}" && -z "${CRO_OPERAND_IMAGE}" ]]; then
    echo "=== Skipping image overrides (CRO_OPERATOR_IMAGE / CRO_OPERAND_IMAGE unset) ==="
    return 0
  fi

  csv="$(oc get subscription "${CRO_SUBSCRIPTION_NAME}" -n "${CRO_NAMESPACE}" -o jsonpath='{.status.installedCSV}')"
  if [[ -z "${csv}" ]]; then
    echo "ERROR: no installedCSV for ${CRO_SUBSCRIPTION_NAME}" >&2
    return 1
  fi

  echo "=== Patching CSV ${csv} images ==="
  echo "  operator: ${CRO_OPERATOR_IMAGE:-<unchanged>}"
  echo "  operand:  ${CRO_OPERAND_IMAGE:-<unchanged>}"

  oc get csv "${csv}" -n "${CRO_NAMESPACE}" -o json \
    | jq \
      --arg op_img "${CRO_OPERATOR_IMAGE}" \
      --arg operand_img "${CRO_OPERAND_IMAGE}" '
        def set_container_image:
          if $op_img != "" then
            (.spec.install.spec.deployments[]?
              | select(.name == "clusterresourceoverride-operator")
              | .spec.template.spec.containers[]?
              | select(.name == "clusterresourceoverride-operator")
              | .image) = $op_img
          else . end;
        def set_operand_env:
          if $operand_img != "" then
            (.spec.install.spec.deployments[]?
              | select(.name == "clusterresourceoverride-operator")
              | .spec.template.spec.containers[]?
              | select(.name == "clusterresourceoverride-operator")
              | .env[]?
              | select(.name == "OPERAND_IMAGE")
              | .value) = $operand_img
          else . end;
        def set_related_images:
          if (.spec.relatedImages|type) == "array" then
            .spec.relatedImages |= map(
              if $op_img != "" and (.name|test("operator";"i")) then .image = $op_img
              elif $operand_img != "" and (.name|test("operand|clusterresourceoverride";"i")) and (.name|test("operator";"i")|not) then .image = $operand_img
              else . end
            )
          else . end;
        set_container_image | set_operand_env | set_related_images
      ' \
    | oc apply -f -

  if [[ -n "${CRO_OPERATOR_IMAGE}" ]]; then
    oc set image deployment/clusterresourceoverride-operator \
      -n "${CRO_NAMESPACE}" \
      "clusterresourceoverride-operator=${CRO_OPERATOR_IMAGE}"
  fi
  if [[ -n "${CRO_OPERAND_IMAGE}" ]]; then
    oc set env deployment/clusterresourceoverride-operator \
      -n "${CRO_NAMESPACE}" \
      "OPERAND_IMAGE=${CRO_OPERAND_IMAGE}"
  fi

  oc rollout status deployment/clusterresourceoverride-operator \
    -n "${CRO_NAMESPACE}" --timeout=600s
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
  -n "${CRO_NAMESPACE}" --timeout=600s || true
oc get deployment,pods -n "${CRO_NAMESPACE}"

patch_operator_images

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
