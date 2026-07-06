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
REVISION=$(git log --oneline -1 | awk '{print $4}' | tr -d "'")
echo "Current Git branch:"
git branch --show-current

echo "Latest Git commits:"
git log --oneline -5
echo "Git status:"
git status
export OPERATOR_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERATOR_COMPONENT}:on-pr-${REVISION}"
echo "export OPERATOR_IMAGE=${OPERATOR_IMAGE}" >> "${SHARED_DIR}/env"

resolve_latest_image() {
  local repo=$1
  skopeo list-tags "docker://$repo" | jq -r '.Tags[]' | grep -E '^[a-f0-9]{40}$' | while read -r tag; do
    created=$(skopeo inspect "docker://$repo:$tag" 2>/dev/null | jq -r '.Created')
    if [ "$created" != "null" ] && [ -n "$created" ]; then echo "$created $tag"; fi
  done | sort | tail -n1 | awk -v repo="$repo" '{print repo ":" $2}'
}

OPERAND_REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERAND_COMPONENT}"
OPERAND_IMAGE=$(resolve_latest_image "$OPERAND_REPO")
if [[ -z "$OPERAND_IMAGE" ]]; then
  echo "ERROR: Failed to resolve OPERAND_IMAGE from $OPERAND_REPO"
  exit 1
fi
echo "Resolved OPERAND_IMAGE: ${OPERAND_IMAGE}"
echo "export OPERAND_IMAGE=${OPERAND_IMAGE}" >> "${SHARED_DIR}/env"

BUNDLE_REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/${BUNDLE_COMPONENT}"
BUNDLE_IMAGE=$(resolve_latest_image "$BUNDLE_REPO")
if [[ -z "$BUNDLE_IMAGE" ]]; then
  echo "ERROR: Failed to resolve BUNDLE_IMAGE from $BUNDLE_REPO"
  exit 1
fi
echo "Resolved BUNDLE_IMAGE: ${BUNDLE_IMAGE}"
echo "export BUNDLE_IMAGE=${BUNDLE_IMAGE}" >> "${SHARED_DIR}/env"

oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite
