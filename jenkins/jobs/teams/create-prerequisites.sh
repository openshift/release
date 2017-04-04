#!/bin/bash

oc create secret generic github-oauth-token --from-file "oauth-token=${GITHUB_OAUTH_TOKEN}" --dry-run -o yaml | oc apply -f -
oc create configmap group-sync-spec --from-file "sync-spec=${GITHUB_SYNC_SPEC}" --dry-run -o yaml | oc apply -f -

echo "kind: List
apiVersion: v1
metadata: {}
items:
- apiVersion: v1
  kind: ClusterRole
  metadata:
    name: 'group-syncer'
  rules:
  - apiGroups:
    - user.openshift.io
    attributeRestrictions: null
    resources:
    - groups
    verbs:
    - get
    - update
- apiVersion: v1
  kind: ClusterRoleBinding
  metadata:
    name: ${GROUP_SYNCER_SERVICEACCOUNT:-group-syncer}
  roleRef:
    name: 'group-syncer'
  subjects:
  - kind: ServiceAccount
    name: ${GROUP_SYNCER_SERVICEACCOUNT:-group-syncer}
    namespace: $( oc project -q )
- apiVersion: v1
  kind: Group
  metadata:
    name: jenkins-admins
  users: []
- apiVersion: v1
  kind: Group
  metadata:
    name: jenkins-editors
  users: []
- apiVersion: v1
  kind: Group
  metadata:
    name: jenkins-viewers
  users: []" | oc apply -f -