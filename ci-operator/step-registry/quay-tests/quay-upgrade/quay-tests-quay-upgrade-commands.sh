#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Quay upgrade test..."
skopeo -v
oc version
# terraform version
go version
podman -v
echo "*******"
#Get the credentials and Email of new Quay User
#QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
#QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

echo "$QUAY_EMAIL \" $QUAY_EMAIL \" exists found"

#Retrieve the Credentials of image registry "brew.registry.redhat.io"
# OMR_BREW_USERNAME=$(cat /var/run/quay-qe-brew-secret/username)
# OMR_BREW_PASSWORD=$(cat /var/run/quay-qe-brew-secret/password)
# podman login brew.registry.redhat.io -u "${OMR_BREW_USERNAME}" -p "${OMR_BREW_PASSWORD}"

#Deploy ODF Operator to OCP namespace 'openshift-storage'
OO_INSTALL_NAMESPACE=openshift-storage
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
ODF_OPERATOR_CHANNEL="$ODF_OPERATOR_CHANNEL"
ODF_SUBSCRIPTION_NAME="$ODF_SUBSCRIPTION_NAME"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ -n "$OPERATORGROUP" ]]; then
  echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
  OG_OPERATION=apply
  OG_NAMESTANZA="name: $OPERATORGROUP"
else
  echo "OperatorGroup does not exist: creating it"
  OG_OPERATION=create
  OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
  oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_INSTALL_NAMESPACE]
EOF
)

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $ODF_SUBSCRIPTION_NAME
  namespace: $OO_INSTALL_NAMESPACE
spec:
  channel: $ODF_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $ODF_SUBSCRIPTION_NAME
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
  CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  sleep 10
done
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

cd new-quay-operator-tests
ls -al
make build
echo "files in new-quay-operator-tests:"
ls -al
./bin/extended-platform-tests run all --dry-run | grep "20934"|./bin/extended-platform-tests run --timeout 150m --junit-dir=./ -f - 
sleep 10
