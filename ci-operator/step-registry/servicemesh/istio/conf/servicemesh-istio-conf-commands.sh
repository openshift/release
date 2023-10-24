#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function create_user() {
  # cluster-add-user: Add user jenkins (cluster admin)
  local HTPASSWD_DATA='$2y$05$wuKjys.Isib68LFUPYlOfuE4/URAFwy4bVZZxAdhKy2v8N4qGwgIW'
  oc apply -f <(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: htpasswd
  namespace: openshift-config
data:
  htpasswd: "${HTPASSWD_DATA}"
type: Opaque
EOF
)

  oc apply -f <(cat <<EOF
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: my_htpasswd_provider
    type: HTPasswd
    mappingMethod: claim
    htpasswd:
      fileData:
        name: htpasswd
EOF
)

  # create cluster admin user
  sleep 10
  oc adm policy add-cluster-role-to-user cluster-admin jenkins
}

create_user
echo "Created admin user jenkins"
