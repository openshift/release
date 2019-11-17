#!/bin/bash

set -o nounset
set -o errext
set -o pipefail

# We want the cluster to be able to access these images
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
oc adm policy add-role-to-group system:image-puller system:authenticated   --namespace "${NAMESPACE}"

# Give admin access to a known bot
oc adm policy add-role-to-user admin system:serviceaccount:ci:ci-chat-bot --namespace "${NAMESPACE}"

# Role for giving the e2e pod permissions to update imagestreams
cat <<EOF
kind: Role
apiVersion: authorization.openshift.io/v1
metadata:
  name: ${JOB_NAME_SAFE}-imagestream-updater
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["image.openshift.io"]
  resources: ["imagestreams/layers"]
  verbs: ["get", "update"]
- apiGroups: ["image.openshift.io"]
  resources: ["imagestreams", "imagestreamtags"]
  verbs: ["get", "create", "update", "delete", "list"]
EOF | oc apply -f -

# Give the e2e pod access to the imagestream-updater role
oc adm policy add-role-to-user ${JOB_NAME_SAFE}-imagestream-updater --serviceaccount default --namespace "${NAMESPACE}"