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
MANIFEST_DIR="/tmp/albo-manifests"
CCOCTL_OUTPUT="/tmp/ccoctl-output"
E2E_INPUT_DIR="${SHARED_DIR}"
E2E_INPUT_WAFV2_WEBACL="wafv2-webacl"
E2E_INPUT_WAF_WEBACL="waf-webacl"
E2E_INPUT_OPERATOR_ROLE_ARN="operator-role-arn"
E2E_INPUT_CONTROLLER_ROLE_ARN="controller-role-arn"
E2E_WAFV2_WEB_ACL_NAME="echoserver-acl"
E2E_WAF_WEB_ACL_NAME="echoserverclassicacl"

if [ -f "${AWSCRED}" ]; then
    echo "=> configuring aws"
    export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
    export AWS_DEFAULT_REGION="${REGION}"
else
    echo "Did not find compatible cloud provider cluster_profile"; exit 1
fi

if [ ! -z "${ROSA_TOKEN}" ]; then
    echo "Logging into staging with offline token using rosa cli $(rosa version)"
    rosa login --env "staging" --token "${ROSA_TOKEN}" || { echo "Login failed"; exit 1; }
else
    echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"; exit 1
fi

echo "=> getting identity provider name"
AWS_ACCOUNT_ID=$(rosa describe cluster --cluster="${CLUSTER_ID}" | grep 'AWS Account:' | tr -d ' ' | cut -d: -f2)
OIDC_IDP_NAME=$(rosa describe cluster --cluster="${CLUSTER_ID}" --output json | jq -r .aws.sts.oidc_endpoint_url | cut -d/ -f3-)
IDP_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_IDP_NAME}"

echo "=> extracting ccoctl binary from cco image"
CCO_IMAGE=$(oc adm release info --registry-config="${CI_REGISTRY_PULL_SECRET}" --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}")
mkdir -p /tmp/albo
oc image extract "${CCO_IMAGE}" --registry-config=${CI_REGISTRY_PULL_SECRET} --path=/usr/bin/ccoctl:/tmp/albo
chmod 775 /tmp/albo/ccoctl

echo "=> creating required iam roles"
CR_DIR="/tmp/albo-credrequests"
mkdir -p "${CR_DIR}"
cp "${SHARED_DIR}/operator-credentials-request.yaml" "${CR_DIR}"
cp "${SHARED_DIR}/controller-credentials-request.yaml" "${CR_DIR}"
/tmp/albo/ccoctl aws create-iam-roles --name="${ACCOUNT_ROLES_PREFIX}" --region="${REGION}" --credentials-requests-dir="${CR_DIR}" --identity-provider-arn="${IDP_ARN}" --output-dir="${MANIFEST_DIR}" 2>&1 | tee "${CCOCTL_OUTPUT}"

echo "=> extracting iam role arns"
# ccoctl generates role names adding prefix, cr namespace and name,
# this results in long names which have to be cut to fit into AWS limits.
# that's where `aws-load-balancer-cont` pattern comes from.
cat "${CCOCTL_OUTPUT}" | \grep -ioP 'role arn:aws:iam.* ' | \grep 'aws-load-balancer-operator-aws-load-balancer-oper' | cut -d' ' -f2 > ${E2E_INPUT_DIR}/${E2E_INPUT_OPERATOR_ROLE_ARN}
cat "${CCOCTL_OUTPUT}" | \grep -ioP 'role arn:aws:iam.* ' | \grep 'aws-load-balancer-cont' | cut -d' ' -f2 > ${E2E_INPUT_DIR}/${E2E_INPUT_CONTROLLER_ROLE_ARN}

echo "=> creating required secrets"
oc create namespace aws-load-balancer-operator
oc apply -f "${MANIFEST_DIR}/manifests"

echo "=> adding ci pull secret"
oc -n openshift-config get secret pull-secret --template='{{index .data ".dockerconfigjson" | base64decode}}' > /tmp/albo-rosa-pull-secret.json
# getting the auth of the build registry (e.g. registry.build01.ci.openshift.org)
cat ${CI_REGISTRY_PULL_SECRET} | python3 -c 'import json,sys
for k,v in json.load(sys.stdin)["auths"].items(): print(k,":",v["auth"])' | grep -P -m1 'registry.build\d+.ci' | tr -d ' ' > /tmp/buildregistryauth
CI_BUILD_REGISTRY=$(cat /tmp/buildregistryauth | cut -d: -f1)
CI_BUILD_REGISTRY_AUTH=$(cat /tmp/buildregistryauth | cut -d: -f2)
echo "=> build registry: ${CI_BUILD_REGISTRY}"
cat /tmp/albo-rosa-pull-secret.json | python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${CI_BUILD_REGISTRY}'"]={"auth":"'${CI_BUILD_REGISTRY_AUTH}'"};j["auths"]=a;print(json.dumps(j))' > /tmp/albo-rosa-pull-secret-with-ci.json
oc -n openshift-config set data secret pull-secret --from-file=.dockerconfigjson=/tmp/albo-rosa-pull-secret-with-ci.json

echo "=> ensuring e2e wafv2 web acl"
aws wafv2 create-web-acl --name "${E2E_WAFV2_WEB_ACL_NAME}" --scope REGIONAL --default-action '{"Block":{}}'  --visibility-config '{"MetricName":"echoserver","CloudWatchMetricsEnabled": false,"SampledRequestsEnabled":false}' || true
aws wafv2 list-web-acls --scope REGIONAL --output json | grep "webacl/${E2E_WAFV2_WEB_ACL_NAME}" | cut -d: -f2- | tr -d \",' ' > ${E2E_INPUT_DIR}/${E2E_INPUT_WAFV2_WEBACL}

echo "=> ensuring e2e wafregional web acl"
WAFREGIONAL_CHANGE_TOKEN=$(aws waf-regional get-change-token --output json | jq -r .ChangeToken)
aws waf-regional create-web-acl --name "${E2E_WAF_WEB_ACL_NAME}" --metric-name "${E2E_WAF_WEB_ACL_NAME}" --default-action '{"Type":"BLOCK"}' --change-token "${WAFREGIONAL_CHANGE_TOKEN}" || true
aws waf-regional list-web-acls --output json | grep -B1 "${E2E_WAF_WEB_ACL_NAME}" | grep WebACLId | tr -d \",' ' | cut -d: -f2 > ${E2E_INPUT_DIR}/${E2E_INPUT_WAF_WEBACL}
