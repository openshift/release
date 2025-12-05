#!/bin/bash

set -exuo pipefail

generate_large_trust_bundle() {
    local output_file="$1"
    local target_size=$2
    local cert_count=0

    echo "Generating large trust bundle (target: ${target_size} bytes)..."

    while [ $(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null) -lt $target_size ]; do
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -keyout /tmp/key-${cert_count}.pem \
            -out /tmp/cert-${cert_count}.pem \
            -subj "/C=US/ST=Test/L=Test/O=TestOrg/CN=TestCA-${cert_count}" \
            2>/dev/null

        # Append certificate to bundle file
        cat /tmp/cert-${cert_count}.pem >> "$output_file"
        cert_count=$((cert_count + 1))

        # Clean up temp files
        rm -f /tmp/key-${cert_count}.pem /tmp/cert-${cert_count}.pem
    done

    local actual_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
    echo "Generated trust bundle with ${cert_count} certificates, total size: ${actual_size} bytes ($(echo "scale=2; ${actual_size}/1024" | bc) KB)"

    if [ $actual_size -lt 16384 ]; then
        echo "ERROR: Trust bundle size (${actual_size} bytes) is less than 16KB, test will not validate the fix"
        exit 1
    fi
}

HC_RENDER_FILE="${SHARED_DIR}"/hypershift_create_cluster_render.yaml
if [ ! -f "${HC_RENDER_FILE}" ]; then
  echo "Error: No hostedcluster render file created"
  exit 1
fi

curl -L https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

HOSTED_CLUSTER_NAME=$(/tmp/yq 'select(.kind == "HostedCluster") | .metadata.name' ${HC_RENDER_FILE})
HOSTED_CLUSTER_NS=$(/tmp/yq 'select(.kind == "Namespace") | .metadata.name' ${HC_RENDER_FILE})
EXISTING_TRUST_BUNDLE=$(/tmp/yq 'select(.kind == "HostedCluster") | .spec.additionalTrustBundle.name // ""' ${HC_RENDER_FILE})
EXISTING_PROXY_CA=$(/tmp/yq 'select(.kind == "HostedCluster") | .spec.configuration.proxy.trustedCA.name // ""' ${HC_RENDER_FILE})
if [[ -n "$EXISTING_TRUST_BUNDLE" || -n "$EXISTING_PROXY_CA" ]] ; then
  echo "Notice: additionalTrustBundle or proxy CA is not empty, please change the configure to test large trust bundle."
  echo "Insisting on adding this step may overwrite the original configuration."
fi

TRUST_BUNDLE_FILE="/tmp/large-trust-bundle.crt"
touch "$TRUST_BUNDLE_FILE"
generate_large_trust_bundle "$TRUST_BUNDLE_FILE" "20480" # 20KB

TRUST_BUNDLE_CM_NAME="large-trust-bundle"
echo "---" >> ${HC_RENDER_FILE}
oc create configmap ${TRUST_BUNDLE_CM_NAME} --from-file=ca-bundle.crt=${TRUST_BUNDLE_FILE} -n ${HOSTED_CLUSTER_NS} --dry-run=client -o yaml >> ${HC_RENDER_FILE}

cat <<EOF > /tmp/patch.yaml
spec:
  additionalTrustBundle:
    name: ${TRUST_BUNDLE_CM_NAME}
  configuration:
    proxy:
      trustedCA:
        name: ${TRUST_BUNDLE_CM_NAME}
EOF

echo "Patching rendered artifacts"
/tmp/yq 'select(.kind == "HostedCluster") *= load("/tmp/patch.yaml")' ${HC_RENDER_FILE} \
    > "${SHARED_DIR}"/hypershift_create_cluster_render_large_trust_bundle.yaml

echo "Applying patched artifacts"
oc apply -f "${SHARED_DIR}"/hypershift_create_cluster_render_large_trust_bundle.yaml


echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${HOSTED_CLUSTER_NS} hostedcluster/${HOSTED_CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
hypershift create kubeconfig --namespace=${HOSTED_CLUSTER_NS} --name=${HOSTED_CLUSTER_NAME} > ${SHARED_DIR}/nested_kubeconfig
echo "${HOSTED_CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
