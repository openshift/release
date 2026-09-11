#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Illegal number of parameters"
  exit 1
fi

CLUSTER=$1
readonly CLUSTER

echo "Checking Image Registry on ${CLUSTER}"

if ! oc config get-contexts ${CLUSTER} > /dev/null ; then
  echo "found no context ${CLUSTER} in kubeconfig"
  exit 1
fi


PUBLIC_DOCKER=$(oc --context ${CLUSTER} get is -n openshift cli -o yaml | yq -r '.status.publicDockerImageRepository')
readonly PUBLIC_DOCKER

REGISTRY_HOST="registry.${CLUSTER}.ci.openshift.org"
readonly REGISTRY_HOST

if [[ $PUBLIC_DOCKER = ${REGISTRY_HOST}* ]] ; then
  echo "Image Registry on ${CLUSTER} has been configured already. Skipping ..."
  exit
fi

CLOUD="$(oc --context ${CLUSTER}  get infrastructure.config.openshift.io cluster -o yaml | yq -r '.status.platformStatus.type')"

case $CLOUD in

  AWS)
    type="CNAME"
    external_ip=$(oc --context ${CLUSTER} get svc -n openshift-ingress router-default -o yaml | yq -r '.status.loadBalancer.ingress[0].hostname')
    echo "not implemented yet"
    exit 1
    ;;

  GCP)
    external_ip=$(oc --context ${CLUSTER} get svc -n openshift-ingress router-default -o yaml | yq -r '.status.loadBalancer.ingress[0].ip')
    if ! gcloud dns record-sets describe registry.${CLUSTER}.ci.openshift.org. --zone=origin-ci-ocp-public-dns --project openshift-ci-infra --type=A > /dev/null ; then
      echo "Configuring the registry's DNS record ..."
      gcloud dns record-sets create registry.${CLUSTER}.ci.openshift.org. --rrdatas="${external_ip}" --type=A --ttl=300 --zone=origin-ci-ocp-public-dns --project openshift-ci-infra
    else
      echo "The registry's DNS record has been configured. No DNS changed"
    fi
    ;;

  *)
    echo "Unknown Cloud $CLOUD"
    exit 1
    ;;
esac

echo "TODO: implement oc-edit configs.imageregistry.operator.openshift.io/cluster and images.config.openshift.io/cluster"
