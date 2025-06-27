#!/bin/bash
set -euo pipefail

function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Get OCP version from cluster
function get_ocp_version() {
  oc get clusterversion version -o jsonpath='{.status.desired.version}' | grep -o '^[0-9]*\.[0-9]*'
}

function get_latest_wmco_index_image() {
  local version ocp_tag image_url
  version=$(get_ocp_version)
  ocp_tag="release-${version//./-}" # e.g., release-4-18

  # Construct the URL using the :latest tag
  image_url="quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator-fbc/windows-machine-config-operator-fbc-${ocp_tag}:latest"

  echo "$image_url"
}

# Create Konflux ImageDigestMirrorSet
function setup_wmco_catalog() {
  local wmco_index_image
  wmco_index_image=$(get_latest_wmco_index_image)
  
  if [ -z "$wmco_index_image" ]; then
    log "Failed to fetch WMCO index image. Cannot proceed with WMCO setup."
    return 1
  fi
  
  log "Using WMCO index image: ${wmco_index_image}"
  
  # Save the image reference for later use
  echo "${wmco_index_image}" > "${SHARED_DIR}/wmco_index_image"
  local ocp_version
  ocp_version=$(get_ocp_version | sed 's/\./-/g')

  # Create ImageDigestMirrorSet
  log "Creating ImageDigestMirrorSet for OCP ${ocp_version}..."
  cat <<EOF > "${ARTIFACT_DIR}/konflux_idms.yaml"
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: stage-repo
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/openshift4-wincw/windows-machine-config-rhel9-operator
    mirrors:
    - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-${ocp_version}
  - source: registry.stage.redhat.io/openshift4-wincw/windows-machine-config-rhel9-operator
    mirrors:
    - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-release-${ocp_version}
  - source: registry.redhat.io/openshift4-wincw/windows-machine-config-operator-bundle
    mirrors:
    - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-${ocp_version}
  - source: registry.stage.redhat.io/openshift4-wincw/windows-machine-config-operator-bundle
    mirrors:
    - quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator-bundle-release-${ocp_version}
EOF

  oc apply -f "${ARTIFACT_DIR}/konflux_idms.yaml"

  # Create CatalogSource using the fetched WMCO index image
  log "Creating CatalogSource using image: ${wmco_index_image}"
  cat <<EOF > "${ARTIFACT_DIR}/wmco_catalogsource.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: wmco
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${wmco_index_image}
  displayName: "Windows Machine Config Operator"
  publisher: "Red Hat"
EOF

  oc apply -f "${ARTIFACT_DIR}/wmco_catalogsource.yaml"

  # Wait for CatalogSource to be ready
  log "Waiting for CatalogSource to become ready..."
  local timeout
  local interval
  local elapsed
  timeout=300
  interval=10
  elapsed=0
  
  while [ $elapsed -lt $timeout ]; do
    if oc get catalogsource wmco -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' | grep -q "READY"; then
      log "CatalogSource is READY"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
    log "Still waiting for CatalogSource... (${elapsed}/${timeout}s)"
  done
  
  log "Error: Timed out waiting for CatalogSource to become ready"
  oc get catalogsource wmco -n openshift-marketplace -o yaml
  return 1
}

# Main execution
log "Setting up dynamic WMCO catalog for Konflux..."
setup_wmco_catalog

