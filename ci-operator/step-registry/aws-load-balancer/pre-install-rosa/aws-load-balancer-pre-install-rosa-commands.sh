#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
# Use mounted registry-pull-credentials secret.
# $CLUSTER_PROFILE_DIR/pull-secret cannot be used here.
# It doesn't have the auths for the CI build registries (e.g. registry.build01.ci.openshift.org).
CI_REGISTRY_PULL_SECRET="/var/run/albo/registry/.dockerconfigjson"
REGION="${LEASED_RESOURCE}"
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
# ALBO roles have to be cleaned up, otherwise ccoctl won't create secret manifests.
# IAM roles with the prefix below are cleaned up by rosa-sts-account-roles-delete ref.
ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")
#ALBO_SRC_DIR="/go/src/github.com/openshift/aws-load-balancer-operator"
CR_DIR="/tmp/albo-credrequests"
MANIFEST_DIR="/tmp/albo-manifests"

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
ls -ltr
[ -d /go/src ] && ls -ltr /go/src
[ -d /go/src/github.com/openshift ] && ls -ltr /go/src/github.com/openshift
[ -d /go/src/github.com/openshift/aws-load-balancer-operator ] && ls -ltr /go/src/github.com/openshift/aws-load-balancer-operator
#mkdir -p "${CR_DIR}"
#cp ${ALBO_SRC_DIR}/hack/operator-credentials-request.yaml "${CR_DIR}"
#cp ${ALBO_SRC_DIR}/hack/controller/controller-credentials-request.yaml "${CR_DIR}"
#cat ${CR_DIR}/*
curl --create-dirs -o ${CR_DIR}/operator.yaml https://raw.githubusercontent.com/openshift/aws-load-balancer-operator/main/hack/operator-credentials-request.yaml
curl --create-dirs -o ${CR_DIR}/controller.yaml https://raw.githubusercontent.com/openshift/aws-load-balancer-operator/main/hack/controller/controller-credentials-request.yaml

echo "=> extracting ccoctl binary from cco image"
CCO_IMAGE=$(oc adm release info --registry-config=${CI_REGISTRY_PULL_SECRET} --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}")
mkdir -p /tmp/albo
oc image extract "${CCO_IMAGE}" --registry-config=${CI_REGISTRY_PULL_SECRET} --path=/usr/bin/ccoctl:/tmp/albo
chmod 775 /tmp/albo/ccoctl

echo "=> creating required iam roles"
/tmp/albo/ccoctl aws create-iam-roles --name="${ACCOUNT_ROLES_PREFIX}" --region="${REGION}" --credentials-requests-dir="${CR_DIR}" --identity-provider-arn="${IDP_ARN}" --output-dir="${MANIFEST_DIR}"

echo "=> creating required secrets"
oc create namespace aws-load-balancer-operator
oc apply -f "${MANIFEST_DIR}/manifests"

echo "=> adding ci pull secret"
oc -n openshift-config get secret pull-secret --template='{{index .data ".dockerconfigjson" | base64decode}}' > /tmp/albo-rosa-pull-secret.json
CI_REGISTRY_AUTH=$(cat ${CI_REGISTRY_PULL_SECRET} | python3 -c 'import json,sys;print(json.load(sys.stdin)["auths"]["registry.build01.ci.openshift.org"]["auth"])')
cat /tmp/albo-rosa-pull-secret.json | python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["registry.build01.ci.openshift.org"]={"auth":"'${CI_REGISTRY_AUTH}'"};j["auths"]=a;print(json.dumps(j))' > /tmp/albo-rosa-pull-secret-with-ci.json
oc -n openshift-config set data secret pull-secret --from-file=.dockerconfigjson=/tmp/albo-rosa-pull-secret-with-ci.json
