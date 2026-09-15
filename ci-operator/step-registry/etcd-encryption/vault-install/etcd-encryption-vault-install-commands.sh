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
  local registry_port="${DS_REGISTRY##*:}"
  vault_enterprise_dst="$(resolve_image_mirror_destination "${DS_REGISTRY}/localimages/vault-enterprise" "${VAULT_ENTERPRISE_IMAGE}")"
  vault_kms_dst="$(resolve_image_mirror_destination "${DS_REGISTRY}/localimages/vault-kube-kms" "${VAULT_KMS_PLUGIN_IMAGE}")"

  echo "Mirroring vault images to local registry (multi-arch manifest list)..."
  echo "  ${vault_enterprise_src} -> ${vault_enterprise_dst}"
  echo "  ${vault_kms_src} -> ${vault_kms_dst}"
  echo "  verification: skopeo inspect / podman pull --platform (detected arch) after mirror"

  # shellcheck disable=SC2087
  ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -euo pipefail

MAX_RETRIES=5
REGISTRY_CONFIG="${DS_WORKING_DIR}/pull_secret.json"
REGISTRY_HOST="${DS_REGISTRY}"

registry_auth_header() {
  local registry="\$1"
  local auth

  auth="\$(jq -r --arg reg "\${registry}" '.auths[\$reg].auth // empty' "\${REGISTRY_CONFIG}" 2>/dev/null || true)"
  if [[ -n "\${auth}" ]]; then
    printf 'Authorization: Basic %s' "\${auth}"
  fi
}

vault_image_mirror_complete() {
  local image="\$1"
  local pull_args=(--authfile "\${REGISTRY_CONFIG}")
  local arch platform

  # Detect architecture: x86_64->amd64, aarch64->arm64, etc.
  arch="\$(uname -m)"
  case "\${arch}" in
    x86_64) platform="linux/amd64" ;;
    aarch64) platform="linux/arm64" ;;
    ppc64le) platform="linux/ppc64le" ;;
    s390x) platform="linux/s390x" ;;
    *) platform="linux/amd64" ;;
  esac

  if command -v skopeo >/dev/null 2>&1; then
    if skopeo inspect --authfile "\${REGISTRY_CONFIG}" --tls-verify=false "docker://\${image}" >/dev/null 2>&1; then
      return 0
    fi
    echo "Mirror verification failed: skopeo inspect \${image}"
    return 1
  fi

  # Pull for the detected platform to verify the multi-arch manifest list was mirrored correctly
  podman rmi "\${image}" >/dev/null 2>&1 || true
  if podman pull "\${pull_args[@]}" --platform="\${platform}" --tls-verify=false "\${image}" >/dev/null 2>&1; then
    echo "Mirror verification succeeded: podman pull --platform=\${platform} \${image}"
    podman rmi "\${image}" >/dev/null 2>&1 || true
    return 0
  fi

  echo "Mirror verification failed: podman pull --platform=\${platform} \${image}"
  return 1
}

copy_vault_image() {
  local src="\$1"
  local dst="\$2"

  if command -v skopeo >/dev/null 2>&1; then
    echo "Using skopeo copy --all for multi-arch mirror"
    skopeo copy --all --retry-times=3 \
      --authfile "\${REGISTRY_CONFIG}" \
      --src-authfile "\${REGISTRY_CONFIG}" \
      --dest-tls-verify=false \
      "docker://\${src}" \
      "docker://\${dst}"
    return
  fi

  echo "skopeo not found; falling back to oc image mirror --keep-manifest-list"
  oc image mirror --insecure=true --keep-manifest-list=true --registry-config "\${REGISTRY_CONFIG}" \
    "\${src}" "\${dst}"
}

registry_image_repo() {
  local image="\$1"
  local registry remainder

  registry="\${image%%/*}"
  remainder="\${image#*/}"
  if [[ "\${remainder}" == *@* ]]; then
    echo "\${remainder%%@*}"
  elif [[ "\${remainder}" == *:* ]]; then
    echo "\${remainder%%:*}"
  else
    echo "\${remainder}"
  fi
}

registry_image_reference() {
  local image="\$1"
  local remainder

  remainder="\${image#*/}"
  if [[ "\${remainder}" == *@* ]]; then
    echo "\${remainder##*@}"
  elif [[ "\${remainder}" == *:* ]]; then
    echo "\${remainder##*:}"
  else
    echo "latest"
  fi
}

