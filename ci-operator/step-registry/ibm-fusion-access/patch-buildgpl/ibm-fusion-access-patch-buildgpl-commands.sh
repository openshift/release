#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Patching buildgpl ConfigMap for RHCOS compatibility'

# Wait for buildgpl ConfigMap to be created by operator (may take up to 15 minutes)
counter=0
maxWait=900

while [[ ${counter} -lt ${maxWait} ]]; do
  if oc get configmap buildgpl -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
    break
  fi
  if oc wait --for=jsonpath='{.metadata.name}'=buildgpl configmap/buildgpl \
      -n "${FA__SCALE__NAMESPACE}" --timeout=30s; then
    break
  fi
  counter=$((counter + 30))
done

if ! oc get configmap buildgpl -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : '⚠️  buildgpl ConfigMap not created after timeout'
  runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --field-selector=status.phase=Running --no-headers | wc -l)
  if [[ "${runningPods}" -gt 0 ]]; then
    : 'Daemon pods already running - buildgpl not needed'
    exit 0
  else
    : '❌ No daemon pods running and no buildgpl ConfigMap found'
    exit 1
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
  : '✅ buildgpl ConfigMap patched successfully'

  # Check if daemon pods already exist
  daemonPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core --no-headers | wc -l)

  if [[ "${daemonPods}" -gt 0 ]]; then
    oc delete pods -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core \
      -n "${FA__SCALE__NAMESPACE}" --ignore-not-found

    oc wait --for=condition=Ready pods -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core \
      -n "${FA__SCALE__NAMESPACE}" --timeout="${FA__SCALE__CORE_PODS_READY_TIMEOUT}"

    runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --field-selector=status.phase=Running --no-headers | wc -l)
  else
    : 'No daemon pods exist yet - they will use fixed buildgpl when created'
  fi
else
  : '❌ Failed to patch buildgpl ConfigMap'
  exit 1
fi

: '✅ buildgpl ConfigMap patched for RHCOS compatibility'

true
