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

function create_aggregated_cert() {
    oc create -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $AGGREGATED_CERT_NAME
  namespace: openshift-ingress
spec:
  commonName: "*.${INGRESS_DOMAIN}"
  dnsNames:
  - "*.${INGRESS_DOMAIN}"
  - "api-${HC_NAME}.${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
  - "oauth-${HC_NAME}.${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
  usages:
  - server auth
  issuerRef:
    kind: ClusterIssuer
    name: $CLUSTERISSUER_NAME
  secretName: $AGGREGATED_CERT_SECRET_NAME
  duration: 2h
  renewBefore: 1h30m
EOF
    oc wait certificate "$AGGREGATED_CERT_NAME" -n openshift-ingress --for=condition=Ready=True --timeout=5m
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
        - servingCertificate:
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

function remove_kubelet_kubeconfig_cluster_ca() {
    local pids_to_wait=()

    for node in $(oc get node -o jsonpath='{.items[*].metadata.name}'); do
        { timeout 90s oc debug node/"$node" -- chroot /host bash -c '
# Wait for the debug pod to be ready
sleep 60
sed "/certificate-authority-data/d" /var/lib/kubelet/kubeconfig > /var/lib/kubelet/kubeconfig.tmp
mv /var/lib/kubelet/kubeconfig.tmp /var/lib/kubelet/kubeconfig
systemctl restart kubelet' || true; } &
        pids_to_wait+=($!)
    done
    wait "${pids_to_wait[@]}"

    # Nodes become unreachable
    oc wait node --all --for=condition=Ready=Unknown --timeout=5m
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
CLUSTERISSUER_NAME=cluster-certs-clusterissuer
oc wait clusterissuer "$CLUSTERISSUER_NAME" --for=condition=Ready=True --timeout=0

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
HYPERSHIFT_EXTERNAL_DNS_DOMAIN="$(cut -d '.' -f 1 --complement <<< "$KAS_ROUTE_HOSTNAME")"

# Create aggregated cert
AGGREGATED_CERT_NAME=custom-ingress-cert
AGGREGATED_CERT_SECRET_NAME=cert-manager-managed-ingress-cert-tls
INGRESS_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
HC_NAME="$(cut -d '.' -f 2 <<< "$INGRESS_DOMAIN")"
HCP_NS="clusters-$HC_NAME"
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

# Get kubeconfig cluster ca data before configuring kas serving cert
BACKUP_KUBECONFIG_CA_DATA="$(grep certificate-authority-data "$KUBECONFIG" | awk '{print $2}')"

# Update KUBECONFIG to allow secure communication between kubelets and the external KAS endpoint
# TODO: remove this workaround once https://issues.redhat.com/browse/OCPBUGS-41853 is resolved
remove_kubelet_kubeconfig_cluster_ca

# Configure kas & oauth serving cert
configure_kas_oauth_serving_cert

# Check kas & oauth cert
check_cert_issuer "$KAS_ROUTE_HOSTNAME" 443 "Let's Encrypt"
check_cert_issuer "$OAUTH_ROUTE_HOSTNAME" 443 "Let's Encrypt"

# Download the updated KUBECONFIG after it's reconciled to include the default ingress certificate
(
    set +x
    CURRENT_KUBECONFIG_CONTENT="$(mgmt oc extract secret/"${HC_NAME}-admin-kubeconfig" -n clusters --to -)"
    CURRENT_KUBECONFIG_CA_DATA="$(grep certificate-authority-data <<< "$CURRENT_KUBECONFIG_CONTENT" | awk '{print $2}')"
    until [[ "$CURRENT_KUBECONFIG_CA_DATA" != "$BACKUP_KUBECONFIG_CA_DATA" ]]; do
        CURRENT_KUBECONFIG_CONTENT="$(mgmt oc extract secret/"${HC_NAME}-admin-kubeconfig" -n clusters --to -)"
        CURRENT_KUBECONFIG_CA_DATA="$(grep certificate-authority-data <<< "$CURRENT_KUBECONFIG_CONTENT" | awk '{print $2}')"
        sleep 15
    done
    tee "$KUBECONFIG" "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/nested_kubeconfig" <<< "$CURRENT_KUBECONFIG_CONTENT" >/dev/null
)

# Perform oc login test if possible
if mgmt oc get secret/"${HC_NAME}-kubeadmin-password" -n clusters >/dev/null; then
    oc_login_kubeadmin_passwd
fi

# Restart ovnkube-node
oc delete po -n openshift-ovn-kubernetes --all

wait_for_hc_readiness
