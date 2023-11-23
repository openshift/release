#!/bin/bash

set +u
set -o errexit
set -o pipefail


CONSOLE_URL=$(cat "$SHARED_DIR"/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
KUBEADMIN_PWD=$(cat "$SHARED_DIR"/kubeadmin-password)
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

export API_URL
export KUBEADMIN_PWD
export OCM_TOKEN

cat << EOF > /tmp/test.properties
xtf.openshift.url=$API_URL
xtf.openshift.admin.username=kubeadmin
xtf.openshift.admin.password=$KUBEADMIN_PWD
xtf.openshift.admin.token=$OCM_TOKEN
xtf.openshift.master.username=xpaasqe
xtf.openshift.master.password=xpaasqe
xtf.openshift.master.token=_7bdpj6B1hZGfJNmeERSkazpgYP1iVSYXorDPylYWDE
xtf.config.master.jump.ssh_hostname=api.pit-39mb.dynamic.xpaas
xtf.config.master.jump.ssh_username=core
xtf.config.master.ssh_key_path=/home/hudson/.ssh/id_rsa
xtf.config.master.ssh_username=core

xtf.openshift.namespace=pit
xtf.bm.namespace=pit-builds
EOF

# oc delete configmap test-properties -n "${1}" || true
# oc create configmap test-properties -n "${1}" --from-file=/tmp/test.properties