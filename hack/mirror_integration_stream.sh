#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${IMAGESTREAM_NAMESPACE:-origin}"
readonly NAMESPACE
NAME="${IMAGESTREAM_NAME:-4.17}"
readonly NAME
DRY_RUN="${DRY_RUN:-true}"

oc --context app.ci -n ci extract secret/registry-push-credentials-ci-images-mirror --to=- --keys .dockerconfigjson > /tmp/app.ci.push.config

TAGS="$(oc  --context app.ci get is -n "${NAMESPACE}" "${NAME}" -o json | jq -r '.status.tags[]|.tag')"
for tag in $TAGS; do
    echo "... $tag ..."
    if oc image info "quay.io/openshift/ci:${NAMESPACE}_${NAME}_${tag}" -a=/tmp/app.ci.push.config &>/dev/null ; then
        echo "skipped $tag"
        continue
    fi
    oc image mirror --dry-run="$DRY_RUN" --keep-manifest-list --registry-config=/tmp/app.ci.push.config \
      --continue-on-error=true --max-per-registry=20 \
      "registry.ci.openshift.org/${NAMESPACE}/${NAME}:${tag}"  "quay.io/openshift/ci:${NAMESPACE}_${NAME}_${tag}"
done
