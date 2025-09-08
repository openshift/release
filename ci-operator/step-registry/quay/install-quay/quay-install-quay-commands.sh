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

for _ in {1..60}; do
    if [[ "$(oc -n quay get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
        echo "Quay is ready" >&2
        exit 0
    fi
    sleep 10
done
echo "Timed out waiting for Quay to become ready" >&2
oc -n quay get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
exit 1
