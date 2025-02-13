#!/bin/bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function wait_for_state() {
    local object="$1"
    local state="$2"
    local timeout="$3"
    local namespace="${4:-}"
    local selector="${5:-}"

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to exist..."
    for _ in {1..30}; do
        oc get ${object} --selector="${selector}" -n=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 5
    done

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to become '${state}'..."
    oc wait --for=${state} --timeout=${timeout} ${object} --selector="${selector}" -n="${namespace}"
    return $?
}

function check_cm_operator() {
    echo "Checking the persence of the cert-manager Operator as prerequisite..."
    if ! oc wait deployment/cert-manager-operator-controller-manager -n cert-manager-operator --for=condition=Available --timeout=0; then
        echo "The cert-manager Operator is not installed or unavailable. Skipping rest of steps..."
        exit 0
    fi
}

function configure_cloud_credentials() {
    local manifest="$1"
    local secret_name="$2"

    echo "Creating a CredentialsRequest object for '$secret_name'..."
    oc apply -f - <<< "${manifest}"

    echo "Patching the generated secret to the Subscription as ambient credentials for DNS01 challenge validation..."
    local json_path='{"spec":{"config":{"env":[{"name":"CLOUD_CREDENTIALS_SECRET_NAME","value":"'"${secret_name}"'"}]}}}'
    oc patch subscription openshift-cert-manager-operator --type=merge -p "$json_path" -n cert-manager-operator

    echo "Configuring the DNS nameservers for DNS01 recursive self-check..."
    json_path='{"spec":{"controllerConfig":{"overrideArgs":["--dns01-recursive-nameservers=1.1.1.1:53,8.8.4.4:53", "--dns01-recursive-nameservers-only"]}}}'
    oc patch certmanager cluster --type=merge -p "$json_path"

    wait_for_state "deployment/cert-manager" "condition=Available" "2m" "cert-manager"
}

function create_aws_route53_clusterissuer() {
    aws_credential_request=$(cat <<EOF
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
    configure_cloud_credentials "${aws_credential_request}" "aws-creds"

    echo "Retrieving configs to be used in the ClusterIssuer spec..."
    base_domain=$(oc get dns cluster -o=jsonpath='{.spec.baseDomain}')
    target_dns_domain=$(cut -d '.' -f 1 --complement <<< "$base_domain")
    public_zone_id=$(oc get dns cluster -o=jsonpath='{.spec.publicZone.id}')
    region=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.aws.region}')

    echo "Creating an ACME DNS01 ClusterIssuer configured with AWS Route53..."
    oc apply -f - << EOF
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
        - "$target_dns_domain"
      dns01:
        route53:
          region: $region
          hostedZoneID: $public_zone_id
EOF
}

function create_gcp_clouddns_clusterissuer() {
    gcp_credential_request=$(cat <<EOF
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
    configure_cloud_credentials "${gcp_credential_request}" "gcp-credentials"

    echo "Retrieving configs to be used in the ClusterIssuer spec..."
    project_id=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.gcp.projectID}')

    echo "Creating an ACME DNS01 ClusterIssuer configured with Google CloudDNS..."
    oc apply -f - << EOF
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
          project: $project_id
EOF
}

function is_clusterisser_ready() {
    if wait_for_state "clusterissuer/$CLUSTERISSUER_NAME" "condition=Ready" "2m"; then
        echo "ClusterIssuer is ready"
    else
        echo "Timed out after 2m. Dumping resources for debugging..."
        run_command "oc describe clusterissuer $CLUSTERISSUER_NAME"
        exit 1
    fi
}

timestamp
set_proxy
check_cm_operator

echo "Creating the ClusterIssuer based on CLUSTER_TYPE '${CLUSTER_TYPE}'..."
case "${CLUSTER_TYPE}" in
aws|aws-arm64)
    create_aws_route53_clusterissuer
    ;;
gcp|gcp-arm64)
    create_gcp_clouddns_clusterissuer
    ;;
*)
    echo "Cluster type '${CLUSTER_TYPE}' unsupported, exiting..." >&2
    exit 1
    ;;
esac

is_clusterisser_ready

echo "[$(timestamp)] Succeeded in creating a ClusterIssuer configured with Let's Encrypt ACME DNS01 type!"
