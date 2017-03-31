#!/bin/bash

set -o errexit

main="$( dirname "${BASH_SOURCE[0]}" )/../../.."
resources="${main}/resources/redhat/openshift"
groovy="${main}/groovy/redhat/openshift"

for job in add remove; do
    # generate the JJB defenition
    jjb="${resources}/${job}Node.yml"
    script="${groovy}/${job}Node.groovy"
    generated_jjb="$( dirname "${jjb}" )/$( basename "${jjb}" .yml )_generated.yml"
    rm -f "${generated_jjb}"
    "${resources}/injectGroovyScript.py" "${jjb}" "${script}" "${generated_jjb}"

    # generate the ConfigMap
    configmap_name="${job}-node"
    output="${resources}/${configmap_name}_generated.yml"
    rm -f "${output}"
    oc create configmap "${configmap_name}" --dry-run -o yaml    \
                        --from-file="job.yml=${generated_jjb}" | \
    oc annotate --dry-run -o yaml --local                        \
                -f - "ci.openshift.io/jenkins-job=true"          \
    > "${output}"
done