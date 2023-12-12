#!/bin/bash

set +u
set -o errexit
set -o pipefail

function create_configmaps()
{
  CREDENTIALS="TMP_CREDS"

  export CREDENTIALS

 cat << EOF > /tmp/credentials.yaml
$CREDENTIALS
EOF

  oc create configmap creds -n "${1}" --from-file=/tmp/credentials.yaml || true
}

function cleanup()
{
  echo "Running cleanup"
  oc delete configmap creds -n "${1}" --wait=true
}

trap 'cleanup credentials' SIGINT SIGTERM ERR EXIT

echo "Create namespace"
oc create namespace credentials || true
echo "Create configmaps"
create_configmaps credentials

echo "Simulate error"
exit 1





