#!/usr/bin/env bash
if test ! -f "${KUBECONFIG}"
then
  echo "No kubeconfig, can't fetch cloud config."
  exit 0
fi

cp -Lrvf ${KUBECONFIG} /tmp/kubeconfig && export KUBECONFIG=/tmp/kubeconfig
oc get configmap cloud-provider-config -n openshift-config -o jsonpath='{.data.config}' > /tmp/config
echo "[LoadBalancer]" >> /tmp/config
echo "use-octavia=true" >> /tmp/config

oc delete configmap cloud-provider-config -n openshift-config
oc create configmap cloud-provider-config -n openshift-config --from-file=config=/tmp/config
