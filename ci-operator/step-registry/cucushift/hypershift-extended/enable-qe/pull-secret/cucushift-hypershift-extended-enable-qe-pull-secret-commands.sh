#!/bin/bash

set -e
set -u
set -o pipefail

if [[ $SKIP_HYPERSHIFT_PULL_SECRET_UPDATE == "true" ]]; then
  echo "SKIP ....."
  exit 0
fi

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o=jsonpath='{.items[0].metadata.name}')
echo $CLUSTER_NAME

secret_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" "$CLUSTER_NAME" -ojsonpath="{.spec.pullSecret.name}")
oc get secret "$secret_name" -n "$HYPERSHIFT_NAMESPACE" -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/global-pull-secret.json

optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`
jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"}}" '.auths |= . + $a' "/tmp/global-pull-secret.json" > /tmp/global-pull-secret.json.tmp

mv /tmp/global-pull-secret.json.tmp /tmp/global-pull-secret.json
oc create secret -n "$HYPERSHIFT_NAMESPACE" generic "$CLUSTER_NAME"-pull-secret-new --from-file=.dockerconfigjson=/tmp/global-pull-secret.json
rm /tmp/global-pull-secret.json

echo "{\"spec\":{\"pullSecret\":{\"name\":\"$CLUSTER_NAME-pull-secret-new\"}}}" > /tmp/patch.json
oc patch hostedclusters -n "$HYPERSHIFT_NAMESPACE" "$CLUSTER_NAME" --type=merge -p="$(cat /tmp/patch.json)"

echo "check day-2 pull-secret update"
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
RETRIES=30
for i in $(seq ${RETRIES}); do
  UPDATED_COUNT=0
  workers=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}')
  IFS="," read -r -a workers_arr <<< "$workers"
  COUNT=${#workers_arr[*]}
  for worker in ${workers_arr[*]}
  do
  count=$(oc debug -n kube-system node/${worker} -- chroot /host/ bash -c 'cat /var/lib/kubelet/config.json' | grep -c jiazha@redhat.com || true)
  if [ $count -gt 0 ] ; then
      UPDATED_COUNT=`expr $UPDATED_COUNT + 1`
  fi
  done
  if [ "$UPDATED_COUNT" == "$COUNT" ] ; then
      echo "day 2 pull-secret successful"
      exit 0
  fi
  echo "Try ${i}/${RETRIES}: pull-secret is not updated yet. Checking again in 60 seconds"
  sleep 60
done
echo "day 2 pull-secret update error"
exit 1