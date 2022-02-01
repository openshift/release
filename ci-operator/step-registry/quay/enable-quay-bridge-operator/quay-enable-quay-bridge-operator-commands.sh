#!/bin/bash
set -x

set -o nounset
set -o errexit
set -o pipefail

oc create secret -n openshift-operators generic quay-integration --from-file=token="$SHARED_DIR/quay-access-token"

registryEndpoint="$(oc -n quay get quayregistry quay -o jsonpath='{.status.registryEndpoint}')"
registry="${registryEndpoint#https://}"

echo "Creating QuayIntegration..."
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayIntegration
metadata:
  name: quay
spec:
  clusterID: openshift
  credentialsSecret:
    namespace: openshift-operators
    name: quay-integration
  quayHostname: $registryEndpoint
EOF

echo "Marking Quay endpoint as insecure..."
oc patch images.config.openshift.io/cluster --type=merge -p '{"spec":{"registrySources":{"insecureRegistries":["'"$registry"'"]}}}'
echo "Waiting until Machine Config Pools are updated..."
sleep 10
time oc wait mcp --for=condition=Updated --all --timeout=20m
echo "Waiting until Quay become ready..."
for _ in {1..30}; do
  ready=$(oc -n quay get pods -l quay-component=quay-app -o go-template='{{$x := ""}}{{range .items}}{{range .status.conditions}}{{if eq .type "Ready"}}{{if or (eq $x "") (eq .status "False")}}{{$x = .status}}{{end}}{{end}}{{end}}{{end}}{{or $x "False"}}')
  if [ "$ready" = "True" ]; then
    echo "Quay is ready"
    sleep 600 # Wait until all nodes are updated and all operator are stable.
    exit 0
  fi
  sleep 10
done
oc -n quay get pods -l quay-component=quay-app -o yaml
oc -n quay logs "$(oc -n quay get pods -l quay-component=quay-app -o name)" || true
echo "Quay is not ready"
exit 1
