#!/usr/bin/env bash

set -euxo pipefail

CERTIFIED_OPERATOR_INDEX_REPO="registry.redhat.io/redhat/certified-operator-index"
COMMUNITY_OPERATOR_INDEX_REPO="registry.redhat.io/redhat/community-operator-index"
REDHAT_MARKETPLACE_INDEX_REPO="registry.redhat.io/redhat/redhat-marketplace-index"
REDHAT_OPERATOR_INDEX_REPO="registry.redhat.io/redhat/redhat-marketplace-index"

echo "Retrieving hash for the multi-arch index images"
CERTIFIED_OPERATOR_INDEX_HASH="$(oc image info "$CERTIFIED_OPERATOR_INDEX_REPO:v${HYPERSHIFT_HC_VERSION}" \
    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
COMMUNITY_OPERATOR_INDEX_HASH="$(oc image info "$COMMUNITY_OPERATOR_INDEX_REPO:v${HYPERSHIFT_HC_VERSION}" \
    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
REDHAT_MARKETPLACE_INDEX_HASH="$(oc image info "$REDHAT_MARKETPLACE_INDEX_REPO:v${HYPERSHIFT_HC_VERSION}" \
    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
REDHAT_OPERATOR_INDEX_HASH="$(oc image info "$REDHAT_OPERATOR_INDEX_REPO:v${HYPERSHIFT_HC_VERSION}" \
    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"

echo "Writing hosted cluster annotations to \$SHARED_DIR"
cat <<EOF >> "${SHARED_DIR}/hypershift_hc_annotations"
hypershift.openshift.io/pod-security-admission-label-override=baseline
hypershift.openshift.io/certified-operators-catalog-image=$CERTIFIED_OPERATOR_INDEX_REPO@$CERTIFIED_OPERATOR_INDEX_HASH
hypershift.openshift.io/community-operators-catalog-image=$COMMUNITY_OPERATOR_INDEX_REPO@$COMMUNITY_OPERATOR_INDEX_HASH
hypershift.openshift.io/redhat-marketplace-catalog-image=$REDHAT_MARKETPLACE_INDEX_REPO@$REDHAT_MARKETPLACE_INDEX_HASH
hypershift.openshift.io/redhat-operators-catalog-image=$REDHAT_OPERATOR_INDEX_REPO@$REDHAT_OPERATOR_INDEX_HASH
EOF
