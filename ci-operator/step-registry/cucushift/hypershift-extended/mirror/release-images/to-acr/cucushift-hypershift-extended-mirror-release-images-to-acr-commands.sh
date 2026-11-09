#!/usr/bin/env bash

set -euxo pipefail

ACR_NAME="$(</var/run/vault/preservehypershiftaks/name)"
ACR_LOGIN_SERVER="$(</var/run/vault/preservehypershiftaks/loginserver)"
ACR_REPO_NAME="release-$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c -5)"
ACR_REPO="$ACR_LOGIN_SERVER/$ACR_REPO_NAME"

PULL_SECRET_PATH="$CLUSTER_PROFILE_DIR"/pull-secret
if [[ -f "${SHARED_DIR}"/hypershift-pull-secret ]]; then
    PULL_SECRET_PATH="${SHARED_DIR}"/hypershift-pull-secret
fi

echo "az acr repository delete --name $ACR_NAME --repository $ACR_REPO_NAME -y" >> "${SHARED_DIR}/remove_resources_by_cli.sh"
oc adm release mirror --from "$RELEASE_IMAGE_LATEST" --to "$ACR_REPO" -a "$PULL_SECRET_PATH" --max-per-registry=2
cat <<EOF >> "$SHARED_DIR"/hypershift_operator_registry_overrides
quay.io/openshift-release-dev/ocp-v4.0-art-dev=$ACR_REPO
quay.io/openshift-release-dev/ocp-release=$ACR_REPO
EOF
