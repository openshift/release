#!/bin/bash

set -eux

EXTRA_ARGS=""
HCP_CLI="bin/hypershift"
OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST

# CRD Validation Test: Extract hypershift CLI from specific nightly build
# This is for testing the CRD validation bug fix in registry.ci.openshift.org/ocp/release:4.21.0-0.nightly-2025-10-23-225733
if [[ "${CRD_VALIDATION_TEST:-false}" == "true" ]]; then
  echo "CRD Validation Test Mode: Extracting hypershift CLI from specific nightly build"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  mkdir -p /tmp/hs-cli-4.21
  NIGHTLY_BUILD="registry.ci.openshift.org/ocp/release:4.21.0-0.nightly-2025-10-23-225733"
  echo "Extracting hypershift CLI from: $NIGHTLY_BUILD"
  
  # Extract the entire image to inspect its contents
  echo "Inspecting image contents..."
  oc image extract $NIGHTLY_BUILD --path /:/tmp/image-root --registry-config=/tmp/.dockerconfigjson --filter-by-os="linux/amd64" || true
  
  # Look for hypershift binary in common locations
  if [[ -f "/tmp/image-root/usr/bin/hypershift" ]]; then
    echo "Found hypershift at /usr/bin/hypershift"
    cp /tmp/image-root/usr/bin/hypershift /tmp/hs-cli-4.21/hypershift
  elif [[ -f "/tmp/image-root/bin/hypershift" ]]; then
    echo "Found hypershift at /bin/hypershift"
    cp /tmp/image-root/bin/hypershift /tmp/hs-cli-4.21/hypershift
  elif [[ -f "/tmp/image-root/usr/local/bin/hypershift" ]]; then
    echo "Found hypershift at /usr/local/bin/hypershift"
    cp /tmp/image-root/usr/local/bin/hypershift /tmp/hs-cli-4.21/hypershift
  else
    echo "ERROR: Could not find hypershift binary in the nightly build image"
    echo "Available files in /usr/bin:"
    ls -la /tmp/image-root/usr/bin/ || true
    echo "Available files in /bin:"
    ls -la /tmp/image-root/bin/ || true
    echo "Available files in /usr/local/bin:"
    ls -la /tmp/image-root/usr/local/bin/ || true
    echo "Falling back to default hypershift CLI"
    HCP_CLI="bin/hypershift"
  fi
  
  # If we found the binary, make it executable
  if [[ -f "/tmp/hs-cli-4.21/hypershift" ]]; then
    chmod +x /tmp/hs-cli-4.21/hypershift
    HCP_CLI="/tmp/hs-cli-4.21/hypershift"
    echo "Using hypershift CLI from nightly build: $HCP_CLI"
  else
    echo "Using default hypershift CLI: $HCP_CLI"
  fi
  
  # Use the nightly build as the operator image for CRD validation testing
  OPERATOR_IMAGE=$NIGHTLY_BUILD
  echo "Using nightly build as operator image: $OPERATOR_IMAGE"
elif [[ $HO_MULTI == "true" ]]; then
  OPERATOR_IMAGE="quay.io/acm-d/rhtap-hypershift-operator:latest"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  mkdir /tmp/hs-cli
  oc image extract quay.io/acm-d/rhtap-hypershift-operator:latest --path /usr/bin/hypershift:/tmp/hs-cli --registry-config=/tmp/.dockerconfigjson --filter-by-os="linux/amd64"
  chmod +x /tmp/hs-cli/hypershift
  HCP_CLI="/tmp/hs-cli/hypershift"
elif [[ $INSTALL_FROM_LATEST == "true" ]]; then
  # We should use the hypershift cli from the HYPERSHIFT_RELEASE_LATEST
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  mkdir /tmp/hs-cli
  oc image extract $HYPERSHIFT_RELEASE_LATEST --path /usr/bin/hypershift:/tmp/hs-cli --registry-config=/tmp/.dockerconfigjson --filter-by-os="linux/amd64"
  chmod +x /tmp/hs-cli/hypershift
  HCP_CLI="/tmp/hs-cli/hypershift"
