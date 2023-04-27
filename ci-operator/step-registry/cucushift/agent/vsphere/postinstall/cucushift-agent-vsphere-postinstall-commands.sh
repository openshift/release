#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere agent post-install ************"
# Check for SNO cluster
if [ "${MASTERS}" -eq 1 ]; then
  echo "$(date -u --rfc-3339=seconds) - no need to add vsphere credentials as the cluster is SNO"
  exit 0
fi
source "${SHARED_DIR}"/platform-conf.sh

oc get nodes

# Backup
oc get secret vsphere-creds -o yaml -n kube-system > "${SHARED_DIR}"/creds_backup.yaml
oc get cm cloud-provider-config -o yaml -n openshift-config > "${SHARED_DIR}"/cloud-provider-config_backup.yaml

cat <<EOF | oc replace -f -
apiVersion: v1
kind: Secret
metadata:
  annotations:
    cloudcredential.openshift.io/mode: passthrough
  name: vsphere-creds
  namespace: kube-system
type: Opaque
stringData:
  "${VSPHERE_VCENTER}.username": "${VSPHERE_USERNAME}"
  "${VSPHERE_VCENTER}.password": "${VSPHERE_PASSWORD}"
EOF

oc patch kubecontrollermanager cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'"$( date --rfc-3339=ns )"'"}}' --type=merge

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloud-provider-config
  namespace: openshift-config
data:
  config: |
    [Global]
    secret-name = "vsphere-creds"
    secret-namespace = "kube-system"
    insecure-flag = "1"
    [Workspace]
    server = "${VSPHERE_VCENTER}"
    datacenter = "${VSPHERE_DATACENTER}"
    default-datastore = "${VSPHERE_DATASTORE}"
    folder = "${VSPHERE_DATACENTER}"/vm
    [VirtualCenter "${VSPHERE_VCENTER}"]
    datacenters = "${VSPHERE_DATACENTER}"
EOF

oc patch clusterversion version --type json -p '[{"op": "remove", "path": "/spec/channel"}]}]'

until \
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done
