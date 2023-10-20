#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function create_user() {
  # create htpasswd file
  htpasswd -c -B -b users.htpasswd "${USER_NAME}" "${USER_PASS}"

  # create htpasswd secret
  oc -n openshift-config create secret generic htpass-secret --from-file=htpasswd=users.htpasswd

  # update oauth
  oc apply -f <(cat <<EOF
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: my_htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
EOF
)

  # create cluster admin user
  oc adm policy add-cluster-role-to-user cluster-admin jenkins
}

create_user
echo "Created admin user ${USER_NAME}"
