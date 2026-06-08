#!/usr/bin/env bash

set -euxo pipefail

cat <<EOF >> "${SHARED_DIR}/hypershift_hc_annotations"
hypershift.openshift.io/pod-security-admission-label-override=baseline
EOF

## No need to annotate catalog images on HC when OLM is placed on the guest cluster
#if [[ $HYPERSHIFT_OLM_CATALOG_PLACEMENT == "guest" ]]; then
#    echo "OLM placed on guest cluster, no need for catalog image annotations"
#    exit 0
#fi
#
#if [[ -z $HYPERSHIFT_CATALOG_IMAGE_VERSION ]]; then
#    echo "error: HYPERSHIFT_CATALOG_IMAGE_VERSION must not be empty when OLM is placed on the management cluster" >&2
#    exit 1
#fi
#
#CERTIFIED_OPERATOR_INDEX_REPO="registry.redhat.io/redhat/certified-operator-index"
#COMMUNITY_OPERATOR_INDEX_REPO="registry.redhat.io/redhat/community-operator-index"
#REDHAT_MARKETPLACE_INDEX_REPO="registry.redhat.io/redhat/redhat-marketplace-index"
#REDHAT_OPERATOR_INDEX_REPO="registry.redhat.io/redhat/redhat-operator-index"
#
#echo "Retrieving hash for the multi-arch index images"
#CERTIFIED_OPERATOR_INDEX_HASH="$(oc image info "$CERTIFIED_OPERATOR_INDEX_REPO:v${HYPERSHIFT_CATALOG_IMAGE_VERSION}" \
#    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
#COMMUNITY_OPERATOR_INDEX_HASH="$(oc image info "$COMMUNITY_OPERATOR_INDEX_REPO:v${HYPERSHIFT_CATALOG_IMAGE_VERSION}" \
#    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
#REDHAT_MARKETPLACE_INDEX_HASH="$(oc image info "$REDHAT_MARKETPLACE_INDEX_REPO:v${HYPERSHIFT_CATALOG_IMAGE_VERSION}" \
#    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
#REDHAT_OPERATOR_INDEX_HASH="$(oc image info "$REDHAT_OPERATOR_INDEX_REPO:v${HYPERSHIFT_CATALOG_IMAGE_VERSION}" \
#    -a "${CLUSTER_PROFILE_DIR}/pull-secret" --filter-by-os linux/amd64 -o json | jq -r .listDigest)"
#
#echo "Writing hosted cluster annotations to \$SHARED_DIR"
#cat <<EOF >> "${SHARED_DIR}/hypershift_hc_annotations"
#hypershift.openshift.io/certified-operators-catalog-image=$CERTIFIED_OPERATOR_INDEX_REPO@$CERTIFIED_OPERATOR_INDEX_HASH
#hypershift.openshift.io/community-operators-catalog-image=$COMMUNITY_OPERATOR_INDEX_REPO@$COMMUNITY_OPERATOR_INDEX_HASH
#hypershift.openshift.io/redhat-marketplace-catalog-image=$REDHAT_MARKETPLACE_INDEX_REPO@$REDHAT_MARKETPLACE_INDEX_HASH
#hypershift.openshift.io/redhat-operators-catalog-image=$REDHAT_OPERATOR_INDEX_REPO@$REDHAT_OPERATOR_INDEX_HASH
#EOF
