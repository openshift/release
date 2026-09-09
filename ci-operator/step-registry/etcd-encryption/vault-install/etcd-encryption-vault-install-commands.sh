#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

resolve_image_repo() {
  local image="$1"
  if [[ "${image}" == *@* ]]; then
    echo "${image%%@*}"
  else
    echo "${image%:*}"
  fi
}

resolve_image_tag() {
  local image="$1"
  if [[ "${image}" == *@* ]]; then
    echo "${image##*@}"
  else
    echo "${image##*:}"
  fi
}

resolve_image_mirror_destination() {
  local local_repo="$1"
  local image="$2"
  if [[ "${image}" == *@* ]]; then
    # oc image mirror requires a tag on DST or a blank tag to push by digest only.
    echo "${local_repo}"
  else
    echo "${local_repo}:$(resolve_image_tag "${image}")"
  fi
}

record_vault_images() {
  if [[ -z "${VAULT_ENTERPRISE_IMAGE:-}" ]]; then
    echo "Error: VAULT_ENTERPRISE_IMAGE is required"
    exit 1
  fi
  if [[ -z "${VAULT_KMS_PLUGIN_IMAGE:-}" ]]; then
    echo "Error: VAULT_KMS_PLUGIN_IMAGE is required"
    exit 1
  fi

  VAULT_IMAGE_REPOSITORY="$(resolve_image_repo "${VAULT_ENTERPRISE_IMAGE}")"
  VAULT_VERSION="$(resolve_image_tag "${VAULT_ENTERPRISE_IMAGE}")"
  export VAULT_IMAGE_REPOSITORY VAULT_VERSION

  echo "Vault Enterprise image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "  Helm repository: ${VAULT_IMAGE_REPOSITORY}"
  echo "  Helm tag: ${VAULT_VERSION}"
  echo "  ICSP source: $(resolve_image_repo "${VAULT_ENTERPRISE_IMAGE}")"
  echo "${VAULT_ENTERPRISE_IMAGE}" > "${SHARED_DIR}/vault-enterprise-image"

  echo "Vault KMS plugin image: ${VAULT_KMS_PLUGIN_IMAGE}"
  echo "  ICSP source: $(resolve_image_repo "${VAULT_KMS_PLUGIN_IMAGE}")"
  if [[ "${VAULT_KMS_PLUGIN_IMAGE}" == *@* ]]; then
    echo "  local mirror: push by digest to localimages/vault-kube-kms"
  fi
  echo "${VAULT_KMS_PLUGIN_IMAGE}" > "${SHARED_DIR}/vault-kms-plugin-image"
}

mirror_vault_images() {
  local vault_enterprise_src="${VAULT_ENTERPRISE_IMAGE}"
  local vault_enterprise_dst
  local vault_kms_src="${VAULT_KMS_PLUGIN_IMAGE}"
  local vault_kms_dst
  vault_enterprise_dst="$(resolve_image_mirror_destination "${DS_REGISTRY}/localimages/vault-enterprise" "${VAULT_ENTERPRISE_IMAGE}")"
  vault_kms_dst="$(resolve_image_mirror_destination "${DS_REGISTRY}/localimages/vault-kube-kms" "${VAULT_KMS_PLUGIN_IMAGE}")"

  echo "Mirroring vault images to local registry..."
  echo "  ${vault_enterprise_src} -> ${vault_enterprise_dst}"
  echo "  ${vault_kms_src} -> ${vault_kms_dst}"

  # shellcheck disable=SC2087
  ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -euo pipefail

MAX_RETRIES=3
CURRENT_RETRY=1
SUCCESS=false

function run-vault-image-mirror() {
  oc image mirror --keep-manifest-list=true --registry-config ${DS_WORKING_DIR}/pull_secret.json \
    "${vault_enterprise_src}" "${vault_enterprise_dst}" || return 1
  oc image mirror --keep-manifest-list=true --registry-config ${DS_WORKING_DIR}/pull_secret.json \
    "${vault_kms_src}" "${vault_kms_dst}" || return 1
}

while [ \$SUCCESS = false ] && [ \$CURRENT_RETRY -le \$MAX_RETRIES ]; do
  echo "Mirroring vault images attempt \$CURRENT_RETRY"
  run-vault-image-mirror
  if [ \$? -eq 0 ]; then
    SUCCESS=true
  else
    echo "Mirroring vault images attempt \$CURRENT_RETRY failed. Trying again..."
    CURRENT_RETRY=\$(( CURRENT_RETRY + 1 ))
    sleep 5
  fi
done

if [ \$SUCCESS = false ]; then
  echo "Mirroring vault images failed after \$MAX_RETRIES attempts."
  exit 1
fi
EOF

  VAULT_IMAGE_REPOSITORY="${DS_REGISTRY}/localimages/vault-enterprise"
  export VAULT_IMAGE_REPOSITORY
  echo "Using mirrored Vault image repository: ${VAULT_IMAGE_REPOSITORY}"
}

