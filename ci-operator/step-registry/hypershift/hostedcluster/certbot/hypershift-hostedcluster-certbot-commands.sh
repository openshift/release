#!/usr/bin/env bash
set -euo pipefail

echo certbot version
certbot --version

echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com
if [[ "${PLATFORM}" == "aws" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  if [[ ! -f "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" ]]; then
    echo "AWS credentials file ${AWS_GUEST_INFRA_CREDENTIALS_FILE} not found"
    exit 1
  fi
  if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
  fi
else
  echo "Unsupported platform. Cannot issue certificates. This is an optional step so exiting with code 0."
  exit 0
fi
export AWS_CONFIG_FILE=${AWS_GUEST_INFRA_CREDENTIALS_FILE}

DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}

HOSTED_CLUSTER_FILE="$SHARED_DIR/hosted_cluster.txt"
if [ -f "$HOSTED_CLUSTER_FILE" ]; then
  echo "Loading $HOSTED_CLUSTER_FILE"
  # shellcheck source=/dev/null
  source "$HOSTED_CLUSTER_FILE"
  echo "Loaded $HOSTED_CLUSTER_FILE"
  echo "Cluster name: $CLUSTER_NAME, infra ID: $INFRA_ID"
else
  CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
  INFRA_ID=""
  echo "$HOSTED_CLUSTER_FILE does not exist. Defaulting to the default cluster name: $CLUSTER_NAME."
fi

echo "Contact email is ${CONTACT_EMAIL}"
if [[ -z "${CONTACT_EMAIL}" ]]; then
  >&2 echo "ERROR: Failed to determine the contact email."
  exit 1
fi

CLUSTER_DOMAIN="${CLUSTER_NAME}.${DOMAIN}"

echo "Detecting Route53 zone ID for ${CLUSTER_DOMAIN}"
export ROUTE53_ZONE_ID=`aws route53 list-hosted-zones-by-name |  jq --arg name "${CLUSTER_DOMAIN}." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id'`

if [[ -z "${ROUTE53_ZONE_ID}" ]]; then
  >&2 echo "ERROR: Failed to determine the Route53 zone ID. Not creating certificates."
  exit 0
fi

echo "Route53 zone ID for ${CLUSTER_DOMAIN} is ${ROUTE53_ZONE_ID}"

CONFIG_DIR=$HOME/etc/letsencrypt
WORK_DIR=$HOME/var/lib/letsencrypt
LOG_DIR=${HOME}/log/letsencrypt

echo "Invoking certbot to obtain a wildcard certificate for ${CLUSTER_DOMAIN}"
certbot certonly -d *.${CLUSTER_DOMAIN} \
    --manual --preferred-challenges dns \
    --manual-auth-hook /opt/manual-auth-hook.sh \
    -m ${CONTACT_EMAIL} \
    --agree-tos -n -v \
    --config-dir ${CONFIG_DIR} \
    --work-dir ${WORK_DIR} \
    --logs-dir ${LOG_DIR}

if [[ $? -ne 0 ]]; then
  >&2 echo "ERROR: Failed to obtain a wildcard certificate for ${CLUSTER_DOMAIN}"
  echo "Validation hook output:"
  echo $CERTBOT_AUTH_OUTPUT
  exit 1
fi

echo "Successfully obtained a wildcard certificate for ${CLUSTER_DOMAIN}"

echo "Installing the certificate..."
$CLI_DIR/oc -n clusters create secret tls ${CLUSTER_NAME}-cert \
    --cert=${CONFIG_DIR}/live/${CLUSTER_DOMAIN}/fullchain.pem \
    --key=${CONFIG_DIR}/live/${CLUSTER_DOMAIN}/privkey.pem

#configure hostedcluster object with cluster name to set
# hostedcluster.spec.configuration.apiServer.servigCerts
echo "Setting the servingCerts for API server"
cat <<EOF | $CLI_DIR/oc patch -n clusters -f - --type merge
spec:
  configuration:
    apiServer:
      servingCerts:
        namedCertificates:
        - names:
          - *.${CLUSTER_DOMAIN}
          servingCertificate:
            name: ${CLUSTER_NAME}-cert
EOF

echo "Successfully installed the certificate for ${CLUSTER_DOMAIN}"
