#!/usr/bin/env bash
if test ! -f "${KUBECONFIG}"
then
  echo "No kubeconfig, can't fetch cloud config."
  exit 0
fi

cp -Lrvf ${KUBECONFIG} /tmp/kubeconfig && export KUBECONFIG=/tmp/kubeconfig
oc get configmap cloud-provider-config -n openshift-config -o jsonpath='{.data.config}' > /tmp/config

# Delete the LoadBalancer section if it exists
sed -i '/^\[LoadBalancer\]/,/^\[/{/^\[/!d}' /tmp/config
sed -i '/^\[LoadBalancer\]/d' /tmp/config

cat << EOF >> /tmp/config
[LoadBalancer]
use-octavia=true
lb-provider=octavia
# The following settings are necessary for creating services with externalTrafficPolicy: Local
# NOT compatible with lb-provider=ovn
# create-monitor=true
# monitor-delay=5s
# monitor-timeout=3s
# monitor-max-retries=1
EOF

oc delete configmap cloud-provider-config -n openshift-config
oc create configmap cloud-provider-config -n openshift-config --from-file=config=/tmp/config