apply_vault_icsp() {
  local vault_enterprise_icsp_source
  local vault_kms_icsp_source
  vault_enterprise_icsp_source="$(resolve_image_repo "${VAULT_ENTERPRISE_IMAGE}")"
  vault_kms_icsp_source="$(resolve_image_repo "${VAULT_KMS_PLUGIN_IMAGE}")"

  echo "Applying ImageContentSourcePolicy for vault images..."
  oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: vault-mirror
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${DS_REGISTRY}/localimages/vault-enterprise
    source: ${vault_enterprise_icsp_source}
  - mirrors:
    - ${DS_REGISTRY}/localimages/vault-kube-kms
    source: ${vault_kms_icsp_source}
EOF

  echo "Waiting for ICSP to propagate to nodes..."
  oc wait machineconfigpool/master --for=condition=Updated=True --timeout=10m
  oc wait machineconfigpool/worker --for=condition=Updated=True --timeout=10m
}

setup_packet_cluster() {
  if [[ -n "${CLUSTER_TYPE:-}" && "${CLUSTER_TYPE}" == equinix-ocp-metal ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/ds-vars.conf"

    # For disconnected or otherwise unreachable environments, we want to
    # have steps use an HTTP(S) proxy to reach the API server. This proxy
    # configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
    # environment variables, as well as their lowercase equivalents (note
    # that libcurl doesn't recognize the uppercase variables).
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
      # shellcheck source=/dev/null
      source "${SHARED_DIR}/proxy-conf.sh"
    fi

    # Always mirror on baremetal. Nodes often lack IPv6 egress to quay.io even when
    # DS_IP_STACK=v4 (connected), while pods still use IPv6 addresses. The dev-scripts
    # local registry is reachable from all metal nodes regardless of IP stack.
    echo "mirroring Vault to local registry"
    mirror_vault_images
    apply_vault_icsp
  fi
}

wait_until() {
  local desc="$1"
  local attempts="$2"
  local interval="$3"
  shift 3
  local i=0
  until "$@"; do
    i=$((i + 1))
    if [[ "${i}" -ge "${attempts}" ]]; then
      echo "Timed out waiting for ${desc}"
      return 1
    fi
    sleep "${interval}"
  done
}

VAULT_SECRET_UNSEAL_KEY_PATH="/vault/secrets/unseal/unseal-key"

vault_exec() {
  local namespace="$1"
  local pod_name="$2"
  shift 2
  oc exec -c vault "${pod_name}" -n "${namespace}" -- \
    env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true "$@"
}

# Prepare the namespace, SCC, and license secret for a Vault instance.
# Must run before setup_packet_cluster() to avoid proxy interference.
# Args: $1 = namespace, $2 = Helm release name
setup_vault_namespace() {
  local namespace="$1"
  local release_name="$2"

  echo "Creating namespace ${namespace}..."
  oc create namespace "${namespace}" --dry-run=client -o yaml | oc apply -f -

  echo "Adding restricted SCC for Vault service account..."
  oc adm policy add-scc-to-user restricted -z "${release_name}" -n "${namespace}"

  echo "Creating Vault license secret from mounted credential..."
  oc create secret generic "${VAULT_LICENSE_SECRET_NAME}" \
    --from-file=license=/var/run/vault/tests-private-account/kms-vault-license \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
}

store_vault_init_secrets() {
  local namespace="$1"
  local init_json="$2"

  # Disable tracing due to password handling
  local WAS_TRACING=false
  [[ $- == *x* ]] && WAS_TRACING=true
  set +x
  local unseal_key root_token
  unseal_key="$(jq -r '.unseal_keys_b64[0]' <<<"${init_json}")"
  root_token="$(jq -r '.root_token' <<<"${init_json}")"
  oc create secret generic vault-unseal-key \
    --from-literal=unseal-key="${unseal_key}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic vault-root-token \
    --from-literal=token="${root_token}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | oc apply -f -
  unset unseal_key root_token
  if [[ "${WAS_TRACING}" == true ]]; then
    set -x
  fi
}

unseal_vault() {
  local namespace="$1"
  local pod_name="$2"

  vault_exec "${namespace}" "${pod_name}" sh -c \
    "test -s '${VAULT_SECRET_UNSEAL_KEY_PATH}' && vault operator unseal \"\$(cat '${VAULT_SECRET_UNSEAL_KEY_PATH}')\" >/dev/null"
}

wait_for_mounted_secret() {
  local namespace="$1"
  local pod_name="$2"
  local secret_path="$3"

  wait_until "mounted secret at ${secret_path}" 60 2 \
    vault_exec "${namespace}" "${pod_name}" test -s "${secret_path}"
}

wait_for_vault_listener() {
  local namespace="$1"
  local pod_name="$2"
  local i=0
  local status_rc=0

  echo "Waiting for Vault listener on ${pod_name}..."
  while true; do
    set +e
    vault_exec "${namespace}" "${pod_name}" vault status >/dev/null 2>&1
    status_rc=$?
    set -e
    # 0 = unsealed, 2 = sealed; both mean the TLS listener is up.
    if [[ "${status_rc}" -eq 0 || "${status_rc}" -eq 2 ]]; then
      return 0
    fi
    i=$((i + 1))
    if [[ "${i}" -ge 60 ]]; then
      echo "Timed out waiting for Vault listener on ${pod_name}"
      oc logs -c vault "${pod_name}" -n "${namespace}" --tail=50 || true
      return 1
    fi
    sleep 5
  done
}

initialize_or_unseal_vault() {
  local namespace="$1"
  local pod_name="$2"
  local status_rc=0

  wait_for_vault_listener "${namespace}" "${pod_name}"

  set +e
  vault_exec "${namespace}" "${pod_name}" vault status >/dev/null 2>&1
  status_rc=$?
  set -e

  if [[ "${status_rc}" -eq 0 ]]; then
    echo "Vault is already unsealed"
    if ! oc get secret vault-root-token -n "${namespace}" >/dev/null 2>&1; then
      echo "Error: Vault is unsealed but vault-root-token secret is missing"
      exit 1
    fi
    return 0
  fi

  if oc get secret vault-unseal-key -n "${namespace}" >/dev/null 2>&1; then
    if ! oc get secret vault-root-token -n "${namespace}" >/dev/null 2>&1; then
      echo "Error: vault-unseal-key exists but vault-root-token secret is missing"
      exit 1
    fi
    echo "Unsealing Vault with stored key..."
    wait_for_mounted_secret "${namespace}" "${pod_name}" "${VAULT_SECRET_UNSEAL_KEY_PATH}"
    unseal_vault "${namespace}" "${pod_name}"
    return 0
  fi

  echo "Initializing Vault..."
  local was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  set +x
  local init_json
  init_json="$(vault_exec "${namespace}" "${pod_name}" vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  store_vault_init_secrets "${namespace}" "${init_json}"
  unset init_json
  if [[ "${was_tracing}" == true ]]; then
    set -x
  fi
  wait_for_mounted_secret "${namespace}" "${pod_name}" "${VAULT_SECRET_UNSEAL_KEY_PATH}"
  unseal_vault "${namespace}" "${pod_name}"
}

# Install a Vault Enterprise instance in the given namespace.
# Args: $1 = namespace, $2 = CA ConfigMap name, $3 = Helm release name
install_vault() {
  local namespace="$1"
  local ca_configmap="$2"
  local release_name="$3"
  local pod_name="${release_name}-0"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation via Helm"
  echo "========================================="
  echo "Image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "Namespace: ${namespace}"
  echo ""

  local vault_api_addr="https://${release_name}.${namespace}.svc:8200"
  local serving_cert="${release_name}-serving-cert"
  local vault_service_fqdn="${release_name}.${namespace}.svc"
  local values_file="/tmp/vault-values-${namespace}.yaml"
  local vault_image="${VAULT_IMAGE_REPOSITORY}:${VAULT_VERSION}"

  cat > "${values_file}" <<EOF
global:
  enabled: true
  openshift: true
  tlsDisable: false
injector:
  enabled: false
server:
  image:
    repository: ${VAULT_IMAGE_REPOSITORY}
    tag: "${VAULT_VERSION}"
  standalone:
    enabled: true
    config: |
      listener "tcp" {
        address = "[::]:8200"
        tls_cert_file = "/var/run/tls/tls.crt"
        tls_key_file = "/var/run/tls/tls.key"
      }
      storage "file" {
        path = "/vault/data"
      }
  dataStorage:
    enabled: true
    size: 1Gi
  ha:
    apiAddr: "${vault_api_addr}"
  extraEnvironmentVars:
    VAULT_DISABLE_USER_LOCKOUT: "true"
  enterpriseLicense:
    secretName: ${VAULT_LICENSE_SECRET_NAME}
    secretKey: license
  volumes:
    - name: tls
      secret:
        secretName: ${serving_cert}
    - name: unseal-key
      secret:
        secretName: vault-unseal-key
        optional: true
    - name: root-token
      secret:
        secretName: vault-root-token
        optional: true
  volumeMounts:
    - name: tls
      mountPath: /var/run/tls
    - name: unseal-key
      mountPath: /vault/secrets/unseal
      readOnly: true
    - name: root-token
      mountPath: /vault/secrets/root
      readOnly: true
  extraContainers:
    - name: auto-unseal
      image: ${vault_image}
      imagePullPolicy: IfNotPresent
      env:
        - name: VAULT_ADDR
          value: https://127.0.0.1:8200
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
      command:
        - /bin/sh
        - -ec
        - |
          while true; do
            if [ -s /vault/unseal/unseal-key ]; then
              vault operator unseal -tls-skip-verify "\$(cat /vault/unseal/unseal-key)" >/dev/null 2>&1 || true
            fi
            sleep 5
          done
      volumeMounts:
        - name: unseal-key
          mountPath: /vault/unseal
          readOnly: true
EOF

  # service-CA serving cert: its CA is stable across restarts, so vault-ca-bundle never drifts.
  # File storage on a PVC keeps the transit mount across pod restarts; the sidecar unseals
  # using vault-unseal-key whenever the process comes back sealed.
  echo "Installing Vault Enterprise ${VAULT_ENTERPRISE_IMAGE} with service-CA TLS and persistent storage..."
  helm upgrade --install "${release_name}" "${VAULT_CHART_ARCHIVE}" \
    --namespace "${namespace}" \
    --version "${VAULT_CHART_VERSION}" \
    -f "${values_file}" \
    --timeout 10m

  # Chart 0.28.1 copies server.service.annotations onto both the client Service
  # and vault-internal. Annotate only the client Service so the serving cert is
  # valid for vault.vault-kms.svc, which is what the KMS tests connect to.
  echo "Requesting service-CA serving certificate for ${vault_service_fqdn}..."
  oc annotate service "${release_name}" -n "${namespace}" \
    "service.beta.openshift.io/serving-cert-secret-name=${serving_cert}" --overwrite

  echo "Waiting for serving certificate secret ${serving_cert}..."
  wait_until "serving certificate secret ${serving_cert}" 60 5 \
    oc get secret "${serving_cert}" -n "${namespace}"

  serving_cert_has_san() {
    oc get secret "${serving_cert}" -n "${namespace}" -o jsonpath='{.data.tls\.crt}' \
      | base64 -d \
      | openssl x509 -noout -text 2>/dev/null \
      | grep -Fq "${vault_service_fqdn}"
  }

  echo "Waiting for serving certificate to include ${vault_service_fqdn}..."
  if ! wait_until "serving certificate SAN ${vault_service_fqdn}" 60 5 serving_cert_has_san; then
    oc get secret "${serving_cert}" -n "${namespace}" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text || true
    exit 1
  fi

  # Do not delete the pod to "pick up" the cert. The TLS secret is a required
  # volume, so the pod stays pending until the cert exists and then starts once
  # with the correct SAN already mounted.
  echo "Waiting for persistent volume claim data-${pod_name}..."
  wait_until "pvc data-${pod_name}" 60 5 oc get "pvc/data-${pod_name}" -n "${namespace}"
  if ! oc wait --for=jsonpath='{.status.phase}'=Bound "pvc/data-${pod_name}" -n "${namespace}" --timeout=10m; then
    echo "PVC data-${pod_name} did not bind"
    oc get storageclass || true
    oc describe "pvc/data-${pod_name}" -n "${namespace}" || true
    exit 1
  fi

  echo "Waiting for Vault pod to be Running..."
  oc wait --for=jsonpath='{.status.phase}'=Running "pod/${pod_name}" -n "${namespace}" --timeout=10m

  echo "Initializing and unsealing Vault..."
  initialize_or_unseal_vault "${namespace}" "${pod_name}"
  oc wait --for=condition=ready "pod/${pod_name}" -n "${namespace}" --timeout=5m

  # Publish the stable service-CA bundle as the trust anchor.
  echo "Waiting for service-CA bundle ConfigMap..."
  service_ca_bundle_ready() {
    [[ -n "$(oc get configmap openshift-service-ca.crt -n "${namespace}" \
      -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)" ]]
  }
  wait_until "service-ca.crt data in ${namespace}" 60 5 service_ca_bundle_ready

  CA_CERT_TMP="/tmp/vault-ca-${namespace}.pem"
  oc get configmap openshift-service-ca.crt -n "${namespace}" -o jsonpath='{.data.service-ca\.crt}' > "${CA_CERT_TMP}"
  if [[ ! -s "${CA_CERT_TMP}" ]]; then
    echo "Error: extracted service-CA bundle is empty"
    exit 1
  fi
  echo "  ✓ service-CA bundle extracted"

  # Create or update ConfigMap with CA certificate in openshift-config
  echo ""
  echo "Creating ConfigMap ${ca_configmap} in openshift-config..."
  oc create configmap "${ca_configmap}" \
    --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  echo "  ✓ ConfigMap ${ca_configmap} created/updated"

  # Clean up temporary CA file
  rm -f "${CA_CERT_TMP}"

  echo ""
  echo "========================================="
  echo "Vault Enterprise Installation Complete"
  echo "========================================="
  echo ""
  echo "Summary:"
  echo "  - Namespace: ${namespace}"
  echo "  - Image: ${VAULT_ENTERPRISE_IMAGE}"
  echo "  - Service: https://${release_name}.${namespace}.svc:8200"
  echo "  - Pod: ${pod_name} (Ready)"
  echo "  - TLS: Enabled (OpenShift service-CA serving certificate)"
  echo "  - TLS cert: /var/run/tls/tls.crt (inside pod)"
  echo "  - TLS SAN: ${vault_service_fqdn}"
  echo "  - Storage: file backend on pvc/data-${pod_name} (transit keys persist across restarts)"
  echo "  - Auto-unseal sidecar using vault-unseal-key secret"
  echo "  - Enterprise License: Configured"
  echo "  - CA ConfigMap: ${ca_configmap} (openshift-config namespace)"
  echo ""
  echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
  echo ""
}

# Vault license secret name
VAULT_LICENSE_SECRET_NAME="vault-license"

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.14.0"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

record_vault_images

setup_vault_namespace "${VAULT_NAMESPACE}" "vault"
setup_vault_namespace "${VAULT_SECONDARY_NAMESPACE}" "vault-secondary"

# Fetch the Helm chart before baremetalds proxy env is applied; hashicorp chart
# downloads fail with Forbidden once proxy-conf.sh is sourced on metal jobs.
echo "Fetching HashiCorp Vault Helm chart..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
VAULT_CHART_ARCHIVE="/tmp/vault-${VAULT_CHART_VERSION}.tgz"
helm pull hashicorp/vault --version "${VAULT_CHART_VERSION}" --destination /tmp
echo "Chart downloaded to ${VAULT_CHART_ARCHIVE}"

echo ""

setup_packet_cluster

install_vault "${VAULT_NAMESPACE}" "vault-ca-bundle" "vault"
install_vault "${VAULT_SECONDARY_NAMESPACE}" "vault-ca-bundle-secondary" "vault-secondary"
