#!/bin/bash

set -o errexit

main="$( dirname "${BASH_SOURCE[0]}" )/../../.."
resources="${main}/resources/redhat/openshift"

for job in add remove; do
    configmap_name="${job}-node"
    generated_output="${resources}/${configmap_name}_generated.yml"
    oc apply -f "${generated_output}"
done
