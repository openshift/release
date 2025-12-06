#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipsecConfig":{"mode":  "Full" }}}}}'