find_registry_repositories_root() {
  local candidate

  for candidate in \
    "${DS_WORKING_DIR}/registry/data/docker/registry/v2/repositories" \
    "${DS_WORKING_DIR}/registry/docker/registry/v2/repositories" \
    "${DS_WORKING_DIR}/registry-${registry_port}/data/docker/registry/v2/repositories" \
    "${DS_WORKING_DIR}/registry-${registry_port}/docker/registry/v2/repositories"; do
    if [[ -d "\${candidate}" ]]; then
      echo "\${candidate}"
      return 0
    fi
  done

  return 1
}

find_registry_ca_cert() {
  local candidate

  for candidate in \
    "${DS_WORKING_DIR}/registry/certs/domain.crt" \
    "${DS_WORKING_DIR}/registry/certs/registry.2.crt" \
    "${DS_WORKING_DIR}/registry-${registry_port}/certs/domain.crt"; do
    if [[ -f "\${candidate}" ]]; then
      echo "\${candidate}"
      return 0
    fi
  done

  return 1
}

purge_local_registry_repository() {
  local image="\$1"
  local registry repo reference manifest_digest repos_root repo_path registry_ca_cert

  registry="\${image%%/*}"
  repo="\$(registry_image_repo "\${image}")"
  reference="\$(registry_image_reference "\${image}")"
  repos_root="\$(find_registry_repositories_root || true)"

  if [[ -n "\${repos_root}" ]]; then
    repo_path="\${repos_root}/\${repo}"
    if [[ -d "\${repo_path}" ]]; then
      echo "Removing incomplete mirror repository data at \${repo_path}"
      rm -rf "\${repo_path}"
    else
      echo "No local registry repository data at \${repo_path}"
    fi
  else
    echo "Warning: could not locate dev-scripts registry repositories root under ${DS_WORKING_DIR}"
  fi

  registry_ca_cert="\$(find_registry_ca_cert || true)"
  if [[ -z "\${registry_ca_cert}" ]]; then
    echo "Warning: could not locate dev-scripts registry CA; skipping manifest API purge for \${image}"
    return 0
  fi

  local curl_auth curl_header_args=()
  curl_auth="\$(registry_auth_header "\${registry}")"
  if [[ -n "\${curl_auth}" ]]; then
    curl_header_args=(-H "\${curl_auth}")
  fi

  # dev-scripts local registry serves HTTPS with a generated TLS certificate.
  manifest_digest="\$(curl -s -I \
    --cacert "\${registry_ca_cert}" \
    "\${curl_header_args[@]}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json" \
    "https://\${registry}/v2/\${repo}/manifests/\${reference}" \
    | awk -F ': ' '/Docker-Content-Digest/ {print \$2}' | tr -d '\r')"

  if [[ -n "\${manifest_digest}" ]]; then
    echo "Removing incomplete mirror manifest \${image} (\${manifest_digest})"
    curl -s -X DELETE \
      --cacert "\${registry_ca_cert}" \
      "\${curl_header_args[@]}" \
      "https://\${registry}/v2/\${repo}/manifests/\${manifest_digest}" >/dev/null || true
  fi
}

mirror_vault_image() {
  local src="\$1"
  local dst="\$2"
  local label="\$3"
  local attempt=1

  if vault_image_mirror_complete "\${dst}"; then
    echo "Skipping \${label}; destination image is already present and pullable: \${dst}"
    return 0
  fi

  purge_local_registry_repository "\${dst}"

  while [ "\${attempt}" -le "\${MAX_RETRIES}" ]; do
    echo "Mirroring \${label} attempt \${attempt}/\${MAX_RETRIES}"
    echo "  \${src} -> \${dst}"
    purge_local_registry_repository "\${dst}"
    if copy_vault_image "\${src}" "\${dst}"; then
      if vault_image_mirror_complete "\${dst}"; then
        echo "Mirrored \${label} successfully"
        return 0
      fi
      echo "Mirror command succeeded but \${dst} is not pullable"
    else
      echo "Mirroring \${label} attempt \${attempt} failed"
    fi
    attempt=\$(( attempt + 1 ))
    if [ "\${attempt}" -le "\${MAX_RETRIES}" ]; then
      sleep \$(( attempt * 10 ))
    fi
  done

  echo "Mirroring \${label} failed after \${MAX_RETRIES} attempts"
  return 1
}

mirror_vault_image "${vault_enterprise_src}" "${vault_enterprise_dst}" "vault-enterprise"
mirror_vault_image "${vault_kms_src}" "${vault_kms_dst}" "vault-kube-kms"
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

VAULT_LOCAL_STORAGE_CLASS="${VAULT_LOCAL_STORAGE_CLASS:-vault-local-storage}"

resolve_vault_storage_class() {
  if [[ -n "${VAULT_STORAGE_CLASS:-}" ]]; then
    echo "${VAULT_STORAGE_CLASS}"
    return
  fi

  local default_sc sc_count
  default_sc="$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${default_sc}" ]]; then
    echo ""
    return
  fi

  sc_count="$(oc get storageclass --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${sc_count}" == "0" ]] || [[ "${CLUSTER_TYPE:-}" == "equinix-ocp-metal" ]]; then
    echo "${VAULT_LOCAL_STORAGE_CLASS}"
    return
  fi

  echo ""
}

pick_vault_node() {
  local node
  node="$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${node}" ]]; then
    node="$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  [[ -n "${node}" ]] || {
    echo "Error: no schedulable nodes found for Vault local storage"
    exit 1
  }
  echo "${node}"
}

vault_scc_name() {
  # hostPath volumes on RHCOS bare metal need hostmount-anyuid so the Vault
  # pod (uid 100, fsGroup 1000) can write through a hostPath mount.
  if [[ "${CLUSTER_TYPE:-}" == "equinix-ocp-metal" ]]; then
    echo "hostmount-anyuid"
    return
  fi
  echo "restricted"
}

# Prepare the host directory before the PV is bound so Vault can persist its
# keyring under /vault/data (file backend). DirectoryOrCreate alone leaves
# root:root with the wrong SELinux context on bare metal nodes.
prepare_vault_host_path() {
  local node="$1"
  local host_path="$2"

  echo "Preparing hostPath ${host_path} on node ${node}..."
  oc debug -n default "node/${node}" --quiet -- chroot /host bash -c "
    set -euo pipefail
    mkdir -p '${host_path}'
    chown 100:1000 '${host_path}'
    chmod 2770 '${host_path}'
    chcon -Rt container_file_t '${host_path}' 2>/dev/null || true
  "
}

ensure_vault_local_storage_class() {
  local storage_class="$1"

  if oc get storageclass "${storage_class}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Creating manual StorageClass ${storage_class} for Vault file storage..."
  oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${storage_class}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
reclaimPolicy: Retain
EOF
}

ensure_vault_local_pv() {
  local namespace="$1"
  local release_name="$2"
  local pod_name="$3"
  local storage_class="$4"
  local pvc_name="data-${pod_name}"
  local pv_name="vault-local-${namespace}-${pod_name}"
  local host_path="/var/lib/vault-kms/${namespace}/${release_name}"
  local node

  wait_until "pvc ${pvc_name} in ${namespace}" 60 2 \
    oc get "pvc/${pvc_name}" -n "${namespace}"

  node="$(pick_vault_node)"
  prepare_vault_host_path "${node}" "${host_path}"

  if oc get pv "${pv_name}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Creating local PersistentVolume ${pv_name} on node ${node} for ${namespace}/${pvc_name}..."
  oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv_name}
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${storage_class}
  volumeMode: Filesystem
  claimRef:
    name: ${pvc_name}
    namespace: ${namespace}
  hostPath:
    path: ${host_path}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - ${node}
EOF
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

  local vault_scc
  vault_scc="$(vault_scc_name)"
  echo "Adding ${vault_scc} SCC for Vault service account..."
  oc adm policy add-scc-to-user "${vault_scc}" -z "${release_name}" -n "${namespace}"

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
  local vault_storage_class data_storage_block

  vault_storage_class="$(resolve_vault_storage_class)"
  if [[ -n "${vault_storage_class}" ]]; then
    echo "Using StorageClass ${vault_storage_class} for Vault file storage"
    ensure_vault_local_storage_class "${vault_storage_class}"
    prepare_vault_host_path "$(pick_vault_node)" "/var/lib/vault-kms/${namespace}/${release_name}"
    data_storage_block="$(cat <<EOF
  dataStorage:
    enabled: true
    size: 1Gi
    storageClass: ${vault_storage_class}
EOF
)"
  else
    echo "Using cluster default StorageClass for Vault file storage"
    data_storage_block="$(cat <<EOF
  dataStorage:
    enabled: true
    size: 1Gi
EOF
)"
  fi

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
  securityContext:
    runAsUser: 100
    runAsGroup: 1000
    fsGroup: 1000
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
${data_storage_block}
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

  if [[ -n "${vault_storage_class}" ]]; then
    ensure_vault_local_pv "${namespace}" "${release_name}" "${pod_name}" "${vault_storage_class}"
  fi

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

# Source CLUSTER_TYPE early so vault_scc_name() can detect baremetal and use hostmount-anyuid.
# On non-baremetal clusters, CLUSTER_TYPE won't be set and vault_scc_name() will use restricted.
if [[ -n "${CLUSTER_TYPE:-}" && "${CLUSTER_TYPE}" == equinix-ocp-metal ]]; then
  if [[ -f "${SHARED_DIR}/packet-conf.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/packet-conf.sh"
  fi
fi

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
