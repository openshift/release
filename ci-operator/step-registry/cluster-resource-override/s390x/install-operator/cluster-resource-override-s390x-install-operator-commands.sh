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
  dump_deployment_debug "csv-not-succeeded"
  return 1
}

dump_deployment_debug() {
  local reason="${1:-deployment-failure}"
  local out="${ARTIFACT_DIR}/cro-deploy-debug-${reason}"
  mkdir -p "${out}"

  echo "=== DEBUG (${reason}): dumping operator deployment state to ${out} ===" >&2

  {
    echo "=== reason: ${reason} ==="
    echo "=== namespace: ${CRO_NAMESPACE} ==="
    echo "=== CRO_OPERATOR_IMAGE=${CRO_OPERATOR_IMAGE:-<unset>} ==="
    echo "=== CRO_OPERAND_IMAGE=${CRO_OPERAND_IMAGE:-<unset>} ==="
    date -u +"=== timestamp: %Y-%m-%dT%H:%M:%SZ ==="
  } >"${out}/summary.txt" 2>&1 || true

  oc get all,csv,subscription,installplan,operatorgroup -n "${CRO_NAMESPACE}" -o wide \
    >"${out}/get-all-wide.txt" 2>&1 || true
  oc get deployment,rs,pods -n "${CRO_NAMESPACE}" -o yaml \
    >"${out}/workload.yaml" 2>&1 || true
  oc describe deployment/clusterresourceoverride-operator -n "${CRO_NAMESPACE}" \
    >"${out}/describe-deployment.txt" 2>&1 || true
  oc get pods -n "${CRO_NAMESPACE}" -o wide \
    >"${out}/pods-wide.txt" 2>&1 || true
  oc get pods -n "${CRO_NAMESPACE}" -o json \
    >"${out}/pods.json" 2>&1 || true
  oc get events -n "${CRO_NAMESPACE}" --sort-by='.lastTimestamp' \
    >"${out}/events.txt" 2>&1 || true

  # Per-pod details (image pull / crashloop)
  local pod
  for pod in $(oc get pods -n "${CRO_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc describe pod "${pod}" -n "${CRO_NAMESPACE}" \
      >"${out}/describe-pod-${pod}.txt" 2>&1 || true
    oc logs "${pod}" -n "${CRO_NAMESPACE}" --all-containers --tail=200 \
      >"${out}/logs-pod-${pod}.txt" 2>&1 || true
    oc get pod "${pod}" -n "${CRO_NAMESPACE}" -o jsonpath='{.spec.containers[*].image}{"\n"}{.status.containerStatuses[*].image}{"\n"}{.status.containerStatuses[*].imageID}{"\n"}{.status.containerStatuses[*].state}{"\n"}' \
      >"${out}/images-pod-${pod}.txt" 2>&1 || true
  done

  local csv
  csv="$(oc get subscription "${CRO_SUBSCRIPTION_NAME}" -n "${CRO_NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  if [[ -n "${csv}" ]]; then
    oc get csv "${csv}" -n "${CRO_NAMESPACE}" -o yaml >"${out}/csv.yaml" 2>&1 || true
    oc describe csv "${csv}" -n "${CRO_NAMESPACE}" >"${out}/describe-csv.txt" 2>&1 || true
  fi

  # Also echo a short digest into the build log for quick triage
  echo "=== DEBUG (${reason}): deployments/pods ===" >&2
  oc get deployment,pods -n "${CRO_NAMESPACE}" -o wide >&2 || true
  echo "=== DEBUG (${reason}): recent events ===" >&2
  oc get events -n "${CRO_NAMESPACE}" --sort-by='.lastTimestamp' | tail -40 >&2 || true
  echo "=== DEBUG (${reason}): pod images/state ===" >&2
  oc get pods -n "${CRO_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.image}{"\t"}{.state}{"\n"}{end}{end}' >&2 || true
  echo "=== DEBUG (${reason}): full dump under ${out} ===" >&2
}

apply_idms_if_configured() {
  if [[ -z "${CRO_MIRROR_OPERATOR_IMAGE}" && -z "${CRO_MIRROR_OPERAND_IMAGE}" ]]; then
    echo "=== Skipping ImageDigestMirrorSet (no CRO_MIRROR_* repositories configured) ==="
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

# Match secrets-store / Konflux ART weekly jobs: pull-secret for art-images-share +
# IDMS so registry.redhat.io/openshift{4,5}/ose-clusterresourceoverride-* digests
# resolve from quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share.
setup_art_image_share_access() {
  if [[ -z "${CRO_ART_IMAGE_SHARE}" ]]; then
    echo "=== Skipping ART image-share access (CRO_ART_IMAGE_SHARE unset) ==="
    return 0
  fi

  local art_pull_secret="${CRO_ART_PULL_SECRET_PATH}"
  if [[ ! -f "${art_pull_secret}" ]]; then
    echo "ERROR: ART image-share pull secret not found at ${art_pull_secret}" >&2
    echo "Mount credentials secret deploy-konflux-operator-art-image-share (test-credentials)." >&2
    return 1
  fi

  echo "=== Merging ART image-share credentials into cluster pull-secret ==="
  # Disable tracing due to pull-secret handling
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  mkdir -p /tmp/cro-pull-secret
  oc extract secret/pull-secret -n openshift-config --confirm --to /tmp/cro-pull-secret
  jq -s '.[0].auths += .[1].auths | .[0]' \
    /tmp/cro-pull-secret/.dockerconfigjson \
    "${art_pull_secret}" > /tmp/cro-merged-pullsecret.json
  oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson=/tmp/cro-merged-pullsecret.json
  rm -rf /tmp/cro-pull-secret /tmp/cro-merged-pullsecret.json
  $WAS_TRACING && set -x

  echo "=== Applying ImageDigestMirrorSet ${CRO_IDMS_NAME} -> ${CRO_ART_IMAGE_SHARE} ==="
  cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${CRO_IDMS_NAME}
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/openshift5/ose-clusterresourceoverride-operator-bundle
    mirrors:
    - ${CRO_ART_IMAGE_SHARE}
  - source: registry.redhat.io/openshift5/ose-clusterresourceoverride-rhel9-operator
    mirrors:
    - ${CRO_ART_IMAGE_SHARE}
  - source: registry.redhat.io/openshift5/ose-clusterresourceoverride-rhel9
    mirrors:
    - ${CRO_ART_IMAGE_SHARE}
  - source: registry.redhat.io/openshift4/ose-clusterresourceoverride-operator-bundle
    mirrors:
    - ${CRO_ART_IMAGE_SHARE}
  - source: registry.redhat.io/openshift4/ose-clusterresourceoverride-rhel9-operator
    mirrors:
    - ${CRO_ART_IMAGE_SHARE}
  - source: registry.redhat.io/openshift4/ose-clusterresourceoverride-rhel9
    mirrors:
    - ${CRO_ART_IMAGE_SHARE}
EOF

  echo "=== Waiting for MachineConfigPools after pull-secret/IDMS update ==="
  sleep 60
  oc wait mcp/master --for condition=Updated --timeout=15m
  oc wait mcp/worker --for condition=Updated --timeout=15m
  echo "MachineConfigPools are Updated"
}

ensure_catalog_source() {
  if [[ -z "${CRO_CATALOG_IMAGE}" ]]; then
    echo "=== Using existing CatalogSource ${CRO_CATALOG_SOURCE} (CRO_CATALOG_IMAGE unset) ==="
    return 0
  fi

  echo "=== Creating CatalogSource ${CRO_CATALOG_SOURCE} from ${CRO_CATALOG_IMAGE} ==="
  oc delete catalogsource "${CRO_CATALOG_SOURCE}" -n "${CRO_CATALOG_SOURCE_NAMESPACE}" --ignore-not-found=true

  # OCP 4.15+ / modern kube: use extractContent cache (OCPBUGS-31427)
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CRO_CATALOG_SOURCE}
  namespace: ${CRO_CATALOG_SOURCE_NAMESPACE}
spec:
  displayName: ClusterResourceOverride ART FBC
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
  image: ${CRO_CATALOG_IMAGE}
  publisher: OpenShift CI
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

  local status=""
  local i
  for i in $(seq 1 60); do
    status="$(oc -n "${CRO_CATALOG_SOURCE_NAMESPACE}" get catalogsource "${CRO_CATALOG_SOURCE}" \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
    if [[ "${status}" == "READY" ]]; then
      echo "CatalogSource ${CRO_CATALOG_SOURCE} is READY"
      return 0
    fi
    echo "Waiting for CatalogSource READY... (${i}/60) state=${status:-<none>}"
    sleep 10
  done

  echo "ERROR: CatalogSource ${CRO_CATALOG_SOURCE} did not become READY" >&2
  oc -n "${CRO_CATALOG_SOURCE_NAMESPACE}" get catalogsource "${CRO_CATALOG_SOURCE}" -o yaml >&2 || true
  oc -n "${CRO_CATALOG_SOURCE_NAMESPACE}" get pods -l "olm.catalogSource=${CRO_CATALOG_SOURCE}" -o wide >&2 || true
  oc -n "${CRO_CATALOG_SOURCE_NAMESPACE}" get pods -l "olm.catalogSource=${CRO_CATALOG_SOURCE}" -o yaml >&2 || true
  return 1
}

package_manifest_ready() {
  oc get packagemanifest -n openshift-marketplace -o json \
    | jq -e \
      --arg pkg "${CRO_PACKAGE_NAME}" \
      --arg src "${CRO_CATALOG_SOURCE}" '
        .items[]
        | select(.status.catalogSource == $src)
        | select(
            .metadata.name == $pkg
            or (.status.packageName // "") == $pkg
          )
      ' >/dev/null 2>&1
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

  echo "=== Pre-override deployment images ==="
  oc get deployment/clusterresourceoverride-operator -n "${CRO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[*].name}{" -> "}{.spec.template.spec.containers[*].image}{"\n"}' || true

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

  echo "=== Post-override deployment images ==="
  oc get deployment/clusterresourceoverride-operator -n "${CRO_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[*].name}{" -> "}{.spec.template.spec.containers[*].image}{"\n"}' || true
  oc set env deployment/clusterresourceoverride-operator -n "${CRO_NAMESPACE}" --list 2>/dev/null | grep -E 'OPERAND_IMAGE|RELATED' || true

  if ! oc rollout status deployment/clusterresourceoverride-operator \
    -n "${CRO_NAMESPACE}" --timeout=600s; then
    dump_deployment_debug "rollout-after-image-patch"
    return 1
  fi
}

echo "=== Ensuring operator namespace ${CRO_NAMESPACE} ==="
oc get ns "${CRO_NAMESPACE}" >/dev/null 2>&1 || oc create ns "${CRO_NAMESPACE}"

setup_art_image_share_access
apply_idms_if_configured
ensure_catalog_source

echo "=== Waiting for PackageManifest ${CRO_PACKAGE_NAME} from CatalogSource ${CRO_CATALOG_SOURCE} ==="
for i in $(seq 1 36); do
  if package_manifest_ready; then
    echo "PackageManifest found from ${CRO_CATALOG_SOURCE}."
    break
  fi
  echo "Waiting for PackageManifest... (${i}/36)"
  sleep 10
done

if ! package_manifest_ready; then
  echo "ERROR: PackageManifest '${CRO_PACKAGE_NAME}' not found from CatalogSource '${CRO_CATALOG_SOURCE}'" >&2
  oc get packagemanifest -n openshift-marketplace -o wide 2>/dev/null | grep -i clusterresource || true
  oc get packagemanifest -n openshift-marketplace -o json \
    | jq -r --arg pkg "${CRO_PACKAGE_NAME}" \
      '.items[] | select(.metadata.name == $pkg) | [.metadata.name, .status.catalogSource, .status.catalogSourceNamespace] | @tsv' \
    >&2 || true
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

echo "=== Waiting for operator Deployment Available (catalog images, pre-patch) ==="
if ! oc wait --for=condition=Available deployment/clusterresourceoverride-operator \
  -n "${CRO_NAMESPACE}" --timeout=600s; then
  dump_deployment_debug "pre-patch-not-available"
  exit 1
fi
oc get deployment,pods -n "${CRO_NAMESPACE}" -o wide
echo "=== Catalog (pre-patch) operator image ==="
oc get deployment/clusterresourceoverride-operator -n "${CRO_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}' || true

patch_operator_images

echo "=== Waiting for operator Deployment Available (post-patch) ==="
if ! oc wait --for=condition=Available deployment/clusterresourceoverride-operator \
  -n "${CRO_NAMESPACE}" --timeout=600s; then
  dump_deployment_debug "post-patch-not-available"
  exit 1
fi
oc get deployment,pods -n "${CRO_NAMESPACE}" -o wide

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
