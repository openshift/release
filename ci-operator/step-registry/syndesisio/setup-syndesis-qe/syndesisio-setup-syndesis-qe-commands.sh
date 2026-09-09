#!/bin/bash

set -u
set -e
set -o pipefail

export ADMIN_USERNAME="admin"

export ADMIN_PASSWORD="admin"

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

oc adm policy add-scc-to-user anyuid -z default

htpasswd -c -B -b /tmp/users.htpasswd admin "$ADMIN_PASSWORD"
htpasswd -B -b /tmp/users.htpasswd user "user"

oc create secret generic htpass-secret --from-file=htpasswd=/tmp/users.htpasswd -n openshift-config

cat <<EOF > /tmp/htpasswd-oa.yaml
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

oc apply -f /tmp/htpasswd-oa.yaml

oc adm policy add-cluster-role-to-user cluster-admin admin --rolebinding-name=cluster-admin

count=0
status=0
while [ $count -lt 120 ]; do
    oc login --insecure-skip-tls-verify=true -u "admin" -p "admin" "$(oc whoami --show-server)" || status=$? || :
    ((count=count+1))
    if [ $status -eq 0 ]; then
        break
    fi
    echo "Waiting for resource to be available"
    sleep 5
    status=0
done

