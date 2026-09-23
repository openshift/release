#!/usr/bin/env bash

set -euxo pipefail

ACR_LOGIN_SERVER="$(</var/run/vault/preservehypershiftaks/loginserver)"
ACR_REPO_NAME="release-$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c -5)"
ACR_REPO="$ACR_LOGIN_SERVER/$ACR_REPO_NAME"

PULL_SECRET_PATH="$CLUSTER_PROFILE_DIR"/pull-secret
if [[ -f "${SHARED_DIR}"/hypershift-pull-secret ]]; then
    PULL_SECRET_PATH="${SHARED_DIR}"/hypershift-pull-secret
fi

oc adm release mirror --from "$RELEASE_IMAGE_TARGET" --to "$ACR_REPO" -a "$PULL_SECRET_PATH" --max-per-registry=2
