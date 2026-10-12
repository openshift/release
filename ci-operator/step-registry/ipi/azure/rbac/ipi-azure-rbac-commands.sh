#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Try only 10 times
for i in `seq 10`; do
    echo "Attempt $i"
    oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: persistent-volume-binder-role
rules:
- apiGroups: ['']
  resources: ['secrets']
  verbs:     ['list', 'get','create']
EOF
    if [ "$?" -eq 0 ]; then
        oc adm policy add-cluster-role-to-user persistent-volume-binder-role "system:serviceaccount:kube-system:persistent-volume-binder" && break
    fi
    sleep 5
done
