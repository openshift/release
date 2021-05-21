#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_NAME=${CLUSTER_NAME:-$NAMESPACE}
CLUSTER_VERSION=${CLUSTER_VERSION:-}
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id")
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret")

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
OCM_CREATE_ARGS=""
if [[ -f "${AWSCRED}" ]]; then
  # Gather fields from the cluster_profile secret
  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
  AWS_ACCOUNT_ID=$(cat "${CLUSTER_PROFILE_DIR}/aws-account-id")
  OCM_CREATE_ARGS="--aws-account-id ${AWS_ACCOUNT_ID} --aws-access-key-id ${AWS_ACCESS_KEY_ID} --aws-secret-access-key ${AWS_SECRET_ACCESS_KEY}"

  # Set defaults for AWS if necessary
  COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
  declare -a AWS_REGIONS=('us-east-1' 'us-east-2' 'us-west-1' 'us-west-2')
  RAND_REGION="${AWS_REGIONS[$RANDOM % ${#AWS_REGIONS[@]}]}"
  CLOUD_PROVIDER_REGION=${CLOUD_PROVIDER_REGION:-"${RAND_REGION}"}
  echo "Will launch in AWS region: ${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

export HOME=${SHARED_DIR}
mkdir -p "${HOME}"
echo "Logging into ${OCM_LOGIN_URL} SSO"
ocm login --url "${OCM_LOGIN_URL}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"

OLD_CLUSTER_ID=$(ocm list clusters --columns=id --parameter search="name is '${CLUSTER_NAME}'" | tail -n 1)
if [[ "$OLD_CLUSTER_ID" != ID* ]]; then
  # A cluster id was returned; not just the ID column heading.
  # Previous cluster was orphaned somehow. Shut it down.
  echo "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster-id: ${OLD_CLUSTER_ID}"
  exit 1
fi

CLUSTER_INFO="${ARTIFACT_DIR}/ocm-cluster.txt"

echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Compute nodes: ${COMPUTE_NODES}"
echo "  Cluster version: ${CLUSTER_VERSION}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Cloud provider region: ${CLOUD_PROVIDER_REGION}"
ocm create cluster ${OCM_CREATE_ARGS} \
                   --ccs "${CLUSTER_NAME}" \
                   --compute-nodes "${COMPUTE_NODES}" \
                   --version "${CLUSTER_VERSION}" \
                   --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
                   --region "${CLOUD_PROVIDER_REGION}" \
                   > "${CLUSTER_INFO}"

CLUSTER_ID=$(cat "${CLUSTER_INFO}" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"

# By default, OSD will setup clusters running for a few days before they expire.
# In case things go wrong in our flow, give the cluster an initial expiration
# that will minimize wasted compute if post steps are not successful.
# After installation, the expiration will be bumped according to CLUSTER_DURATION.
INIT_EXPIRATION_DATE=$(date -u -d "+3hours" "+%Y-%m-%dT%H:%M:%S.00000Z")
echo '{ "expiration_timestamp": "'"${INIT_EXPIRATION_DATE}"'" }' | ocm patch "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"

# Store the cluster ID for the delete operation
echo -n "${CLUSTER_ID}" > "${HOME}/cluster-id"

echo "Waiting for cluster ready..."
while true; do
  sleep 60
  CLUSTER_STATE=$(ocm cluster status "${CLUSTER_ID}" | grep 'State:' | tr -d '[:space:]' | cut -d ':' -f 2)
  echo "Cluster state: ${CLUSTER_STATE}"
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    echo "Cluster is reported as ready"
    break
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" ]]; then
    ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.osd_install.log" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 1
  fi
done

if [[ -n "${CLUSTER_DURATION}" ]]; then
  # Set the expiration according to desired cluster TTL
  EXPIRATION_DATE=$(date -u -d "+${CLUSTER_DURATION}sec" "+%Y-%m-%dT%H:%M:%S.00000Z")
  echo '{ "expiration_timestamp": "'"${EXPIRATION_DATE}"'" }' | ocm patch "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"
fi

ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.osd_install.log"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${SHARED_DIR}/kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" | jq -jr .admin.password > "${SHARED_DIR}/kubeadmin-password"
CONSOLE_URL=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r .console.url)
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"

echo "Console URL: ${CONSOLE_URL}"
while true; do
  echo "Waiting for reachable api.."
  if oc --kubeconfig "${SHARED_DIR}/kubeconfig" get project/openshift-apiserver; then
    break
  fi
  sleep 30
done

# OSD replaces the provider selection template and eliminate the kube:admin option.
# Restore the ugly, but kube:admin containing, default template.
cd /tmp
oc --kubeconfig "${SHARED_DIR}/kubeconfig" patch oauth.config.openshift.io cluster --type='json' -p='{"spec":{"templates": null}}' --type=merge

exit 0
