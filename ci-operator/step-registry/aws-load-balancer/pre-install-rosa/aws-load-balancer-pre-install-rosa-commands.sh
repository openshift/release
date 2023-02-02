#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"
CI_BUILD01_AUTH="$(cat /var/run/albo/ci/build01/auth-token)"
REGION="${LEASED_RESOURCE}"
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
# ALBO roles have to be cleaned up, otherwise ccoctl won't create secret manifests.
# IAM roles with the prefix below are cleaned up by rosa-sts-account-roles-delete ref.
ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")
ALBO_SRC_DIR="/go/src/github.com/openshift/aws-load-balancer-operator"
CR_DIR="/tmp/albo-credrequests"
MANIFEST_DIR="/tmp/albo-manifests"
# RELEASE_IMAGE_LATEST value needs a pull secret, use a public image instead.
OCP_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.12.0-x86_64"

echo "=> registry pull secret"
[ -d "/var/run/albo/registry" ] && ls -ltra /var/run/albo/registry
grep -v auth /var/run/albo/registry/.dockerconfigjson || true

echo "=> checking pull secret"
grep -v auth "${PULL_SECRET}" || true

echo "=> configuring aws"
if [ -f "${AWSCRED}" ]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"; exit 1
fi

echo "=> logging into rosa"
if [ ! -z "${ROSA_TOKEN}" ]; then
  echo "Logging into staging with offline token using rosa cli $(rosa version)"
  rosa login --env "staging" --token "${ROSA_TOKEN}" || { echo "Login failed"; exit 1; }
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"; exit 1
fi

echo "=> getting identity provider name"
rosa describe cluster --cluster="${CLUSTER_ID}"
AWS_ACCOUNT_ID=$(rosa describe cluster --cluster="${CLUSTER_ID}" | grep 'AWS Account:' | tr -d ' ' | cut -d: -f2)
OIDC_IDP_NAME=$(rosa describe cluster --cluster="${CLUSTER_ID}" | grep 'OIDC Endpoint URL:' | tr -d ' ' | cut -d: -f2- | cut -d/ -f3-)
IDP_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_IDP_NAME}"

echo "=> preparing credential requests"
mkdir -p "${CR_DIR}"
cp ${ALBO_SRC_DIR}/hack/operator-credentials-request.yaml "${CR_DIR}"
cp ${ALBO_SRC_DIR}/hack/controller/controller-credentials-request.yaml "${CR_DIR}"
cat ${CR_DIR}/*

echo "=> extracting ccoctl binary from cco image"
CCO_IMAGE=$(oc adm release info --image-for='cloud-credential-operator' "${OCP_RELEASE_IMAGE}")
mkdir -p /tmp/albo
oc image extract "${CCO_IMAGE}" --path=/usr/bin/ccoctl:/tmp/albo -a "${PULL_SECRET}"
chmod 775 /tmp/albo/ccoctl

echo "=> creating required iam roles"
/tmp/albo/ccoctl aws create-iam-roles --name="${ACCOUNT_ROLES_PREFIX}" --region="${REGION}" --credentials-requests-dir="${CR_DIR}" --identity-provider-arn="${IDP_ARN}" --output-dir="${MANIFEST_DIR}"

echo "=> creating required secrets"
oc create namespace aws-load-balancer-operator
oc apply -f "${MANIFEST_DIR}/manifests"

echo "=> adding ci pull secret"
oc -n openshift-config get secret pull-secret --template='{{index .data ".dockerconfigjson" | base64decode}}' > /tmp/albo-rosa-pull-secret.json
#CI_REGISTRY_AUTH=$(cat ${PULL_SECRET} | python3 -c 'import json,sys;print(json.load(sys.stdin)["auths"]["registry.ci.openshift.org"]["auth"])')
cat /tmp/albo-rosa-pull-secret.json | python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["registry.build01.ci.openshift.org"]={"auth":"'${CI_BUILD01_AUTH}'"};j["auths"]=a;print(json.dumps(j))' > /tmp/albo-rosa-pull-secret-with-ci.json
oc -n openshift-config set data secret pull-secret --from-file=.dockerconfigjson=/tmp/albo-rosa-pull-secret-with-ci.json

echo "=> extracting ccoctl binary from cco image using personal token"
echo '{"auths":{"registry.build01.ci.openshift.org":{"auth":"'${CI_BUILD01_AUTH}'"}}}' > /tmp/ci-pull-secret.json
oc adm release info --registry-config=/tmp/ci-pull-secret.json --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}" || true
mkdir -p /tmp/albo2
oc image extract "${CCO_IMAGE}" --path=/usr/bin/ccoctl:/tmp/albo2 -a /tmp/ci-pull-secret.json || true
chmod 775 /tmp/albo2/ccoctl
/tmp/albo2/ccoctl

echo "=> extracting ccoctl binary from cco image using ci token"
oc adm release info --registry-config=${PULL_SECRET} --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}" || true
mkdir -p /tmp/albo3
oc image extract "${CCO_IMAGE}" --path=/usr/bin/ccoctl:/tmp/albo3 --registry-config=${PULL_SECRET} || true
chmod 775 /tmp/albo3/ccoctl
/tmp/albo3/ccoctl