fi

if [ "${TECH_PREVIEW_NO_UPGRADE}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --tech-preview-no-upgrade"
fi

if [ "${ENABLE_HYPERSHIFT_OPERATOR_DEFAULTING_WEBHOOK}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-defaulting-webhook=true"
fi

if [ "${ENABLE_HYPERSHIFT_OPERATOR_VALIDATING_WEBHOOK}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-validating-webhook=true"
fi

if [ "${ENABLE_HYPERSHIFT_CERT_ROTATION_SCALE}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --cert-rotation-scale=20m"
fi

AZURE_EXTERNAL_DNS_DOMAIN="service.hypershift.azure.devcluster.openshift.com"
if [ "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" != "" ]; then
  AZURE_EXTERNAL_DNS_DOMAIN="${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
fi

if [ "${AUTH_THROUGH_CERTS}" == "true" ]; then
  KEYVAULT_CLIENT_ID="$(<"${SHARED_DIR}/aks_keyvault_secrets_provider_client_id")"
  EXTRA_ARGS="${EXTRA_ARGS} --aro-hcp-key-vault-users-client-id ${KEYVAULT_CLIENT_ID}"
fi

if [ "${ENABLE_SIZE_TAGGING}" == "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-size-tagging"
fi

if [ "${TEST_CPO_OVERRIDE}" == "1" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-cpo-overrides"
fi

if [ "${CLOUD_PROVIDER}" == "AWS" ]; then
  "${HCP_CLI}" install --hypershift-image="${OPERATOR_IMAGE}" \
  --oidc-storage-provider-s3-credentials=/etc/hypershift-pool-aws-credentials/credentials \
  --oidc-storage-provider-s3-bucket-name=hypershift-ci-oidc \
  --oidc-storage-provider-s3-region=us-east-1 \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --private-platform=AWS \
  --aws-private-creds=/etc/hypershift-pool-aws-credentials/credentials \
  --aws-private-region="${HYPERSHIFT_AWS_REGION}" \
  --external-dns-provider=aws \
  --external-dns-credentials=/etc/hypershift-pool-aws-credentials/credentials \
  --external-dns-domain-filter=service.ci.hypershift.devcluster.openshift.com \
  --wait-until-available \
  ${EXTRA_ARGS}
fi

if [ "${AKS}" == "true" ]; then
  oc delete secret azure-config-file --namespace "default" --ignore-not-found=true
  oc create secret generic azure-config-file --namespace "default" --from-file=etc/hypershift-aks-e2e-dns-credentials/credentials.json
  oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
  oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
  oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
  oc apply -f https://raw.githubusercontent.com/openshift/api/6bababe9164ea6c78274fd79c94a3f951f8d5ab2/route/v1/zz_generated.crd-manifests/routes.crd.yaml
fi

if [ "${CLOUD_PROVIDER}" == "Azure" ]; then
  "${HCP_CLI}" install --hypershift-image="${OPERATOR_IMAGE}" \
  --enable-conversion-webhook=false \
  --managed-service=ARO-HCP \
  --external-dns-provider=azure \
  --external-dns-credentials=/etc/hypershift-aks-e2e-dns-credentials/credentials.json \
  --external-dns-domain-filter="${AZURE_EXTERNAL_DNS_DOMAIN}" \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
  --wait-until-available \
  ${EXTRA_ARGS}
fi

if [ "${CLOUD_PROVIDER}" != "Azure" ] && [ "${CLOUD_PROVIDER}" != "AWS" ]; then
  "${HCP_CLI}" install --hypershift-image="${OPERATOR_IMAGE}" \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
  --wait-until-available \
  ${EXTRA_ARGS}
fi
