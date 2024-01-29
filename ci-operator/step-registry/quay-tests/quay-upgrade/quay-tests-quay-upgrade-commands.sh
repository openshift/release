#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Quay upgrade test..."
skopeo -v
oc version
terraform version
go version
podman -v

#Get the credentials and Email of new Quay User
#QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
#QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

echo "$QUAY_EMAIL \" $QUAY_EMAIL \" exists fffound"

#Retrieve the Credentials of image registry "brew.registry.redhat.io"
OMR_BREW_USERNAME=$(cat /var/run/quay-qe-brew-secret/username)
OMR_BREW_PASSWORD=$(cat /var/run/quay-qe-brew-secret/password)
podman login brew.registry.redhat.io -u "${OMR_BREW_USERNAME}" -p "${OMR_BREW_PASSWORD}"

#Deploy ODF Operator to OCP namespace 'openshift-storage'

echo "ODF/OCS Operator is deployed successfully"

cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  dbType: postgres
EOF

echo "Waiting for NooBaa Storage to be ready..." >&2
oc -n openshift-storage wait noobaa.noobaa.io/noobaa --for=condition=Available --timeout=180s

cd quay-operator-tests
ls -al
make build
echo "files in quay-operator-tests:"
ls -al
./bin/extended-platform-tests run all --dry-run | grep "Quay" | ./bin/extended-platform-tests run -f -
sleep 10
