#!/usr/bin/env bash

set -euxo pipefail

function mgmt() {
    KUBECONFIG="${SHARED_DIR}"/mgmt_kubeconfig "$@"
}

function oc_login_kubeadmin_passwd() {
    local kas_url
    kas_url="$(oc whoami --show-server)"

    (
        trap 'rm kubeconfig.tmp' EXIT
        cp "${SHARED_DIR}/kubeconfig" kubeconfig.tmp

        set +x
        kubeadmin_password="$(mgmt oc extract secret/"${HC_NAME}-kubeadmin-password" -n clusters --to -)"
        KUBECONFIG=kubeconfig.tmp oc login "$kas_url" --username kubeadmin --password "$kubeadmin_password"
    )
}

function wait_for_hc_readiness() {
    local pids_to_wait=()

    oc wait node --all --for=condition=Ready=True --timeout=2m

    oc wait co --all --for=condition=Available=True --timeout=5m &
    pids_to_wait+=($!)
    oc wait co --all --for=condition=Progressing=False --timeout=5m &
    pids_to_wait+=($!)
    oc wait co --all --for=condition=Degraded=False --timeout=5m &
    pids_to_wait+=($!)
    wait "${pids_to_wait[@]}"
}

function check_clusterissuer() {
    echo "Checking the persence of ClusterIssuer '$CLUSTERISSUER_NAME' as prerequisite..."
    if ! oc wait clusterissuer/$CLUSTERISSUER_NAME --for=condition=Ready --timeout=0; then
        echo "ClusterIssuer is not created or not ready to use. Skipping rest of steps..."
        exit 0
    fi
}

function create_aggregated_cert() {
    oc apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $AGGREGATED_CERT_NAME
  namespace: openshift-ingress
spec:
  commonName: "*.${INGRESS_DOMAIN}"
  dnsNames:
  - "*.${INGRESS_DOMAIN}"
  - "${KUBE_API_SERVER_DNS_NAME}"
  - "oauth-${HC_NAME}.${HYPERSHIFT_DNS_DOMAIN}"
  usages:
  - server auth
  issuerRef:
    kind: ClusterIssuer
    name: $CLUSTERISSUER_NAME
  secretName: $AGGREGATED_CERT_SECRET_NAME
  duration: 2h
  renewBefore: 1h30m
EOF
    oc wait certificate "$AGGREGATED_CERT_NAME" -n openshift-ingress --for=condition=Ready=True --timeout=10m
}

function configure_default_ic_cert() {
    local ic_json_patch
    ic_json_patch='{"spec":{"defaultCertificate": {"name": "'"$AGGREGATED_CERT_SECRET_NAME"'"}}}'

    oc patch ingresscontroller default --type=merge -p "$ic_json_patch" -n openshift-ingress-operator
    oc wait co ingress --for=condition=Progressing=True --timeout=2m
    oc wait co ingress --for=condition=Progressing=False --timeout=5m
}

function configure_kas_oauth_serving_cert() {
    local kas_generation
    local oauth_generation

    kas_generation="$(mgmt oc get deployment -n "$HCP_NS" kube-apiserver -o jsonpath='{.metadata.generation}')"
    oauth_generation="$(mgmt oc get deployment -n "$HCP_NS" oauth-openshift -o jsonpath='{.metadata.generation}')"

    mgmt oc patch hc -n clusters "$HC_NAME" --type merge -p "
spec:
  configuration:
    apiServer:
      servingCerts:
        namedCertificates:
        - names:
            - $KUBE_API_SERVER_DNS_NAME
            - oauth-$HC_NAME.$HYPERSHIFT_DNS_DOMAIN
          servingCertificate:
            name: $AGGREGATED_CERT_SECRET_NAME"

    # Wait for kube-apiserver and oauth-openshift to restart
    until (( $(mgmt oc get deployment -n "$HCP_NS" kube-apiserver -o jsonpath='{.metadata.generation}') > kas_generation )); do
        sleep 15
    done
    mgmt oc rollout status deployment -n "$HCP_NS" kube-apiserver --timeout=15m
    until (( $(mgmt oc get deployment -n "$HCP_NS" oauth-openshift -o jsonpath='{.metadata.generation}') > oauth_generation )); do
        sleep 15
    done
    mgmt oc rollout status deployment -n "$HCP_NS" oauth-openshift --timeout=6m
}

function check_cert_issuer() {
    local fqdn="$1"
    local port="$2"
    local issuer="$3"
    local cert_issuers

    cert_issuers="$(openssl s_client -connect "${fqdn}:${port}" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer)"
    if ! grep -q "$issuer" <<< "$cert_issuers"; then
        echo "Error: no ${fqdn}:${port} certificate issued by ${issuer}" >&2
        return 1
    fi
}

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Timestamp
export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

# Check clusterissuer readiness
check_clusterissuer

# Get CP service hostnames
KAS_ROUTE_HOSTNAME="$(mgmt oc get hc -A -o jsonpath='{.items[0].spec.services[?(@.service=="APIServer")].servicePublishingStrategy.route.hostname}')"
if [[ -z "$KAS_ROUTE_HOSTNAME" ]]; then
    echo "Empty KAS route hostname, exiting" >&2
    exit 1
