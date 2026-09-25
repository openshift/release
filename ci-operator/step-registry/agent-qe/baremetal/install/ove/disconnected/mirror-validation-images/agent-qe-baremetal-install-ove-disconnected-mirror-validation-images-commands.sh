#!/bin/bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "=== Detecting KubeVirt release tag ==="
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n "${TARGET_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if [[ -z "${VIRT_OPERATOR_IMAGE}" ]]; then
  echo "ERROR: Could not find virt-operator deployment in ${TARGET_NAMESPACE}"
  exit 1
fi

CLUSTER_PULL_SECRET=$(mktemp)
trap 'rm -f "${CLUSTER_PULL_SECRET}"' EXIT
oc get secret/pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${CLUSTER_PULL_SECRET}"

KUBEVIRT_TAG=$(oc image info -a "${CLUSTER_PULL_SECRET}" "${VIRT_OPERATOR_IMAGE}" \
  -o json --filter-by-os=linux/amd64 2>/dev/null | \
  jq -r '.config.config.Labels["upstream-version"] // empty') || true

if [[ -z "${KUBEVIRT_TAG}" ]]; then
  KUBEVIRT_TAG=$(oc image info -a "${CLUSTER_PULL_SECRET}" "brew.${VIRT_OPERATOR_IMAGE}" \
    -o json --filter-by-os=linux/amd64 2>/dev/null | \
    jq -r '.config.config.Labels["upstream-version"] // empty') || true
fi

if [[ -z "${KUBEVIRT_TAG}" ]]; then
  CSV_VERSION=$(oc get csv -n "${TARGET_NAMESPACE}" -o json | \
    jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).spec.version') || true
  if [[ -n "${CSV_VERSION}" ]]; then
    KONFLUX_VERSION="v$(echo "${CSV_VERSION}" | cut -d. -f1)-$(echo "${CSV_VERSION}" | cut -d. -f2)"
    IMAGE_NAME_WITH_DIGEST=$(echo "${VIRT_OPERATOR_IMAGE}" | sed 's|.*/||')
    KONFLUX_IMAGE="quay.io/openshift-virtualization/konflux-builds/${KONFLUX_VERSION}/${IMAGE_NAME_WITH_DIGEST}"
    KUBEVIRT_TAG=$(oc image info -a "${CLUSTER_PULL_SECRET}" "${KONFLUX_IMAGE}" \
      -o json --filter-by-os=linux/amd64 2>/dev/null | \
      jq -r '.config.config.Labels["upstream-version"] // empty') || true
  fi
fi

if [[ -z "${KUBEVIRT_TAG}" ]]; then
  KUBEVIRT_RELEASE="v1.8.2"
  echo "WARNING: Could not auto-detect KubeVirt release tag. Using default: ${KUBEVIRT_RELEASE}"
else
  KUBEVIRT_RELEASE="v${KUBEVIRT_TAG%%-[0-9]*}"
  echo "Detected KubeVirt release: ${KUBEVIRT_RELEASE}"
fi

echo "=== Discovering validation checkup image ==="
CSV_NAME=$(oc get csv -n "${TARGET_NAMESPACE}" -o json | \
  jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).metadata.name')
OCP_VIRT_VALIDATION_IMAGE=$(oc get csv -n "${TARGET_NAMESPACE}" "${CSV_NAME}" -o json | \
  jq -r '.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image')
echo "Validation image: ${OCP_VIRT_VALIDATION_IMAGE}"

echo "=== Setting up internal registry ==="
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge --patch '{"spec":{"defaultRoute":true}}'

echo "Waiting for internal registry route..."
COUNTER=0
while [ $COUNTER -lt 120 ]; do
  INTERNAL_REGISTRY=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "${INTERNAL_REGISTRY}" ]]; then
    echo "Internal registry: ${INTERNAL_REGISTRY}"
    break
  fi
  sleep 10
  COUNTER=$((COUNTER + 10))
  echo "Waiting ${COUNTER}s for registry route..."
done

if [[ -z "${INTERNAL_REGISTRY}" ]]; then
  echo "ERROR: Internal registry route did not appear within 120s"
  oc get configs.imageregistry.operator.openshift.io/cluster -o yaml || true
  exit 1
fi

oc new-project kubevirt-mirror 2>/dev/null || true
oc policy add-role-to-group system:image-puller system:authenticated -n kubevirt-mirror 2>/dev/null || true
oc policy add-role-to-group system:image-puller system:unauthenticated -n kubevirt-mirror 2>/dev/null || true

oc create sa registry-pusher -n kubevirt-mirror 2>/dev/null || true
oc adm policy add-role-to-user system:image-builder -n kubevirt-mirror -z registry-pusher 2>/dev/null || true
LOGIN_TOKEN=$(oc create token registry-pusher -n kubevirt-mirror --duration=1h)
oc registry login --registry="${INTERNAL_REGISTRY}" --auth-basic="unused:${LOGIN_TOKEN}" --insecure=true

CI_AUTH_PATH="/var/run/secrets/ci-pull-credentials/.dockerconfigjson"
if [[ -f "${CI_AUTH_PATH}" ]]; then
  for registry in registry.redhat.io quay.io/openshift-virtualization/konflux-builds; do
    AUTH_B64=$(jq -r --arg r "${registry}" '.auths[$r].auth // empty' "${CI_AUTH_PATH}")
    if [[ -n "${AUTH_B64}" ]]; then
      AUTH=$(echo "${AUTH_B64}" | base64 -d)
      oc registry login --registry="${registry}" --auth-basic="${AUTH%%:*}:${AUTH#*:}" 2>/dev/null || true
    fi
  done
