#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset
set -o xtrace

base=$( dirname "${BASH_SOURCE[0]}")

for environment in $( find "${base}/env" -name \*.env ); do
	oc process --param-file="${environment}" --filename="${base}/jjb-configmap.yaml" | oc apply -f -
done