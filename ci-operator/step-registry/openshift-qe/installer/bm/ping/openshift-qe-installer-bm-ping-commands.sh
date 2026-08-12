#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")

ping -c 5 prometheus-k8s-openshift-monitoring.apps.doca8.nvidia.eng.rdu2.dc.redhat.com
