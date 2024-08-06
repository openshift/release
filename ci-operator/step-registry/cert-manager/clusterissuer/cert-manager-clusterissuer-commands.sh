#!/bin/bash

set -e
set -u
set -o pipefail

function wait_cert_manager_rollout() {
    local OLD_POD=$1
    local MAX_RETRY=12
    local INTERVAL=10
    local COUNTER=0
    while :;
    do
        NEW_POD_OUTPUT=$(oc get po -l app.kubernetes.io/name=cert-manager -n cert-manager)
        if [[ ! "$NEW_POD_OUTPUT" =~ $OLD_POD ]] && [[ "$NEW_POD_OUTPUT" == *1/1*Running* ]]; then
            echo "The cert-manager pod finished rollout." && break
        fi
        ((++COUNTER))
        if [[ $COUNTER -eq $MAX_RETRY ]]; then
            echo "The cert-manager pod still does not finish rollout after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
            oc get po -n cert-manager
            exit 1
        fi
        sleep $INTERVAL
    done
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
fi

# Check cert-manager Operator is already installed
if ! CM_OP_VERSION=$(oc get subscription openshift-cert-manager-operator -n cert-manager-operator '-o=jsonpath={.status.installedCSV}'); then
    echo "The cert-manager Operator is not already installed. Please ensure the cert-manager-install ref is executed first."
    exit 1
elif echo "${CM_OP_VERSION#cert-manager-operator.v}" 1.13 | awk '{ print ($1 < $2) ? "true" : "false" }' | grep -q true; then
    echo -e "Only cert-manager Operator >= v1.13 is supported but the cert-manager Operator is ${CM_OP_VERSION#cert-manager-operator.v}.\nSkipping ..."
    exit 1
fi

BASE_DOMAIN=$(oc get dns cluster -o=jsonpath='{.spec.baseDomain}')
TARGET_DNS_DOMAIN=$(cut -d '.' -f 1 --complement <<< "$BASE_DOMAIN")
PUBLIC_ZONE_ID=$(oc get dns cluster '-o=jsonpath={.spec.publicZone.id}')
CLUSTERISSUER_NAME=cluster-certs-clusterissuer # This clusterissuer is consumed by the cert-manager-custom-apiserver-cert ref et al

case "${CLUSTER_TYPE}" in
aws|aws-arm64)
    oc create -f - << EOF
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
    OLD_CERT_MANAGER_POD="$(oc get po -l app.kubernetes.io/name=cert-manager -n cert-manager '-o=jsonpath={.items[*].metadata.name}')"
    oc -n cert-manager-operator patch subscription openshift-cert-manager-operator --type=merge -p '{"spec":{"config":{"env":[{"name":"CLOUD_CREDENTIALS_SECRET_NAME","value":"aws-creds"}]}}}'
    # We must do below oc patch otherwise `oc get challenge -o wide` later will be stuck in "Waiting for DNS-01 challenge propagation: NS ns-0.awsdns-00.com.:53 returned REFUSED for _acme-challenge.alt-api.BASE_DOMAIN." as same as test case OCP-62582
    oc patch certmanager cluster --type=merge -p='{"spec":{"controllerConfig":{"overrideArgs":["--dns01-recursive-nameservers=1.1.1.1:53,8.8.4.4:53", "--dns01-recursive-nameservers-only"]}}}'
    wait_cert_manager_rollout "$OLD_CERT_MANAGER_POD"

    # hostedZoneID must be specified when alternative Api FQDN is used, otherwise `oc get challenge -o wide` later will be stuck in "failed to determine Route 53 hosted zone ID: zone  not found in Route 53 for domain _acme-challenge.alt-api.BASE_DOMAIN."
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

    ;;
*)
    echo "Cluster type '${CLUSTER_TYPE}' is not supported currently." >&2
    exit 1
    ;;
esac

# Wait for the clusterissuer to become ready
MAX_RETRY=12
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking the $CLUSTERISSUER_NAME clusterissuer status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers clusterissuer $CLUSTERISSUER_NAME)" =~ True ]]; then
        echo "[$(date -u --rfc-3339=seconds)] The $CLUSTERISSUER_NAME clusterissuer has become ready."
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The $CLUSTERISSUER_NAME clusterissuer status is still not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get clusterissuer $CLUSTERISSUER_NAME -o jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

