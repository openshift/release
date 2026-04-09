#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function gateway_api()
{
  # Configure gateway api
  echo "[INFO]Creating GatewayClass"
  oc create -f -<<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF
  set +e
  sleep 180
  echo "[INFO]Wait and ensure gatewayclass ACCEPTED=True"
  oc get gatewayclass | grep openshift-default | grep True
  retry=10
  while [[ ! $(oc get gatewayclass | grep openshift-default | grep True) && $retry -gt 0 ]]; do
    retry=$(($retry - 1))
    if [[ $retry -eq 0 ]]; then
      echo "[INFO]gatewayclass ACCEPTED is not True after 10 retries with interval 10s."
      exit 1
    fi
    echo "[INFO]Waiting for gatewayclass ACCEPTED to be True... retries remaining: $retry"
    sleep 10
  done

  echo "[INFO]Ensure OSSM is installed"
  echo "[INFO]Getting servicemeshoperator subscription is stable"
  oc -n openshift-operators get sub | grep servicemeshoperator | grep stable

  echo "[INFO]Ensure servicemeshoperator service is Succeeded"
  oc -n openshift-operators get csv | grep servicemeshoperator | grep Succeeded
  retry=10
  while [[ ! $(oc -n openshift-operators get csv | grep servicemeshoperator | grep Succeeded) && $retry -gt 0 ]]; do
    retry=$(($retry - 1))
    if [[ $retry -eq 0 ]]; then
      echo "[INFO]openshift-operators svc is not 'Succeeded' after 10 retries with interval 10s."
      exit 1
    fi
    echo "[INFO]Waiting for openshift-operators svc to 'Succeeded'... retries remaining: $retry"
  done

  echo "[INFO]Ensure servicemesh-operator pod is running"
  oc -n openshift-operators get pod | grep servicemesh-operator | grep Running
  retry=10
  while [[ ! $(oc -n openshift-operators get pod | grep servicemesh-operator | grep Running) && $retry -gt 0 ]]; do
    retry=$(($retry - 1))
    if [[ $retry -eq 0 ]]; then
      echo "[INFO]openshift-operators pod is not 'Running' after 10 retries with interval 10s."
      exit 1
    fi
    echo "[INFO]Waiting for openshift-operators pod to 'Running'... retries remaining: $retry"
    sleep 10
  done

  echo "[INFO]Ensure istio STATUS is Healthy"
  oc get istio | grep openshift-gateway | grep Healthy
  retry=10
  while [[ ! $(oc get istio | grep openshift-gateway | grep Healthy) && $retry -gt 0 ]]; do
    retry=$(($retry - 1))
    if [[ $retry -eq 0 ]]; then
      echo "[INFO]istio openshift-gateway is not 'Healthy' after 10 retries with interval 10s."
      exit 1
    fi
    echo "[INFO]Waiting for istio openshift-gateway to 'Healthy'... retries remaining: $retry"
    sleep 10
  done

  echo "[INFO]Ensure istiod deployment is ready"
  oc -n openshift-ingress get deployment | grep istiod-openshift-gateway | grep 1/1
  set -e

  echo "Gateway-api class and OSSM are configured!"
}

# if test ! -f "${KUBECONFIG}"; then
# 	echo "No kubeconfig, can not continue."
# 	exit 0
# fi
# if test -f "${SHARED_DIR}/proxy-conf.sh"; then
# 	source "${SHARED_DIR}/proxy-conf.sh"
# fi

gateway_api