#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
EOF

echo "Waiting for NooBaa storage..." >&2
oc -n openshift-storage wait noobaa.noobaa.io/noobaa --for=condition=Available --timeout=120s

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay
EOF

cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay
spec:
  components:
  - kind: clair
    managed: true
EOF

echo "Waiting for Quay to become ready (timeout: 15m)..." >&2
for i in $(seq 1 90); do
    status="$(oc -n quay get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
        echo "Quay is ready (after $((i * 10))s)" >&2
        exit 0
    fi
    if (( i % 6 == 0 )); then
        echo "[$((i * 10))s] Quay not ready yet. Component status:" >&2
        oc -n quay get quayregistry quay -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null >&2 || true
    fi
    sleep 10
done

echo "Timed out waiting for Quay to become ready" >&2
echo "Final QuayRegistry conditions:" >&2
oc -n quay get quayregistry quay -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null >&2 || true
echo "Pods in quay namespace:" >&2
oc -n quay get pods -o wide >&2 || true
echo "Events in quay namespace:" >&2
oc -n quay get events --sort-by='.lastTimestamp' >&2 || true

oc -n quay get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
oc -n quay get pods -o yaml >"$ARTIFACT_DIR/quay-pods.yaml" || true
oc -n quay get events --sort-by='.lastTimestamp' -o yaml >"$ARTIFACT_DIR/quay-events.yaml" || true
oc -n quay get deployments -o yaml >"$ARTIFACT_DIR/quay-deployments.yaml" || true
exit 1
