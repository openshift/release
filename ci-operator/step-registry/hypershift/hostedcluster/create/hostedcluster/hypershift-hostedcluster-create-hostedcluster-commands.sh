#!/usr/bin/env bash
set -euo pipefail

echo HyperShift CLI version
/usr/bin/hypershift version

echo Generating pull secret to current build farm
oc registry login --to=${SHARED_DIR}/pull-secret-build-farm.json
echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

if [[ "${PLATFORM}" == "aws" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  if [[ ! -f "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" ]]; then
    echo "AWS credentials file ${AWS_GUEST_INFRA_CREDENTIALS_FILE} not found"
    exit 1
  fi
elif [[ "${PLATFORM}" == "powervs" ]]; then
  export IBMCLOUD_CREDENTIALS="${CLUSTER_PROFILE_DIR}/.powervscred"
  if [[ ! -f "${IBMCLOUD_CREDENTIALS}" ]]; then
      echo "PowerVS credentials file ${IBMCLOUD_CREDENTIALS} not found"
      exit 1
  fi
else
  echo "Currently only AWS and PowerVS platforms are supported"
  exit 1
fi
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}


[[ ! -z "$BASE_DOMAIN" ]] && DOMAIN=${BASE_DOMAIN}
[[ ! -z "$HYPERSHIFT_BASE_DOMAIN" ]] && DOMAIN=${HYPERSHIFT_BASE_DOMAIN}
echo "DOMAIN is ${DOMAIN}"
if [[ -z "${DOMAIN}" ]]; then
  >&2 echo "ERROR: Failed to determine the base domain."
  exit 1
fi

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

if [[ "${COMPUTE_NODE_TYPE}" == "" ]]; then
  COMPUTE_NODE_TYPE="m5.xlarge"
fi

echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
case "${PLATFORM}" in
  "aws")
    /usr/bin/hypershift create cluster aws \
      ${EXTRA_ARGS} \
      --name ${CLUSTER_NAME} \
      --infra-id ${INFRA_ID} \
      --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
      --instance-type=${COMPUTE_NODE_TYPE} \
      --base-domain ${DOMAIN} \
      --region ${HYPERSHIFT_AWS_REGION} \
      --control-plane-availability-policy ${HYPERSHIFT_CP_AVAILABILITY_POLICY} \
      --infra-availability-policy ${HYPERSHIFT_INFRA_AVAILABILITY_POLICY} \
      --pull-secret=/tmp/pull-secret.json \
      --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE} \
      --release-image ${RELEASE_IMAGE} \
      --control-plane-operator-image=${CONTROLPLANE_OPERATOR_IMAGE:-} \
      --node-selector "hypershift.openshift.io/control-plane=true" \
      --additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)" \
      --annotations "prow.k8s.io/job=${JOB_NAME}" \
      --annotations "cluster-profile=${CLUSTER_PROFILE_NAME}" \
      --annotations "prow.k8s.io/build-id=${BUILD_ID}" \
      --annotations resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m \
      --annotations hypershift.openshift.io/cleanup-cloud-resources="false" \
      --additional-tags "prow.k8s.io/job=${JOB_NAME}" \
      --additional-tags "prow.k8s.io/build-id=${BUILD_ID}" 
    ;;
  "powervs")
    if [[ -z "${POWERVS_GUID}" ]]; then
      POWERVS_GUID=$(jq -r '.cloudInstanceID' "${CLUSTER_PROFILE_DIR}/existing-resources.json")
    fi
    if [[ -z "${POWERVS_VPC}" ]]; then
      POWERVS_VPC=$(jq -r '.vpc' "${CLUSTER_PROFILE_DIR}/existing-resources.json")
    fi
    if [[ -z "${POWERVS_CLOUD_CONNECTION}" ]]; then
      POWERVS_CLOUD_CONNECTION=$(jq -r '.cloudConnection' "${CLUSTER_PROFILE_DIR}/existing-resources.json")
    fi
    if [[ -z "${POWERVS_REGION}" ]]; then
      POWERVS_REGION=$(jq -r '.region' "${CLUSTER_PROFILE_DIR}/existing-resources.json")
    fi
    if [[ -z "${POWERVS_ZONE}" ]]; then
      POWERVS_ZONE=$(jq -r '.zone' "${CLUSTER_PROFILE_DIR}/existing-resources.json")
    fi
    if [[ -z "${POWERVS_VPC_REGION}" ]]; then
      POWERVS_VPC_REGION=$(jq -r '.vpcRegion' "${CLUSTER_PROFILE_DIR}/existing-resources.json")
    fi

    bin/hypershift create cluster powervs \
      --name ${CLUSTER_NAME} \
      --infra-id ${INFRA_ID} \
      --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
      --base-domain ${DOMAIN} \
      --region ${POWERVS_REGION} \
      --zone ${POWERVS_ZONE} \
      --resource-group ${POWERVS_RESOURCE_GROUP} \
      --pull-secret=/etc/registry-pull-credentials/.dockerconfigjson \
      --release-image ${RELEASE_IMAGE} \
      --control-plane-operator-image=${CONTROLPLANE_OPERATOR_IMAGE:-} \
      --control-plane-availability-policy ${HYPERSHIFT_CP_AVAILABILITY_POLICY} \
      --infra-availability-policy ${HYPERSHIFT_INFRA_AVAILABILITY_POLICY} \
      --vpc-region ${POWERVS_VPC_REGION} \
      --proc-type ${POWERVS_PROC_TYPE} \
      --sys-type ${POWERVS_SYS_TYPE} \
      --processors ${POWERVS_PROCESSORS} \
      --cloud-instance-id ${POWERVS_GUID} \
      --vpc ${POWERVS_VPC} \
      --cloud-connection ${POWERVS_CLOUD_CONNECTION} \
      --annotations "prow.k8s.io/job=${JOB_NAME}" \
      --annotations "prow.k8s.io/build-id=${BUILD_ID}" \
      --debug
    ;;
  *)
    echo "Unsupported platform: ${PLATFORM}"
    exit 1
    ;;
esac


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

# The timeout should be much lower, this is due to https://bugzilla.redhat.com/show_bug.cgi?id=2060091
echo "Waiting for cluster to become available"
oc wait --timeout=120m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME} || {
  echo "Cluster did not become available"
  oc get hostedcluster --namespace=clusters -o yaml ${CLUSTER_NAME}
  exit 1
}
echo "Cluster became available, creating kubeconfig"
KUBECONFIG_NAME=""
while [[ -z "${KUBECONFIG_NAME}" ]]; do
  echo "Still waiting for kubeconfig to be available"
  sleep 10
  KUBECONFIG_NAME=$(oc get hc/${CLUSTER_NAME} -n clusters -o jsonpath='{ .status.kubeconfig.name }')
done

bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} > ${SHARED_DIR}/nested_kubeconfig || {
  echo "Failed to create kubeconfig"
}

# Data for cluster bot.
# The kubeadmin-password secret is reconciled only after the kas is available so we will wait up to 5 minutes for it to become available
echo "Retrieving kubeadmin password"
for _ in {1..50}; do
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
KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig oc annotate -n clusters hostedcluster ${CLUSTER_NAME} "created-at=`date -u +'%Y-%m-%dT%H:%M:%SZ'`"
