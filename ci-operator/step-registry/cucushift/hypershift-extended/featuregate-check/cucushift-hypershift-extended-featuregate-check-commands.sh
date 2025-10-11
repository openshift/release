#!/bin/bash

set -euo pipefail

# ====== Logging helpers ======
log()   { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }


check_storage_volumeattributeclasses() {
    # Assign enabled feature gates to a variable
    local enabled_features=$(oc get featuregate cluster -o jsonpath='{range .status.featureGates[*].enabled[*]}{.name}{" "}{end}')

    if [[ " $enabled_features " == *" VolumeAttributesClass "* ]]; then
       log "Found VolumeAttributesClass in the enabled featureGates list"
    else
       error "VolumeAttributesClass is NOT found from the the enabled featureGates list"
       return 1
    fi
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
    fi

}

# Initial setup
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
log "Checking hosted cluster storage VolumeAttributesClass feature gate is enabled..."
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
check_storage_volumeattributeclasses|| exit 1

log "✅storage VolumeAttributesClass check finished."
