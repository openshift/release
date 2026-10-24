#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

# install-operators only waits for the operator CSV. The VirtualMachine CRD
# is registered after this operand is created and becomes Available.
typeset hcoNamespace="${LPC_LP_CNV__HCO__NS}"
typeset hcoName="${LPC_LP_CNV__HCO__NAME}"
typeset hcoWaitTimeout="${LPC_LP_CNV__HCO__WAIT_TIMEOUT}"

{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg hcoName "${hcoName}" \
        --arg hcoNamespace "${hcoNamespace}" \
        '
        .metadata.name = $hcoName |
        .metadata.namespace = $hcoNamespace
        '
} 0<<'EOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: ""
  namespace: ""
EOF

oc wait "hyperconverged/${hcoName}" -n "${hcoNamespace}" \
    --for=condition=Available --timeout="${hcoWaitTimeout}" 1> /dev/null

true
