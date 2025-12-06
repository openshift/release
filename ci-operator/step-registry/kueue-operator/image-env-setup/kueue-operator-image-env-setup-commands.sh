#!/usr/bin/env bash
set -euxo pipefail

echo "Applying ImageDigestMirrorSet and ImageTagMirrorSet..."

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: kueue-digest-mirrorset
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERATOR_COMPONENT}
      source: registry.redhat.io/kueue/kueue-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERAND_COMPONENT}
      source: registry.redhat.io/kueue/kueue-rhel9
EOF

echo "Current PWD: $(pwd)"
ls -lah

# Check if we should use CI-built images
if [[ "${USE_CI_IMAGES}" == "true" && -n "${IMAGE_FORMAT:-}" ]]; then
  echo "Using CI-built images via IMAGE_FORMAT"

  # Use IMAGE_FORMAT to construct image references
  OPERATOR_IMAGE="${IMAGE_FORMAT//\$\{component\}/kueue-operator}"
  export OPERATOR_IMAGE
  echo "Operator image from CI: ${OPERATOR_IMAGE}"

  # Try to get operand image, but fall back if it doesn't exist
  OPERAND_IMAGE="${IMAGE_FORMAT//\$\{component\}/kueue-operand}"
  export OPERAND_IMAGE
  echo "Operand image from CI: ${OPERAND_IMAGE}"

  # Try to get must-gather image
  MUST_GATHER_IMAGE="${IMAGE_FORMAT//\$\{component\}/kueue-must-gather}"
  export MUST_GATHER_IMAGE
  echo "Must-gather image from CI: ${MUST_GATHER_IMAGE}"

  # Note: BUNDLE_IMAGE is not set here for CI images - it comes from dependencies
  # in the chain YAML (kueue-operator-bundle image dependency)
  echo "CI mode: BUNDLE_IMAGE will be set via dependencies in the chain"

  {
    echo "export OPERATOR_IMAGE=${OPERATOR_IMAGE}"
    echo "export OPERAND_IMAGE=${OPERAND_IMAGE}"
    echo "export MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE}"
  } >> "${SHARED_DIR}/env"
else
  echo "Using Konflux-built images"
  REVISION=$(git log --oneline -1 | awk '{print $4}' | tr -d "'")
  echo "Current Git branch:"
  git branch --show-current
  echo "Latest Git commits:"
  git log --oneline -5
  echo "Git status:"
  git status

  export OPERATOR_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERATOR_COMPONENT}:on-pr-${REVISION}"
  export OPERAND_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERAND_COMPONENT}:on-pr-${REVISION}"
  export MUST_GATHER_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${MUST_GATHER_COMPONENT}:on-pr-${REVISION}"

  {
    echo "export OPERATOR_IMAGE=${OPERATOR_IMAGE}"
    echo "export OPERAND_IMAGE=${OPERAND_IMAGE}"
    echo "export MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE}"
  } >> "${SHARED_DIR}/env"

  REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/${BUNDLE_COMPONENT}"
  BUNDLE_IMAGE=$(skopeo list-tags "docker://${REPO}" | jq -r '.Tags[]' | grep -E '^[a-f0-9]{40}$' | while read -r tag; do
      created=$(skopeo inspect "docker://${REPO}:${tag}" 2>/dev/null | jq -r '.Created')
      if [ "$created" != "null" ] && [ -n "$created" ]; then echo "$created $tag"; fi
  done | sort | tail -n1 | awk -v repo="$REPO" '{print repo ":" $2}')

  if [[ -z "$BUNDLE_IMAGE" ]]; then
    echo "ERROR: Failed to resolve BUNDLE_IMAGE from ${REPO}"
    exit 1
  fi

  echo "Resolved BUNDLE_IMAGE: ${BUNDLE_IMAGE}"
  echo "export BUNDLE_IMAGE=${BUNDLE_IMAGE}" >> "${SHARED_DIR}/env"
fi

oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite
