#!/bin/bash
set -euo pipefail

function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# Get OCP version from cluster
function get_ocp_version() {
  oc get clusterversion version -o jsonpath='{.status.desired.version}' | grep -o '^[0-9]*\.[0-9]*'
}

function get_latest_wmco_index_image() {
  local version ocp_tag image_url
  version=$(get_ocp_version)
  ocp_tag="release-${version//./-}"
  image_url="quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator-fbc/windows-machine-config-operator-fbc-${ocp_tag}:latest"
  echo "$image_url"
}

# Mirror Konflux WMCO catalog for disconnected operation
function setup_wmco_catalog_disconnected() {
  local wmco_index_image mirror_registry new_pull_secret registry_cred

  wmco_index_image=$(get_latest_wmco_index_image)

  if [ -z "$wmco_index_image" ]; then
    log "Failed to fetch WMCO index image. Cannot proceed with WMCO setup."
    return 1
  fi

  log "Using WMCO index image: ${wmco_index_image}"

  # Get mirror registry details
  if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    log "Error: ${SHARED_DIR}/mirror_registry_url does not exist"
    return 1
  fi

  mirror_registry=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
  log "Mirror registry: ${mirror_registry}"

  # Prepare pull secret with mirror registry auth
  new_pull_secret="$(mktemp)"
  registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
  jq --argjson a "{\"${mirror_registry}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"
  trap 'rm -f "${new_pull_secret:-}"' RETURN

  # Resolve tag to digest
  log "Resolving index image digest..."
  wmco_index_digest=$(oc image info "${wmco_index_image}" -a "${new_pull_secret}" -o json | jq -r '.digest')
  wmco_index_with_digest="${wmco_index_image%:*}@${wmco_index_digest}"
  log "Resolved index image: ${wmco_index_with_digest}"

  # Mirror with digest to bastion
  local mirrored_index_repo="${mirror_registry}/openshift4-wincw/windows-machine-config-operator-index"
  log "Mirroring FBC index with digest to: ${mirrored_index_repo}"

  retries=0
  until oc image mirror "${wmco_index_with_digest}=${mirrored_index_repo}" \
    --insecure=true \
    -a "${new_pull_secret}" \
    --skip-verification=true \
    --keep-manifest-list=true \
    --filter-by-os='.*'
  do
    if [[ $retries -eq 5 ]]; then
      log "Max retries reached mirroring index image"
      return 1
    fi
    log "Failed to mirror index image, retrying..."
    sleep 5
    ((retries+=1))
  done

  log "Successfully mirrored FBC index"

  # Mirrored image with digest
  local mirrored_index="${mirrored_index_repo}@${wmco_index_digest}"

  # Save mirrored index image reference
  echo "${mirrored_index}" > "${SHARED_DIR}/wmco_index_image"
  log "Saved mirrored index image reference to ${SHARED_DIR}/wmco_index_image"

  # Extract bundle image from catalog and mirror it
  log "Extracting catalog.json from FBC index..."
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -f "${new_pull_secret:-}"; [[ -n "${temp_dir:-}" ]] && rm -rf "${temp_dir}"' RETURN

  if ! oc image extract "${wmco_index_with_digest}" \
    --path "/configs/windows-machine-config-operator/catalog.json:${temp_dir}" \
    --confirm -a "${new_pull_secret}"; then
    log "Error: Failed to extract catalog.json"
    return 1
  fi

  log "Parsing related images from catalog.json..."
  local related_images
  related_images=$(jq -r 'select(.schema=="olm.bundle").relatedImages[].image' "${temp_dir}/catalog.json" | sort -u)

  if [ -z "${related_images}" ]; then
    log "Error: No related images found in catalog"
    return 1
  fi

  log "Found related images:"
  echo "${related_images}"

  # Validate we have expected WMCO images
  local bundle_count operator_count
  bundle_count=$(echo "${related_images}" | grep -c "operator-bundle" || true)
  operator_count=$(echo "${related_images}" | grep -E "windows-machine-config.*-operator" | grep -v -c "operator-bundle" || true)

  log "Validation: Found ${bundle_count} bundle image(s) and ${operator_count} operator image(s)"

  if [ "${bundle_count}" -eq 0 ]; then
    log "WARNING: No bundle image found in relatedImages"
  fi

  if [ "${operator_count}" -eq 0 ]; then
    log "WARNING: No operator image found in relatedImages"
  fi

  # Mirror all related images (bundle + operator)
  local ocp_version
  ocp_version=$(get_ocp_version)
  local version_tag="${ocp_version//./-}"

  declare -a idms_sources=()
  local images_mirrored=0

  while IFS= read -r img; do
    log "Mirroring related image: ${img}"

    # Parse image components
    local src_no_digest="${img%%@sha256:*}"
    local img_sha="${img##*@sha256:}"
    local repo_path_no_registry="${src_no_digest#*/}"
    local mirrored_img="${mirror_registry}/${repo_path_no_registry}"

    # Translate registry.redhat.io to quay.io Konflux path if needed
    local src_img="${img}"
    if [[ "${img}" =~ ^registry\.redhat\.io/openshift4-wincw/ ]]; then
      if [[ "${img}" == *operator-bundle* ]]; then
        src_img="quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-${version_tag}@sha256:${img_sha}"
      else
        src_img="quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-${version_tag}@sha256:${img_sha}"
      fi
      log "Translated to Konflux source: ${src_img}"
    fi

    log "Mirroring to: ${mirrored_img}"

    retries=0
    until oc image mirror "${src_img}=${mirrored_img}" \
      --insecure=true \
      -a "${new_pull_secret}" \
      --skip-verification=true \
      --keep-manifest-list=true \
      --filter-by-os='.*'
    do
      if [[ $retries -eq 3 ]]; then
        log "ERROR: Failed to mirror image after 3 retries: ${img}"
        log "This image is required for WMCO to function - cannot proceed"
        return 1
      fi
      log "Retry mirroring..."
      sleep 5
      retries=$((retries + 1))
    done

    # Only add IDMS entry for successfully mirrored images
    idms_sources+=("${src_no_digest}|${repo_path_no_registry}")
    images_mirrored=$((images_mirrored + 1))

  done <<< "${related_images}"

  log "Successfully mirrored ${images_mirrored} related images"

  if [[ "${images_mirrored}" -eq 0 ]]; then
    log "ERROR: No related images were mirrored"
    return 1
  fi

  # Mirror hello-openshift test image (used by cucushift-winc-prepare)
  log "Mirroring hello-openshift test image for winc-prepare step..."
  local hello_src="quay.io/openshifttest/hello-openshift:multiarch-winc"
  local hello_dst="${mirror_registry}/openshifttest/hello-openshift:multiarch-winc"

  retries=0
  until oc image mirror "${hello_src}=${hello_dst}" \
    --insecure=true \
    -a "${new_pull_secret}" \
    --skip-verification=true \
    --keep-manifest-list=true \
    --filter-by-os='.*'
  do
    if [[ $retries -eq 3 ]]; then
      log "Failed to mirror hello-openshift image after 3 retries"
      return 1
    fi
    log "Retry mirroring hello-openshift..."
    sleep 5
    ((retries+=1))
  done

  log "hello-openshift test image mirrored successfully"

  rm -rf "${temp_dir}"

  # Create ImageDigestMirrorSet for FBC index and related images
  local image_source="${wmco_index_image%:*}"
  log "Creating ImageDigestMirrorSet for FBC index and related images..."
  cat <<EOF > "${ARTIFACT_DIR}/wmco-konflux-disconnected-idms.yaml"
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: wmco-digested-mirror
spec:
  imageDigestMirrors:
  - source: ${image_source}
    mirrors:
    - ${mirrored_index_repo}
EOF

  # Add IDMS entries for each unique source repo from related images
  for entry in "${idms_sources[@]}"; do
    local src="${entry%%|*}"
    local repo="${entry##*|}"
    cat <<EOF >> "${ARTIFACT_DIR}/wmco-konflux-disconnected-idms.yaml"
  - source: ${src}
    mirrors:
    - ${mirror_registry}/${repo}
EOF
  done

  run_command "cat ${ARTIFACT_DIR}/wmco-konflux-disconnected-idms.yaml"
  run_command "oc apply -f ${ARTIFACT_DIR}/wmco-konflux-disconnected-idms.yaml"

  # Create ImageTagMirrorSet for hello-openshift test image
  log "Creating ImageTagMirrorSet for hello-openshift test image..."
  cat <<EOF > "${ARTIFACT_DIR}/hello-openshift-itms.yaml"
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: hello-openshift-tagmirrorset
spec:
  imageTagMirrors:
  - mirrors:
    - ${mirror_registry}/openshifttest/hello-openshift
    source: quay.io/openshifttest/hello-openshift
EOF

  run_command "cat ${ARTIFACT_DIR}/hello-openshift-itms.yaml"
  run_command "oc apply -f ${ARTIFACT_DIR}/hello-openshift-itms.yaml"

  # Create CatalogSource with digest reference
  log "Creating CatalogSource for bastion-mirrored Konflux FBC..."
  cat <<EOF > "${ARTIFACT_DIR}/wmco-catalogsource-disconnected.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: wmco
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
    nodeSelector:
      kubernetes.io/os: linux
      node-role.kubernetes.io/master: ""
    priorityClassName: system-cluster-critical
    securityContextConfig: restricted
    tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
    - effect: NoExecute
      key: node.kubernetes.io/unreachable
      operator: Exists
      tolerationSeconds: 120
    - effect: NoExecute
      key: node.kubernetes.io/not-ready
      operator: Exists
      tolerationSeconds: 120
  image: ${mirrored_index}
  displayName: "Windows Machine Config Operator (Disconnected)"
  publisher: "Red Hat"
EOF

  run_command "cat ${ARTIFACT_DIR}/wmco-catalogsource-disconnected.yaml"
  run_command "oc apply -f ${ARTIFACT_DIR}/wmco-catalogsource-disconnected.yaml"

  # Disable default OperatorHub sources in disconnected environment
  log "Disabling default OperatorHub sources for disconnected environment..."
  oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
  log "Default OperatorHub sources disabled"

  # Configure cluster to trust mirror registry CA certificate
  log "Configuring cluster to trust mirror registry CA certificate..."
  local client_ca_cert mirror_registry_host
  client_ca_cert=/var/run/vault/mirror-registry/client_ca.crt
  mirror_registry_host=$(echo "${mirror_registry}" | cut -d : -f 1)

  # Check if registry-config ConfigMap already exists and patch or create
  if oc get configmap registry-config -n openshift-config &>/dev/null; then
    log "registry-config ConfigMap exists, patching with mirror registry CA..."
    oc create configmap registry-config --from-file="${mirror_registry_host}..5000"=${client_ca_cert} -n openshift-config --dry-run=client -o yaml | oc apply -f -
  else
    log "Creating registry-config ConfigMap with mirror registry CA..."
    oc create configmap registry-config --from-file="${mirror_registry_host}..5000"=${client_ca_cert} -n openshift-config
  fi

  # Patch Image config to use the CA ConfigMap
  log "Patching Image config with additionalTrustedCA..."
  oc patch image.config.openshift.io/cluster --patch '{"spec":{"additionalTrustedCA":{"name":"registry-config"}}}' --type=merge
  log "Mirror registry CA certificate configured - cluster will trust bastion registry"

  # Pre-create WMCO namespace with required labels so default install-wmco step skips it
  log "Pre-creating WMCO namespace with required labels for default install step..."
  mkdir -p "${SHARED_DIR}/manifests/windows"
  cat <<EOF > "${SHARED_DIR}/manifests/windows/namespace.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-windows-machine-config-operator
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "true"
    pod-security.kubernetes.io/enforce: "privileged"
    openshift.io/cluster-monitoring: "true"
EOF
  log "WMCO namespace manifest created at ${SHARED_DIR}/manifests/windows/namespace.yaml"

  # Wait for CatalogSource to be ready
  log "Waiting for CatalogSource to become ready..."
  local timeout=300
  local interval=10
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    if oc get catalogsource wmco -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null | grep -q "READY"; then
      log "CatalogSource is READY"

      # Debug: Check CatalogSource details
      log "DEBUG: CatalogSource full details:"
      run_command "oc get catalogsource wmco -n openshift-marketplace -o yaml | tail -50"

      # Debug: Check catalog pod status
      log "DEBUG: Catalog pods in openshift-marketplace:"
      run_command "oc get pods -n openshift-marketplace | grep wmco || true"
      run_command "oc get pods -n openshift-marketplace -l olm.catalogSource=wmco -o wide || true"

      # Debug: Check if packagemanifest is created
      log "DEBUG: PackageManifest availability:"
      run_command "oc get packagemanifest -n openshift-marketplace | grep windows || echo 'No windows-machine-config-operator packagemanifest found'"
      run_command "oc get packagemanifest windows-machine-config-operator -n openshift-marketplace -o yaml 2>&1 | tail -50 || echo 'PackageManifest windows-machine-config-operator not found'"

      # Debug: Check events
      log "DEBUG: Recent events in openshift-marketplace:"
      run_command "oc get events -n openshift-marketplace --sort-by='.lastTimestamp' | tail -20"

      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
    log "Still waiting for CatalogSource... (${elapsed}/${timeout}s)"
  done

  log "Error: Timed out waiting for CatalogSource to become ready"
  run_command "oc get catalogsource wmco -n openshift-marketplace -o yaml | tail -50"
  return 1
}

# Main execution
run_command "oc whoami"
run_command "oc version -o yaml"

log "Setting up Konflux WMCO catalog for disconnected environment..."
setup_wmco_catalog_disconnected
