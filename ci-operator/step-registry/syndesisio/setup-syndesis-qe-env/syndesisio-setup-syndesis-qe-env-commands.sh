#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc project default || true
oc registry login || true
oc create --as system:admin user kubeadmin || true
oc create --as system:admin identity kube:admin || true
oc create --as system:admin useridentitymapping kube:admin kubeadmin || true
oc adm policy --as system:admin add-cluster-role-to-user cluster-admin kubeadmin || true