fi

mirror_image() {
  local src="$1" dst="$2"
  echo "  ${src} -> ${dst}"
  if ! oc image mirror --keep-manifest-list=true --insecure=true "${src}" "${dst}" 2>&1; then
    echo "  FAILED (non-fatal)"
  fi
}

do_mirror() {
  local TARGET="${INTERNAL_REGISTRY}/kubevirt-mirror"

  echo "=== Mirroring KubeVirt test images (${KUBEVIRT_RELEASE}) ==="
  for img in cirros-container-disk-demo alpine-container-disk-demo \
    fedora-with-test-tooling-container-disk alpine-with-test-tooling-container-disk \
    alpine-ext-kernel-boot-demo virtio-container-disk disks-images-provider vm-killer; do
    mirror_image "quay.io/kubevirt/${img}:${KUBEVIRT_RELEASE}" "${TARGET}/${img}:${KUBEVIRT_RELEASE}"
  done

  echo "=== Mirroring tier2 test images ==="
  mirror_image "quay.io/openshift-cnv/qe-cnv-tests-fedora:41" "${TARGET}/qe-cnv-tests-fedora:41"
  mirror_image "quay.io/openshift-cnv/qe-net-utils:latest" "${TARGET}/qe-net-utils:latest"

  echo "=== Mirroring results viewer ==="
  mirror_image "registry.redhat.io/rhel9/nginx-124:latest" "${TARGET}/nginx-124:latest"

  echo "=== Mirroring validation checkup image ==="
  local IMAGE_BASE
  IMAGE_BASE=$(echo "${OCP_VIRT_VALIDATION_IMAGE}" | sed 's|.*/||' | sed 's|[@:].*||')
  if ! oc image mirror --filter-by-os=linux/amd64 --insecure=true \
    "${OCP_VIRT_VALIDATION_IMAGE}" "${TARGET}/${IMAGE_BASE}:disconnected" 2>&1; then
    echo "  Direct mirror failed, trying IDMS mirrors..."
    local IMAGE_SOURCE_REPO
    IMAGE_SOURCE_REPO=$(echo "${OCP_VIRT_VALIDATION_IMAGE}" | sed 's|[@:].*||')
    local IMAGE_DIGEST
    IMAGE_DIGEST=$(echo "${OCP_VIRT_VALIDATION_IMAGE}" | grep -o '@sha256:[a-f0-9]*' || true)
    local MIRRORED=false
    if [[ -n "${IMAGE_DIGEST}" ]]; then
      for mirror in $(oc get imagedigestmirrorset -o json 2>/dev/null | \
        jq -r --arg src "${IMAGE_SOURCE_REPO}" \
        '.items[].spec.imageDigestMirrors[] | select(.source == $src) | .mirrors[]'); do
        if oc image mirror --filter-by-os=linux/amd64 --insecure=true \
          "${mirror}${IMAGE_DIGEST}" "${TARGET}/${IMAGE_BASE}:disconnected" 2>&1; then
          MIRRORED=true
          break
        fi
      done
    fi
    if [[ "${MIRRORED}" != "true" ]]; then
      echo "WARNING: Could not mirror validation image"
    fi
  fi
}

do_mirror

echo "=== Applying ImageTagMirrorSet and ImageDigestMirrorSet ==="
MIRROR_PREFIX="image-registry.openshift-image-registry.svc:5000/kubevirt-mirror"
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ocp-virt-validation-mirrors
spec:
  imageTagMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - ${MIRROR_PREFIX}
      mirrorSourcePolicy: NeverContactSource
    - source: quay.io/openshift-cnv
      mirrors:
        - ${MIRROR_PREFIX}
      mirrorSourcePolicy: NeverContactSource
    - source: registry.redhat.io/rhel9
      mirrors:
        - ${MIRROR_PREFIX}
      mirrorSourcePolicy: NeverContactSource
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ocp-virt-validation-digest-mirrors
spec:
  imageDigestMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - ${MIRROR_PREFIX}
      mirrorSourcePolicy: NeverContactSource
    - source: quay.io/openshift-cnv
      mirrors:
        - ${MIRROR_PREFIX}
      mirrorSourcePolicy: NeverContactSource
    - source: registry.redhat.io/rhel9
      mirrors:
        - ${MIRROR_PREFIX}
      mirrorSourcePolicy: NeverContactSource
EOF

echo "=== Waiting for MachineConfigPool rollout ==="
oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
sleep 30
oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
echo "MachineConfigPools stable"

echo "=== Re-mirroring images (registry pod may have restarted) ==="
LOGIN_TOKEN=$(oc create token registry-pusher -n kubevirt-mirror --duration=1h)
oc registry login --registry="${INTERNAL_REGISTRY}" --auth-basic="unused:${LOGIN_TOKEN}" --insecure=true
do_mirror

echo "=== Saving mirrored image reference ==="
IST_REF=$(oc get imagestreamtag -n kubevirt-mirror \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.image.dockerImageReference}{"\n"}{end}' 2>/dev/null | \
  grep "ocp-virt-validation-checkup-rhel9:disconnected" | awk '{print $2}') || true
if [[ -n "${IST_REF}" ]]; then
  echo "${IST_REF}" > "${SHARED_DIR}/validation-image-override"
  echo "Mirrored checkup image: ${IST_REF}"
else
  echo "WARNING: Could not resolve mirrored checkup image, will use original reference"
fi

echo "=== Mirror step complete ==="
