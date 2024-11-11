#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion "cat ~/mno/kubeconfig" > /tmp/kubeconfig
  # Setup socks proxy
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion -fNT -D 12345
  export KUBECONFIG=/tmp/kubeconfig
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig=/tmp/kubeconfig config set-cluster bm --proxy-url=socks5://localhost:12345
fi

oc config view
oc projects

# Install the CNV operator
cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cnv-nightly-catalog-source
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/openshift-cnv/nightly-catalog:${CNV_VERSION}
  displayName: OpenShift Virtualization Nightly Index
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 8h
EOF

sleep 30

STARTING_CSV=$(oc get packagemanifest -l catalog=cnv-nightly-catalog-source -n openshift-marketplace -o jsonpath="{$.items[?(@.metadata.name=='kubevirt-hyperconverged')].status.channels[?(@.name==\"nightly-${CNV_VERSION}\")].currentCSV}")

cat << EOF| oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
    name: openshift-cnv
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
    name: kubevirt-hyperconverged-group
    namespace: openshift-cnv
spec:
    targetNamespaces:
    - openshift-cnv
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
    name: hco-operatorhub
    namespace: openshift-cnv
spec:
    source: cnv-nightly-catalog-source
    sourceNamespace: openshift-marketplace
    name: kubevirt-hyperconverged
    startingCSV: ${STARTING_CSV}
    channel: "nightly-${CNV_VERSION}"
EOF

until oc get csv -n openshift-cnv $STARTING_CSV ; do  sleep 5; done
oc wait --timeout=300s -n openshift-cnv csv $STARTING_CSV --for=jsonpath='{.status.phase}'=Succeeded

cat << EOF| oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
Spec: {}
EOF

sleep 20

oc wait --timeout=300s -n openshift-cnv csv $STARTING_CSV --for=jsonpath='{.status.phase}'=Succeeded
oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
