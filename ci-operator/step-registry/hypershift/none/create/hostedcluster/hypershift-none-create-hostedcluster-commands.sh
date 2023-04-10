#!/bin/bash

set -exuo pipefail

hc_name="hc-$(echo -n $PROW_JOB_ID|cut -c-8)"
echo "$(date +%H:%M:%S) Creating a new namespace hcp-s390x for the hosted cluster."
oc new-project "hcp-s390x" --kubeconfig="$KUBECONFIG"
release_image=${HYPERSHIFT_HC_RELEASE_IMAGE:-$OCP_IMAGE_MULTI}
echo "Extracting pull-secret for the hosted cluster."
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm --kubeconfig="$KUBECONFIG"

echo "Checking for the hypershift binary..."
which hypershift
if [ $? -eq 0 ]; then
  echo "Hypershift binary is already present"
else
  echo "Hypershift binary is not present, Installing it now..."
  git clone https://github.com/openshift/hypershift.git
  cd hypershift && make OUT_DIR=/usr/bin hypershift
  echo "Successfully installed hypershift binary" && cd ..
fi

echo "Installing hypershift operator in the management cluster"
hypershift install

echo "$(date +%H:%M:%S) Creating the hosted cluster $hc_name in the namespace hcp-s390x"
hypershift create cluster none \
  --name=$hc_name \
  --pull-secret=/tmp/.dockerconfigjson \
  --namespace="hcp-s390x" \
  --base-domain=$BASE_DOMAIN \
  --release-image=$release_image \
  --expose-through-load-balancer

echo "$(date +%H:%M:%S) Waiting for the hosted cluster to become available...."
oc wait --timeout=30m --for=condition=Available --namespace="hcp-s390x" hostedcluster/$hc_name --kubeconfig="$KUBECONFIG"
echo "$(date) Hosted cluster $hc_name is created successfully and is available to deploy."