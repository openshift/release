#!/bin/bash

set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function rosa_login() {
    # ROSA_VERSION=$(rosa version)
    ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")

    if [[ ! -z "${ROSA_TOKEN}" ]]; then
      echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
      rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
      ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
    else
      echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
      exit 1
    fi
}

function find_openshift_version() {
    # Get the openshift version
    CHANNEL_GROUP=stable
    version_cmd="rosa list versions --hosted-cp --channel-group ${CHANNEL_GROUP} -o json"
    version_cmd="$version_cmd | jq -r '.[].raw_id'"

    versionList=$(eval $version_cmd)
    echo -e "Available cluster versions:\n${versionList}"

    if [[ -z "$UPGRADED_TO_VERSION" ]]; then
      UPGRADED_TO_VERSION=$(echo "$versionList" | head -1)
    elif [[ $UPGRADED_TO_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
      UPGRADED_TO_VERSION=$(echo "$versionList" | grep -E "^${UPGRADED_TO_VERSION}" | head -1 || true)
    else
      # Match the whole line
      UPGRADED_TO_VERSION=$(echo "$versionList" | grep -x "${UPGRADED_TO_VERSION}" || true)
    fi

    if [[ -z "$UPGRADED_TO_VERSION" ]]; then
      echo "Requested cluster version not available!"
      exit 1
    fi
}

set_proxy
rosa_login
find_openshift_version

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION=${REGION}
export AWS_PAGER=""

# get cluster namesapce
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
if [[ -z "${CLUSTER_NAME}" ]] ; then
  echo "Error: cluster name not found"
  exit 1
fi

read -r namespace _ _  <<< "$(oc get cluster -A | grep ${CLUSTER_NAME})"
if [[ -z "${namespace}" ]]; then
  echo "capi cluster name not found error, ${CLUSTER_NAME}"
  exit 1
fi

echo "upgrade rosacontrolplane"
rosacontrolplane_name=$(oc get cluster "${CLUSTER_NAME}" -n "${namespace}" -ojsonpath='{.spec.controlPlaneRef.name}')
version=$(oc get rosacontrolplane ${rosacontrolplane_name} -n ${namespace} -ojsonpath='{.spec.version}')
echo "rosa controlplane version is $version now, begin to upgrade to $UPGRADED_TO_VERSION"
oc patch -n "${namespace}" --type=merge --patch='{"spec":{"version":"'"${UPGRADED_TO_VERSION}"'"}}' rosacontrolplane/${rosacontrolplane_name}
new_version=$(oc get rosacontrolplane ${rosacontrolplane_name} -n ${namespace} -ojsonpath='{.spec.version}')
echo "now rosacontrolplane version is ${new_version}"

CLUSTER_ID=$(cat $SHARED_DIR/cluster-id)
start_time=$(date +"%s")
while true; do
  sleep 150
  rosa_hcp_version=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.openshift_version')
  echo "rosa hcp version: ${rosa_hcp_version}"
  if [[ "${rosa_hcp_version}" == "${new_version}" ]]; then
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster cp upgrade ${rosa_hcp_version}"
    exit 1
  fi
done

echo "rosa hcp cp upgrade done"


