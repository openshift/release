#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "require exactly 6 args"
  exit 1
fi

OUTPUT_PATH=$1
readonly OUTPUT_PATH
CLUSTER=$2
readonly CLUSTER
SERVICE_ACCOUNT=$3
readonly SERVICE_ACCOUNT
SA_NAMESPACE=$4
readonly SA_NAMESPACE
API_SERVER_URL=$5
readonly API_SERVER_URL
SECRET=$6
readonly SECRET
SKIP_TLS_VERIFY=${SKIP_TLS_VERIFY:-false}
CONTEXT=${CONTEXT:-$CLUSTER}
readonly CONTEXT

TOKEN=$(oc --context $CONTEXT -n ci extract secret/$SECRET --to=- --keys token)
while [ "$TOKEN" == '' ]; do
  echo "waiting for the token to be generated ..."
  sleep 5
  TOKEN=$(oc --context $CONTEXT -n ci extract secret/$SECRET --to=- --keys token)
done

oc --kubeconfig=$OUTPUT_PATH config set-cluster $CLUSTER --server="$API_SERVER_URL" --insecure-skip-tls-verify=$SKIP_TLS_VERIFY
oc --kubeconfig=$OUTPUT_PATH config set-credentials $SERVICE_ACCOUNT --token="$TOKEN"
oc --kubeconfig=$OUTPUT_PATH config set-context $CLUSTER --user=$SERVICE_ACCOUNT --namespace=$SA_NAMESPACE --cluster="$CLUSTER"
oc --kubeconfig=$OUTPUT_PATH config use-context $CLUSTER
