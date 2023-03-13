#!/bin/bash

set -exuo pipefail

hc_name="z-hc-$(echo -n $PROW_JOB_ID|cut -c-8)"
echo "$(date) Creating a new namespace clusters-$hc_name for the hosted cluster."
oc new-project "clusters-$hc_name"
release_image=${HYPERSHIFT_HC_RELEASE_IMAGE:-$OCP_IMAGE_MULTI}
echo "$(date) Extracting pull-secret for the hosted cluster."
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm

echo "$(date) Creating the hosted cluster $hc_name in the namespace clusters-$hc_name"
/usr/bin/hypershift create cluster none \
  --name=$hc_name \
  --pull-secret=/tmp/.dockerconfigjson \
  --namespace="clusters-$hc_name" \
  --base-domain=$BASE_DOMAIN \
  --release-image=$release_image

echo "$(date) Waiting for the hosted cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace="clusters-$hc_name" hostedcluster/$hc_name
echo "$(date) Hosted cluster is available, creating hosted cluster kubeconfig"
/usr/bin/hypershift create kubeconfig --namespace="clusters-$hc_name" --name=$hc_name > ${SHARED_DIR}/nested_hosted_kubeconfig