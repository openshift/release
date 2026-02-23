#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

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
  runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --field-selector=status.phase=Running --no-headers | wc -l)
  if [[ "${runningPods}" -gt 0 ]]; then
    exit 0
  else
    exit 1
  fi
fi

if oc patch configmap buildgpl -n "${FA__SCALE__NAMESPACE}" --type=merge -p "$(cat <<EOF
data:
  buildgpl: |
    #!/bin/sh
    kerv=\$(uname -r)

    rsync -av /host/var/lib/firmware/lxtrace-* /usr/lpp/mmfs/bin/ || echo "Warning: No lxtrace files found"

    touch /usr/lpp/mmfs/bin/lxtrace-\$kerv
    chmod +x /usr/lpp/mmfs/bin/lxtrace-\$kerv

    mkdir -p /lib/modules/\$kerv/extra
    echo "# This is a workaround to pass file validation on IBM container" > /lib/modules/\$kerv/extra/mmfslinux.ko
    echo "# This is a workaround to pass file validation on IBM container" > /lib/modules/\$kerv/extra/tracedev.ko

    exit 0
EOF
)"; then
  daemonPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core --no-headers | wc -l)

  if [[ "${daemonPods}" -gt 0 ]]; then
    oc delete pods -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core \
      -n "${FA__SCALE__NAMESPACE}" --ignore-not-found

    oc wait --for=condition=Ready pods -l app.kubernetes.io/instance=ibm-spectrum-scale,app.kubernetes.io/name=core \
      -n "${FA__SCALE__NAMESPACE}" --timeout="${FA__SCALE__CORE_PODS_READY_TIMEOUT}"

    runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --field-selector=status.phase=Running --no-headers | wc -l)
  fi
else
  exit 1
fi

true
