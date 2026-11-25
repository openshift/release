#!/bin/bash
set -xeuo pipefail
oc adm wait-for-stable-cluster --minimum-stable-period=5s
# Let's start with the MCO cert rotation
oc adm ocp-certificates regenerate-machine-config-server-serving-cert
# A few preparatory rotations
oc adm ocp-certificates regenerate-leaf -n openshift-config-managed secrets kube-controller-manager-client-cert-key kube-scheduler-client-cert-key
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver-operator secrets node-system-admin-client
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver secrets check-endpoints-client-cert-key control-plane-node-admin-client-cert-key  external-loadbalancer-serving-certkey internal-loadbalancer-serving-certkey kubelet-client localhost-recovery-serving-certkey localhost-serving-cert-certkey service-network-serving-certkey
oc adm wait-for-stable-cluster
