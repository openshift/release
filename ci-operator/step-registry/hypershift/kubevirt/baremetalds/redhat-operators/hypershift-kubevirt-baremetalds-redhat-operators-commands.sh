#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

name="redhat-operators-$(echo $REDHAT_OPERATORS_INDEX_TAG| sed "s/[.]/-/g")"

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  annotations:
    operatorframework.io/managed-by: marketplace-operator
    target.workload.openshift.io/management: '{"effect": "PreferredDuringScheduling"}'
  generation: 5
  name: $name
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators
  grpcPodConfig:
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
  icon:
    base64data: ""
    mediatype: ""
  image: registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}
  priority: -100
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

for i in $(seq 1 120); do
    state=$(oc get catalogsources/$name -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}')
    echo $state
    if [ "$state" == "READY" ] ; then
        echo "Catalogsource created successfully after waiting $((5*i)) seconds"
        echo "current state of catalogsource is \"$state\""
        created=true
        break
    fi
    sleep 5
done
[ "$created" = "true" ]

