#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script creates a basic SMCP cr with given version in given namespace.
# SMCP_VERSION and SMCP_NAMESPACE env variables are required
# oc client is expected to be logged in

smcp_name="basic-smcp"

if ! oc get namespace ${SMCP_NAMESPACE}
then
  oc new-project ${SMCP_NAMESPACE}

  # wait for servicemeshoperator to be sucesfully installed in the newly created namespace
  i=1
  until oc get csv -n ${SMCP_NAMESPACE} 2>&1 | grep servicemeshoperator | grep Succeeded
  do
    if [ $i -gt 10 ]
    then
      echo "Timeout waiting for servicemeshoperator installation"
      exit 1
    fi

    echo "Waiting for servicemeshoperator installation"
    sleep 10
    ((i=i+1))
  done

  # workaround for https://issues.redhat.com/browse/OSSM-521
  sleep 120
fi

oc apply -f - <<EOF
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: ${smcp_name}
  namespace: ${SMCP_NAMESPACE}
spec:
  version: v${SMCP_VERSION}
  security:
    dataPlane:
      mtls: true
      automtls: true
    controlPlane:
      mtls: true
  tracing:
    type: Jaeger
  addons:
    jaeger:
      install:
        storage:
          type: Memory
    grafana:
      enabled: true
    kiali:
      enabled: true
    prometheus:
      enabled: true
EOF

oc wait --for condition=Ready smcp/${smcp_name} -n ${SMCP_NAMESPACE} --timeout=180s
