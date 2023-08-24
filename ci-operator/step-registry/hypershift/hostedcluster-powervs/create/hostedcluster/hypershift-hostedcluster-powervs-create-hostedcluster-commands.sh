#!/usr/bin/env bash
set -euox pipefail

echo HyperShift CLI version
/usr/bin/hypershift version

echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

echo "DOMAIN is ${BASE_DOMAIN}"
if [[ -z "${BASE_DOMAIN}" ]]; then
  >&2 echo "ERROR: Failed to determine the base domain."
  exit 1
fi

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}
echo "Using cluster name $CLUSTER_NAME and infra id $INFRA_ID"
echo "CLUSTER_NAME=$CLUSTER_NAME" > ${SHARED_DIR}/hosted_cluster.txt
echo "INFRA_ID=$INFRA_ID" >> ${SHARED_DIR}/hosted_cluster.txt

echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
bin/hypershift create cluster powervs \
  --name ${CLUSTER_NAME} \
  --infra-id ${INFRA_ID} \
  --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
  --base-domain ${BASE_DOMAIN} \
  --region ${POWERVS_REGION} \
  --zone ${POWERVS_ZONE} \
  --resource-group ${POWERVS_RESOURCE_GROUP} \
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
  --release-image ${RELEASE_IMAGE} \
  --vpc-region ${POWERVS_VPC_REGION} \
  --proc-type ${POWERVS_PROC_TYPE} \
  --sys-type ${POWERVS_SYS_TYPE} \
  --processors ${POWERVS_PROCESSORS} \
  --cloud-instance-id ${POWERVS_GUID} \
  --vpc ${VPC} \
  --cloud-connection ${CLOUD_CONNECTION} \
  --annotations "prow.k8s.io/job=${JOB_NAME}" \
  --annotations "prow.k8s.io/build-id=${BUILD_ID}" \
  --debug

echo "Wait to check if release image is valid"
n=0
until [ $n -ge 60 ]; do
    valid_image="$(oc -n clusters get hostedcluster "${CLUSTER_NAME}" -o json | jq '.status.conditions[]? | select(.type == "ValidReleaseImage")')"
    valid_image_status="$(printf '%s' "${valid_image}" | jq -r .status)"
    if [[ $valid_image_status == "True" ]]; then
        break
    fi
    if [[ $valid_image_status == "False" ]]; then
        printf 'Release image is not valid: %s\n' "${valid_image}"
        exit 1
    fi
    echo -n "."
    n=$((n+1))
    sleep 1
done

echo "Waiting for cluster to become available"
oc wait --timeout=120m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME} || {
  echo "Cluster did not become available"
  oc get hostedcluster --namespace=clusters -o yaml ${CLUSTER_NAME}
  exit 1
}
echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig || {
  echo "Failed to create kubeconfig"
  exit 1
}

# Data for cluster bot.
# The kubeadmin-password secret is reconciled only after the kas is available so we will wait up to 2 minutes for it to become available
echo "Retrieving kubeadmin password"
for _ in {1..8}; do
  kubeadmin_pwd=`oc get secret --namespace=clusters ${CLUSTER_NAME}-kubeadmin-password --template='{{.data.password}}' | base64 -d` || true
  if [ -z $kubeadmin_pwd ]; then
    echo "kubeadmin password is not ready yet, waiting 15s"
    sleep 15
  else
    echo $kubeadmin_pwd > ${SHARED_DIR}/kubeadmin-password
    break
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