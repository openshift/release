#!/bin/bash

set -e
set -u
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
fi

timestamp() {
    date -u --rfc-3339=seconds
}

# Define common variables
SUB="openshift-cert-manager-operator"
OPERATOR_NAMESPACE="cert-manager-operator"
OPERAND_NAMESPACE="cert-manager"
CLUSTERISSUER_NAME="cluster-certs-clusterissuer" # This clusterissuer is consumed by the 'cert-manager-custom-apiserver-cert' and 'cert-manager-custom-ingress-cert' refs.
INTERVAL=10

function wait_cert_manager_rollout() {
    local OLD_POD=$1
    local MAX_RETRY=12
    local COUNTER=0

    echo "# Waiting for the pod to finish rollout."
    while :;
    do
        echo "Checking the cert-manager controller pod status for the #${COUNTER}-th time ..."
        NEW_POD_OUTPUT=$(oc get po -l app.kubernetes.io/name=cert-manager -n $OPERAND_NAMESPACE)
        if [[ ! "$NEW_POD_OUTPUT" =~ $OLD_POD ]] && [[ "$NEW_POD_OUTPUT" == *1/1*Running* ]]; then
            echo "[$(timestamp)] Finished the cert-manager controller pod rollout."
            break
        fi
        ((++COUNTER))
        if [[ $COUNTER -eq $MAX_RETRY ]]; then
            echo "[$(timestamp)] The cert-manager controller pod didn't finish rollout after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
            oc get po -n $OPERAND_NAMESPACE
            exit 1
        fi
        sleep $INTERVAL
    done
}

function configure_cloud_credentials() {
    local MANIFEST=$1
    local SECRET_NAME=$2

    echo -e "# Creating a credentialsrequest object for '$SECRET_NAME'."
    oc create -f - <<< "${MANIFEST}"

    OLD_CONTROLLER_POD="$(oc get po -l app.kubernetes.io/name=cert-manager -n cert-manager -o=jsonpath='{.items[*].metadata.name}')"

    # Patch the cloud credential secret to the subscription, so that it can be used as ambient credentials for dns01 challenge validation.
    oc -n $OPERATOR_NAMESPACE patch subscription $SUB --type=merge -p '{"spec":{"config":{"env":[{"name":"CLOUD_CREDENTIALS_SECRET_NAME","value":"'"${SECRET_NAME}"'"}]}}}'

    # Override dns nameservers for dns01 self-check, in case that the target hosted zone in dns01 solver overlaps with the cluster's default private hosted zone.
    oc patch certmanager cluster --type=merge -p='{"spec":{"controllerConfig":{"overrideArgs":["--dns01-recursive-nameservers=1.1.1.1:53,8.8.4.4:53", "--dns01-recursive-nameservers-only"]}}}'

    # Wait for the cert-manager controller pod to finish rollout
    wait_cert_manager_rollout "$OLD_CONTROLLER_POD"
}

function create_aws_route53_clusterissuer() {
    AWS_CREDREQUEST=$(cat <<EOF
apiVersion: cloudcredential.openshift.io/v1
kind: CredentialsRequest
metadata:
  name: cert-manager
  namespace: openshift-cloud-credential-operator
spec:
  providerSpec:
    apiVersion: cloudcredential.openshift.io/v1
    kind: AWSProviderSpec
    statementEntries:
    - action:
      - "route53:GetChange"
      effect: Allow
      resource: "arn:aws:route53:::change/*"
    - action:
      - "route53:ChangeResourceRecordSets"
      - "route53:ListResourceRecordSets"
      effect: Allow
      resource: "arn:aws:route53:::hostedzone/*"
    - action:
      - "route53:ListHostedZonesByName"
      effect: Allow
      resource: "*"
  secretRef:
    name: aws-creds
    namespace: cert-manager
  serviceAccountNames:
  - cert-manager
EOF
)
    configure_cloud_credentials "${AWS_CREDREQUEST}" "aws-creds"

    # retrieve configs to be used in the ClusterIssuer spec
    BASE_DOMAIN=$(oc get dns cluster -o=jsonpath='{.spec.baseDomain}')
    TARGET_DNS_DOMAIN=$(cut -d '.' -f 1 --complement <<< "$BASE_DOMAIN")
    PUBLIC_ZONE_ID=$(oc get dns cluster -o=jsonpath='{.spec.publicZone.id}')

    # hostedZoneID must be specified when alternative Api FQDN is used, otherwise `oc get challenge -o wide` later will be stuck
    # in "failed to determine Route 53 hosted zone ID: zone  not found in Route 53 for domain _acme-challenge.alt-api.BASE_DOMAIN."
    echo "# Creating a clusterissuer with the ACME DNS01 AWS Route53 solver."
    oc create -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $CLUSTERISSUER_NAME
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: acme-dns01-account-key
    solvers:
    - selector:
        dnsZones:
        - "$TARGET_DNS_DOMAIN"
      dns01:
        route53:
          region: us-east-2
          hostedZoneID: "$PUBLIC_ZONE_ID"
EOF
}

function create_gcp_clouddns_clusterissuer() {
    GCP_CREDREQUEST=$(cat <<EOF
apiVersion: cloudcredential.openshift.io/v1
kind: CredentialsRequest
metadata:
  name: cert-manager
  namespace: openshift-cloud-credential-operator
spec:
  providerSpec:
    apiVersion: cloudcredential.openshift.io/v1
    kind: GCPProviderSpec
    predefinedRoles:
    - roles/dns.admin
  secretRef:
    name: gcp-credentials
    namespace: cert-manager
  serviceAccountNames:
  - cert-manager
EOF
)
    configure_cloud_credentials "${GCP_CREDREQUEST}" "gcp-credentials"

    # retrieve configs to be used in the ClusterIssuer spec
    PROJECT_ID=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.gcp.projectID}')

    echo "# Creating a clusterissuer with the ACME DNS01 Google CloudDNS solver."
    oc create -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $CLUSTERISSUER_NAME
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: acme-dns01-account-key
    solvers:
    - dns01:
        cloudDNS:
          project: $PROJECT_ID
EOF
}

echo "# Checking if the cert-manager operator is already installed."
INSTALLED_CSV=$(oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status.installedCSV}' || true)
if [ -z "${INSTALLED_CSV}" ]; then
    echo "The cert-manager operator is not installed. Please ensure the 'cert-manager-install' ref is executed first."
    exit 1
fi

echo -e "# Creating the clusterissuer based on the CLUSTER_TYPE '${CLUSTER_TYPE}'."
case "${CLUSTER_TYPE}" in
aws|aws-arm64)
    create_aws_route53_clusterissuer
    ;;
gcp|gcp-arm64)
    create_gcp_clouddns_clusterissuer
    ;;
*)
    echo "Cluster type '${CLUSTER_TYPE}' is not supported currently." >&2
    exit 1
    ;;
esac

echo "# Waiting for the clusterissuer to be ready."
MAX_RETRY=12
COUNTER=0
while :;
do
    echo "Checking the clusterissuer $CLUSTERISSUER_NAME status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers clusterissuer $CLUSTERISSUER_NAME)" =~ True ]]; then
        echo "[$(timestamp)] The clusterissuer has become ready."
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The clusterissuer status is still not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get clusterissuer $CLUSTERISSUER_NAME -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done
