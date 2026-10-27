#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

# install-operators only waits for the operator CSV. The VirtualMachine CRD
# is registered after this operand is created and becomes Available.
{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg hcoName "${LPC_LP_CNV__HCO__NAME}" \
        --arg hcoNamespace "${LPC_LP_CNV__HCO__NS}" \
        '
            .metadata|=(
                .name=$hcoName |
                .namespace=$hcoNamespace
            )
        '
} 0<<'EOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: ""
  namespace: ""
EOF

oc wait "hyperconverged/${LPC_LP_CNV__HCO__NAME}" -n "${LPC_LP_CNV__HCO__NS}" \
    --for=condition=Available --timeout="${LPC_LP_CNV__HCO__WAIT_TIMEOUT}" 1> /dev/null

true
