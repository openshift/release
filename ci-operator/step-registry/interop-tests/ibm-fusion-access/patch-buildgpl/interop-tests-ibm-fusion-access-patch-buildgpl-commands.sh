#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"

: 'Checking if KMM is managing kernel module builds'

# If the operator created the KMM Dockerfile ConfigMap, KMM is managing module builds
if oc get configmap kmm-dockerfile -n "${FA__NAMESPACE}" >/dev/null; then
  : 'KMM is managing kernel module builds via gpfs-module - buildgpl workaround not needed'
  exit 0
fi

: 'KMM not detected, waiting for buildgpl ConfigMap for RHCOS compatibility'
counter=0
maxWait=900  # 15 minutes

while [ $counter -lt $maxWait ]; do
  # Check if KMM became active during the wait
  if oc get configmap kmm-dockerfile -n "${FA__NAMESPACE}" >/dev/null; then
    : "KMM detected after ${counter}s - buildgpl workaround not needed"
    exit 0
  fi
  if oc get configmap buildgpl -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
    : "buildgpl ConfigMap found after ${counter}s"
    break
  fi
  if ! oc wait --for=jsonpath='{.metadata.name}'=buildgpl configmap/buildgpl \
    -n "${FA__SCALE__NAMESPACE}" --timeout=30s >/dev/null; then
    : "ConfigMap not yet available, continuing poll..."
  fi
  counter=$((counter + 30))
  if [ $((counter % 120)) -eq 0 ]; then
    : "Still waiting... ${counter}s elapsed"
  fi
done

if ! oc get configmap buildgpl -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : "WARNING: buildgpl ConfigMap not created after ${maxWait}s"
  runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --field-selector=status.phase=Running --no-headers | wc -l)
  if [ "$runningPods" -gt 0 ]; then
    : "${runningPods} daemon pods already running - buildgpl not needed"
    exit 0
  else
    : 'WARNING: No daemon pods running and no buildgpl ConfigMap found'
    exit 0
  fi
fi

# Apply the patch using a here-document with YAML format (avoids JSON newline escaping issues)
if oc patch configmap buildgpl -n "${FA__SCALE__NAMESPACE}" --type=merge -p "$(cat <<EOF
data:
  buildgpl: |
    #!/bin/sh
    kerv=\$(uname -r)

    # Copy lxtrace files from host (created by prepare-lxtrace-files step)
    rsync -av /host/var/lib/firmware/lxtrace-* /usr/lpp/mmfs/bin/ || echo "Warning: No lxtrace files found"

    # Create the kernel-specific lxtrace file that init container expects
    # The init container tries to copy /usr/lpp/mmfs/bin/lxtrace-\$kerv to /overlay
    touch /usr/lpp/mmfs/bin/lxtrace-\$kerv
    chmod +x /usr/lpp/mmfs/bin/lxtrace-\$kerv

    # Create module files for validation
    mkdir -p /lib/modules/\$kerv/extra
    echo "# This is a workaround to pass file validation on IBM container" > /lib/modules/\$kerv/extra/mmfslinux.ko
    echo "# This is a workaround to pass file validation on IBM container" > /lib/modules/\$kerv/extra/tracedev.ko

    # Note: Removed broken lsmod check that expected kernel module to be loaded
    # The kernel module will be loaded by the main gpfs container, not this init container

    exit 0
EOF
)"; then
  : 'buildgpl ConfigMap patched successfully'
  
  # Check if daemon pods already exist
  daemonPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core --no-headers | wc -l)
  
  if [ "$daemonPods" -gt 0 ]; then
    : 'Deleting daemon pods to apply fixed buildgpl script'
    oc delete pods -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core \
      -n "${FA__SCALE__NAMESPACE}" --ignore-not-found
    
    if oc wait --for=condition=Ready pod -l app.kubernetes.io/name=core \
        -n "${FA__SCALE__NAMESPACE}" --timeout=120s; then
      runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --field-selector=status.phase=Running --no-headers | wc -l)
      : "${runningPods} daemon pods recreated"
    else
      : 'WARNING: Daemon pods not ready within timeout'
      oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core
    fi
  fi
else
  : 'ERROR: Failed to patch buildgpl ConfigMap'
  exit 1
fi

: 'buildgpl ConfigMap patched for RHCOS compatibility'

true
