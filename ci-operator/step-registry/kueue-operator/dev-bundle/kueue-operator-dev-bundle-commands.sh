#!/usr/bin/env bash

echo "Current PWD: $(pwd)"
ls -lah
echo "Current Git branch:"
git branch --show-current

echo "Latest Git commits:"
git log --oneline -5
echo "Git status:"
git status
REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-bundle-dev-main"
BUNDLE_IMAGE=$(skopeo list-tags docker://$REPO | jq -r '.Tags[]' | grep -E '^[a-f0-9]{40}$' | while read -r tag; do
    created=$(skopeo inspect docker://$REPO:$tag 2>/dev/null | jq -r '.Created')
    if [ "$created" != "null" ] && [ -n "$created" ]; then echo "$created $tag"; fi
done | sort | tail -n1 | awk -v repo="$REPO" '{print repo ":" $2}')

if [[ -z "$BUNDLE_IMAGE" ]]; then
  echo "ERROR: Failed to resolve BUNDLE_IMAGE from $REPO"
  exit 1
fi

echo "Resolved BUNDLE_IMAGE: ${BUNDLE_IMAGE}"
echo "export BUNDLE_IMAGE=${BUNDLE_IMAGE}" >> "${SHARED_DIR}/env"

oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite
