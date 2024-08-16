#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script creates a basic SMCP cr with given version in given namespace.
# SMCP_VERSION and SMCP_NAMESPACE env variables are required

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

if [[ "${GATEWAY_API_ENABLED}" = "true" ]]; then
  if [[ "${SMCP_VERSION}" == "v2.4" || "${SMCP_VERSION}" == "v2.3" ]]; then
    echo 'Installing Gateway API version v0.5.1'
    oc kustomize "github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v0.5.1" | oc apply -f -
  elif [ "${SMCP_VERSION}" == "v2.5" ]; then
    echo 'Installing Gateway API version v0.6.2'
    oc kustomize "github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=v0.6.2" | oc apply -f -
  elif [ "${SMCP_VERSION}" == "v2.6" ]; then
    echo 'Installing Gateway API version v0.1.0'
    oc kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0" | oc apply -f -
  else
    echo '[WARNING] Gateway API version for this release is not known. Using the latest support one v1.0.0. Consider adding that SMCP version here and according to the Istio version, update the Gateway API version as well.'
    oc kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0" | oc apply -f -
  fi
fi

smcp_name="basic-smcp"

# set security identity type
if [ "$ROSA" == "true" ]
then
  sec_id_type="ThirdParty"
else
  sec_id_type="Kubernetes"
fi

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
    identity:
      type: ${sec_id_type}
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
  techPreview:
    gatewayAPI:
      enabled: ${GATEWAY_API_ENABLED}
EOF

oc wait --for condition=Ready smcp/${smcp_name} -n ${SMCP_NAMESPACE} --timeout=180s

oc wait --for condition=Successful kiali/kiali -n ${SMCP_NAMESPACE} --timeout=250s
oc wait --for condition=available deployment/kiali -n ${SMCP_NAMESPACE} --timeout=250s
