#!/usr/bin/env bash

set -euo pipefail
set -x

if [[ ${DYNAMIC_ADDITIONAL_TRUST_BUNDLE_ENABLED} == "false" ]]; then
  echo "SKIP additional trust bundle ....."
  exit 0
fi

#Get controlplane endpoint
if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# === Create a temp working dir ===
echo "Create TLS Cert/Key pairs..." >&2
temp_dir=$(mktemp -d)

# generate CA pair
openssl genrsa -out "$temp_dir"/hc_ca.key 2048 2>/dev/null
openssl req  -sha256 -x509 -new -nodes -key "$temp_dir"/hc_ca.key -days 100000 -out "$temp_dir"/hc_ca.crt -subj "/C=CN/ST=Beijing/L=BJ/O=Hypershift team/OU=Hypershift QE Team/CN=Hosted Cluster CA" 2>/dev/null

cp "$temp_dir"/hc_ca.key "${SHARED_DIR}"/hc_ca.key
cp "$temp_dir"/hc_ca.crt "${SHARED_DIR}"/hc_ca.crt
if [ -n "${ADDITIONAL_CA_BUNDLE_FILE}" ]; then
    cp "$temp_dir"/hc_ca.crt "${SHARED_DIR}/${ADDITIONAL_CA_BUNDLE_FILE}"
fi

rm -rf "$temp_dir"

# Make sure the namespace exists where the hc will be created, even if the hc is not created yet
oc get namespace "$HYPERSHIFT_NAMESPACE" &>/dev/null || oc create namespace "$HYPERSHIFT_NAMESPACE"

# Create a secret with `ca-bundle.crt` key and the ca crt
oc create configmap "$ADDITIONAL_CA_CONFIGMAP_NAME" -n "$HYPERSHIFT_NAMESPACE" --from-file=ca-bundle.crt="${SHARED_DIR}"/hc_ca.crt

# record the configmap name so that the following steps can read it
echo "$ADDITIONAL_CA_CONFIGMAP_NAME" > "${SHARED_DIR}"/hc_additional_trust_bundle_name

CLUSTER_NAME=$(oc get hostedclusters --ignore-not-found -n "${HYPERSHIFT_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')

function print_all_ca_fingerprints() {
    local bundle="$1" # the first argument is the content of ca trust bundle
    # Split PEM bundle into individual certs and process each
    awk 'BEGIN{RS="-----END CERTIFICATE-----\n"} NF{
        print $0 "-----END CERTIFICATE-----\0"
    }' <<<"$bundle" | while IFS= read -r -d '' cert; do
        echo "$cert" | openssl x509 -noout -fingerprint -sha256
    done
}

# retry_until_success <retries> <sleep_time> <function_name> [args...]
# - retries       : max number of attempts
# - sleep_time    : seconds between attempts
# - func          : the function to be called or a sub shell call
function retry_until_success() {
    local retries="$1"
    local sleep_time="$2"
    shift 2   # drop retries and sleep_time
    for i in $(seq 1 "$retries"); do
        echo "Attempt $i/$retries: running $*"
        if "$@"; then
            echo "Success on attempt $i"
            return 0
        fi
        echo "Failed attempt $i, retrying in $sleep_time seconds..."
        sleep "$sleep_time"
    done
    echo "$* did not succeed after $retries attempts"
    return 1
}

# If there is hosted cluster created already, we do day 2 update, which needs some time waiting for nodes rolling out
if [ ! -z "${CLUSTER_NAME}" ]; then
    cluster_addtional_trust_bundle=$(oc get hostedclusters ${CLUSTER_NAME} --ignore-not-found -n "${HYPERSHIFT_NAMESPACE}" -o jsonpath='{.spec.additionalTrustBundle.name}')
    if [ "${ADDITIONAL_CA_CONFIGMAP_NAME}" != "${cluster_addtional_trust_bundle}" ]; then
        echo "Updating HostedCluster: ${CLUSTER_NAME} to set the additionalTrustBundle to ${ADDITIONAL_CA_CONFIGMAP_NAME}"
        echo "{\"spec\":{\"additionalTrustBundle\":{\"name\":\"$ADDITIONAL_CA_CONFIGMAP_NAME\"}}}" > /tmp/patch.json
        oc patch hostedclusters -n "$HYPERSHIFT_NAMESPACE" "$CLUSTER_NAME" --type=merge -p="$(cat /tmp/patch.json)"

        echo "check day-2 additional trust bundle update"
        nodepools=$(oc get nodepools -n "$HYPERSHIFT_NAMESPACE" --ignore-not-found -o jsonpath='{.items[?(@.spec.clusterName=="'"$CLUSTER_NAME"'")].metadata.name}')
        if [ -z "$nodepools" ]; then
            echo "There is no nodepool for the hosted cluster: $CLUSTER_NAME. No need to wait for nodepool updating."
            exit 0
        fi
        # waiting for node pool's rolling out
        for np in $nodepools; do
            # check each node pool with this hc begin updating as the start of rolling
            echo "Checking nodepool $np for update..."
            retry_until_success 30 10 bash -c "oc get nodepool $np -n $HYPERSHIFT_NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"UpdatingConfig\")].status}' | grep True"

            # check each node pool with this hc stop updating as the end of rolling
            echo "Checking nodepool $np that finishing the rolling out"
            # wait for at most 60 minutes
            retry_until_success 60 60 bash -c "oc get nodepool $np -n $HYPERSHIFT_NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"UpdatingConfig\")].status}' | grep False"
            retry_until_success 60 60 bash -c "oc get nodepool $np -n $HYPERSHIFT_NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"AllNodesHealthy\")].status}' | grep True"
        done

        export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
        ca_fingerprint=$(openssl x509 -in "${SHARED_DIR}"/hc_ca.crt -noout -fingerprint -sha256|cut -d "=" -f2-)
        nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
        set +x
        for node in $nodes; do
            echo "Checking the trusted ca in node $node ..."
            node_ca_bundle=$(oc debug "node/$node" -q -- chroot /host cat /etc/pki/tls/certs/ca-bundle.crt)
            if ! print_all_ca_fingerprints "$node_ca_bundle" | grep "$ca_fingerprint" ; then
                echo "additional trust bundle did not get updated in node: $node"
                exit 1
            fi
        done
    fi
fi
