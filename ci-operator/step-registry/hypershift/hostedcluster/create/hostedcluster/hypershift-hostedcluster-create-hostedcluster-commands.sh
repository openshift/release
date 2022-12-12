#!/usr/bin/env bash
set -euo pipefail

echo Generating pull secret to current build farm
oc registry login --to=${SHARED_DIR}/pull-secret-build-farm.json
echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ! -f "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" ]]; then
  echo "AWS credentials file ${AWS_GUEST_INFRA_CREDENTIALS_FILE} not found"
  exit 1
fi
DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-""}
if [[ -z "${DOMAIN}" ]]; then
  echo "HYPERSHIFT_BASE_DOMAIN must be set"
  exit 1
fi

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

# We don't have the value of HYPERSHIFT_RELEASE_LATEST when we set CONTROLPLANE_OPERATOR_IMAGE so we
# have to use a hack like this.
[[ ${CONTROLPLANE_OPERATOR_IMAGE} = "LATEST" ]] && CONTROLPLANE_OPERATOR_IMAGE="${HYPERSHIFT_RELEASE_LATEST}"

HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}
echo "Using cluster name $CLUSTER_NAME and infra id $INFRA_ID"
echo "CLUSTER_NAME=$CLUSTER_NAME" > ${SHARED_DIR}/hosted_cluster.txt
echo "INFRA_ID=$INFRA_ID" >> ${SHARED_DIR}/hosted_cluster.txt

if [[ -f ${SHARED_DIR}/pull-secret-build-farm.json ]]; then
  jq -s '.[0] * .[1]' ${SHARED_DIR}/pull-secret-build-farm.json /etc/ci-pull-credentials/.dockerconfigjson > /tmp/pull-secret.json
else
  cp /etc/ci-pull-credentials/.dockerconfigjson /tmp/pull-secret.json
fi

echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
/usr/bin/hypershift create cluster aws \
  ${EXTRA_ARGS} \
  --name ${CLUSTER_NAME} \
  --infra-id ${INFRA_ID} \
  --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
  --instance-type=m5.xlarge \
  --base-domain ${DOMAIN} \
  --region ${HYPERSHIFT_AWS_REGION} \
  --control-plane-availability-policy ${HYPERSHIFT_CP_AVAILABILITY_POLICY} \
  --infra-availability-policy ${HYPERSHIFT_INFRA_AVAILABILITY_POLICY} \
  --pull-secret=/tmp/pull-secret.json \
  --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE} \
  --release-image ${RELEASE_IMAGE} \
  --control-plane-operator-image=${CONTROLPLANE_OPERATOR_IMAGE:-} \
  --additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)"

echo "Wait to check if release image is valid"
n=0
until [ $n -ge 60 ]; do
    valid_image_status=$(oc -n clusters get hostedcluster ${CLUSTER_NAME} -o json | jq -r '.status.conditions[]? | select(.type == "ValidReleaseImage") | .status')
    if [[ $valid_image_status == "True" ]]; then
        break
    fi
    if [[ $valid_image_status == "False" ]]; then
        echo "Release image is not valid"
        exit 1
    fi
    echo -n "."
    n=$((n+1))
    sleep 1
done

# The timeout should be much lower, this is due to https://bugzilla.redhat.com/show_bug.cgi?id=2060091
echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

# Data for cluster bot.
# The kubeadmin-password secret is reconciled only after the kas is available so we will wait up to 2 minutes for it to become available
for _ in {1..8}; do
    if oc get secret --namespace=clusters ${CLUSTER_NAME}-kubeadmin-password --template='{{.data.password}}' | base64 -d > ${SHARED_DIR}/kubeadmin-password; then
      echo "Successfully retrieved kubeadmin password"
      break
    else
      # make sure file is non-existant if command failed
      rm ${SHARED_DIR}/kubeadmin-password
      sleep 15
    fi
done

if [[ ! -f ${SHARED_DIR}/kubeadmin-password ]]; then
  echo "Failed to get kubeadmin password for the cluster"
  exit 1
fi

echo "Waiting for clusteroperators to be ready"
ln -s ${SHARED_DIR}/nested_kubeconfig ${SHARED_DIR}/kubeconfig
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null; do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    oc get clusterversion 2>/dev/null || true
    sleep 5s
done

# Data for cluster bot.
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
