#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "require exactly 6 args"
  exit 1
fi

oc_cmd="${oc_cmd:-oc}"
sed_cmd="${sed_cmd:-sed}"

OUTPUT_PATH=$1
readonly OUTPUT_PATH
CLUSTER=$2
readonly CLUSTER
SERVICE_ACCOUNT=$3
readonly SERVICE_ACCOUNT
SA_NAMESPACE=$4
readonly=SA_NAMESPACE
API_SERVER_URL=$5
readonly API_SERVER_URL
SECRET=$6
readonly SECRET

while :
do
  TOKEN=$(oc --context $CLUSTER -n ci extract secret/$SECRET --to=- --keys token)
  if [ ${TOKEN} == "" ];
  then
    echo "waiting for the token to be generated ..."
    sleep 5
  else
    break
  fi
done


template="apiVersion: v1
clusters:
- cluster:
    server: {{API_SERVER_URL}}
  name: {{CLUSTER}}
contexts:
- context:
    cluster: {{CLUSTER}}
    namespace: {{SA_NAMESPACE}}
    user: {{SERVICE_ACCOUNT}}
  name: {{CLUSTER}}
current-context: {{CLUSTER}}
kind: Config
preferences: {}
users:
- name: {{SERVICE_ACCOUNT}}
  user:
    token: {{TOKEN}}
"

echo -n "$template" | ${sed_cmd} "s/{{CLUSTER}}/${CLUSTER}/g;s/{{SERVICE_ACCOUNT}}/${SERVICE_ACCOUNT}/g;s/{{SA_NAMESPACE}}/${SA_NAMESPACE}/g;s/{{API_SERVER_URL}}/${API_SERVER_URL//\//\\/}/g;s/{{TOKEN}}/${TOKEN}/g" > $OUTPUT_PATH



