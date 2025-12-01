#!/bin/bash

set -euo pipefail

# ====== Logging helpers ======
log()   { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }


check_volumeattributeclass() {
    local response=$(oc get --raw /apis/storage.k8s.io/v1beta1 2>/dev/null)
    if [[ -n "$response" ]]; then
        log "/apis/storage.k8s.io/v1beta1 is served as expected"
    else
        error "/apis/storage.k8s.io/v1beta1 is not served"
        return 1
    fi

    if oc get volumeattributesclass &>/dev/null; then
        log "VolumeAttributesClass resource exist as expected"
    else
        error "VolumeAttributesClass resource does NOT exist"
        return 1
    fi

}

# Initial setup
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
log "Checking hosted cluster feature gate is enabled..."
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
if [[ -n "$CHECK_FEATURE_GATES" ]]; then
    read -ra gates_array <<< "$CHECK_FEATURE_GATES"
    enabled_features=$(oc get featuregate cluster -o jsonpath='{range .status.featureGates[*].enabled[*]}{.name}{" "}{end}')

    for gate in "${gates_array[@]}"; do
      log "Checking $gate..."
      if [[ " $enabled_features " == *" $gate "* ]]; then
            log "Found $gate in the enabled featureGates list"
      else
            error "$gate is NOT found from the the enabled featureGates list"
            exit 1
      fi
      # in case we need to check more thing for specific feature
      if [[ "${gate}" == "VolumeAttributeClass" ]]; then
        check_volumeattributeclass|| exit 1
        log "More check for VolumeAttributesClass feature gate finished."
      fi
    done
    log "✅All feature gates check finished."
else
  log "There is no value defined in $CHECK_FEATURE_GATES and skip this check."
fi

