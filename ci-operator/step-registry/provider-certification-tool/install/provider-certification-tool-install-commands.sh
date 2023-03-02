#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Downloading latest stable
REPO_ORG="redhat-openshift-ecosystem"
REPO_NAME="provider-certification-tool"
BIN_NAME="openshift-provider-cert"
BIN_OS="linux"
BIN_ARCH="amd64"
OPCT_EXEC="${ARTIFACT_DIR}/${BIN_NAME}-${BIN_OS}-${BIN_ARCH}-latest"

LATEST_URL=$(curl -s https://api.github.com/repos/${REPO_ORG}/${REPO_NAME}/releases/latest \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["tarball_url"])')
LATEST_VERSION=$(basename "${LATEST_URL}")
BIN_URL="https://github.com/${REPO_ORG}/${REPO_NAME}/releases/download/${LATEST_VERSION}/${BIN_NAME}-${BIN_OS}-${BIN_ARCH}"

echo "Downloading OPCT binary from $BIN_URL"
curl -o "${OPCT_EXEC}" -LJO "${BIN_URL}"
chmod u+x "${OPCT_EXEC}"

test -x "${OPCT_EXEC}" && echo "OPCT binary ${OPCT_EXEC} found and ready to be used on the version $LATEST_VERSION"

cat <<EOF > "${SHARED_DIR}/install-env"
OPCT_EXEC=$OPCT_EXEC
LATEST_VERSION=$LATEST_VERSION
BIN_URL=$BIN_URL
EOF

cp "${SHARED_DIR}/install-env" "${ARTIFACT_DIR}/install-env"