#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"

mkdir -p "${HOME}"/.ssh
BUNDLE_VERSION="$(crc version | grep -oP '^OpenShift version\s*:\s*\K\S+')"
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)
        BUNDLE_ARCH="amd64"
       ;;
    aarch64)
        BUNDLE_ARCH="arm64"
       ;;
    *)
        BUNDLE_ARCH=${ARCH}
       ;;
esac
BUNDLE=crc_hyperv_"${BUNDLE_VERSION}"_"${BUNDLE_ARCH}".crcbundle

mock-nss.sh

echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
export AZURE_AUTH_LOCATION

echo "Logging in with az"
AZURE_AUTH_CLIENT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .clientId)
AZURE_AUTH_CLIENT_SECRET=$(cat $AZURE_AUTH_LOCATION | jq -r .clientSecret)
AZURE_AUTH_TENANT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .tenantId)
AZURE_SUBSCRIPTION_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .subscriptionId)
az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID --output none
az account set --subscription ${AZURE_SUBSCRIPTION_ID}


cat  > "${HOME}"/run-tests.sh << 'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/home/packer:$PATH
mkdir -p /tmp/artifacts
sudo mv /tmp/crc /usr/bin/crc

function run-tests() {
  pushd crc
  set +e
  export PULL_SECRET_PATH="${HOME}"/pull-secret
  export BUNDLE_PATH="${HOME}"/$(cat "${HOME}"/bundle)
  make integration
  if [[ $? -ne 0 ]]; then
    exit 1
    popd
  fi
  popd
}

run-tests
EOF

chmod +x "${HOME}"/run-tests.sh

# Get the bundle
curl -L "https://storage.googleapis.com/crc-bundle-github-ci/${BUNDLE}" -o /tmp/${BUNDLE}

echo "${BUNDLE}" > "${HOME}"/bundle