fi
OAUTH_ROUTE_HOSTNAME="$(mgmt oc get hc -A -o jsonpath='{.items[0].spec.services[?(@.service=="OAuthServer")].servicePublishingStrategy.route.hostname}')"
if [[ -z "$OAUTH_ROUTE_HOSTNAME" ]]; then
    echo "Empty OAuth route hostname, exiting" >&2
    exit 1
fi
HYPERSHIFT_DNS_DOMAIN="$(cut -d '.' -f 1 --complement <<< "$KAS_ROUTE_HOSTNAME")"

# Create aggregated cert
AGGREGATED_CERT_NAME=custom-aggregated-cert
AGGREGATED_CERT_SECRET_NAME=cert-manager-managed-aggregated-cert-tls
INGRESS_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
HC_NAME="$(cut -d '.' -f 2 <<< "$INGRESS_DOMAIN")"
HCP_NS="clusters-$HC_NAME"

# Get kubeAPIServerDNSName from HostedCluster spec
KUBE_API_SERVER_DNS_NAME="$(mgmt oc get hc -n clusters "$HC_NAME" -o jsonpath='{.spec.kubeAPIServerDNSName}')"
if [[ -z "$KUBE_API_SERVER_DNS_NAME" ]]; then
    echo "kubeAPIServerDNSName is not set in HostedCluster spec." >&2
    exit 1
fi

create_aggregated_cert

# Configure ic cert
configure_default_ic_cert

# Check console cert
CONSOLE_URL="$(oc whoami --show-console)"
CONSOLE_FQDN="${CONSOLE_URL#*://}"
check_cert_issuer "$CONSOLE_FQDN" 443 "Let's Encrypt"

# Copy certificates to MC
TMP_DIR=/tmp/cert-manager-aggregated-cert-hypershift
mkdir -p "$TMP_DIR"
pushd "$TMP_DIR"
oc extract secret/"$AGGREGATED_CERT_SECRET_NAME" -n openshift-ingress
mgmt oc create secret tls "$AGGREGATED_CERT_SECRET_NAME" --cert=tls.crt --key=tls.key -n clusters

# Configure kas & oauth serving cert
configure_kas_oauth_serving_cert

# Check kas custom DNS name cert & oauth cert (should use cert-manager certificate)
check_cert_issuer "$KUBE_API_SERVER_DNS_NAME" 443 "Let's Encrypt"
check_cert_issuer "$OAUTH_ROUTE_HOSTNAME" 443 "Let's Encrypt"

(
    set +x
    echo "Waiting for custom kubeconfig to be generated..."

    # Wait for customKubeconfig to be available
    CUSTOM_KUBECONFIG_SECRET=""
    RETRY_COUNT=0
    MAX_RETRIES=30
    while [[ -z "$CUSTOM_KUBECONFIG_SECRET" && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
        CUSTOM_KUBECONFIG_SECRET=$(mgmt oc get hc -n clusters "$HC_NAME" -o jsonpath='{.status.customKubeconfig.name}' 2>/dev/null || echo "")
        if [[ -z "$CUSTOM_KUBECONFIG_SECRET" ]]; then
            echo "Waiting for status.customKubeconfig to be set... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
            sleep 10
            RETRY_COUNT=$((RETRY_COUNT+1))
        fi
    done

    if [[ -z "$CUSTOM_KUBECONFIG_SECRET" ]]; then
        echo "ERROR: Custom kubeconfig not generated. spec.kubeAPIServerDNSName may not be set."
        echo "This test requires the cluster to be created with --kas-dns-name flag."
        exit 1
    fi

    echo "✓ Custom kubeconfig generated: ${CUSTOM_KUBECONFIG_SECRET}"

    # Extract the custom kubeconfig
    CUSTOM_KUBECONFIG_CONTENT="$(mgmt oc extract secret/"${CUSTOM_KUBECONFIG_SECRET}" -n clusters --to -)"

    # Check if external-dns is enabled
    # When external-dns is enabled, the custom kubeconfig needs port 443 instead of 6443
    # Workaround for https://issues.redhat.com/browse/OCPBUGS-72258
    if [[ -n "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" ]]; then
        echo "Applying port replacement: 6443 → 443 (workaround for OCPBUGS-72258)"
        CUSTOM_KUBECONFIG_CONTENT="$(echo "$CUSTOM_KUBECONFIG_CONTENT" | sed 's/:6443/:443/g')"
    else
        echo "External DNS not enabled, no port replacement needed"
    fi

    # Write modified kubeconfig to all required locations
    tee "$KUBECONFIG" "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/nested_kubeconfig" <<< "$CUSTOM_KUBECONFIG_CONTENT" >/dev/null

    echo "✓ Custom kubeconfig deployed"
    echo "Performing health check on KAS endpoint..."
)

# Perform oc login test if possible
if mgmt oc get secret/"${HC_NAME}-kubeadmin-password" -n clusters >/dev/null; then
    oc_login_kubeadmin_passwd
fi

wait_for_hc_readiness
