#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")

ping -c 5 $bastion

curl https://prometheus-k8s-openshift-monitoring.apps.vlan604.rdu2.scalelab.redhat.com -k