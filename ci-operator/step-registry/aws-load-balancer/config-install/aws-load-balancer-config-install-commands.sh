#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -n "${OO_CONFIG_ENVVARS}" ]; then
    echo "=> parsing environment variables"
    envvars=""
    IFS=',' read -ra vars <<< "${OO_CONFIG_ENVVARS}"
    for var in "${vars[@]}"; do
        IFS='=' read -ra kv <<< "${var}"
        if [ ${#kv[@]} -eq 2 ]; then
            key=${kv[0]}
            val=${kv[1]}
            [ -n "${EVAL_CONFIG_ENVVARS}" ] && val=$(eval echo "${val}")
            [ -n "${envvars}" ] && envvars+=","
            echo "=> key \"${key}\" parsed"
            envvars+="${key}=${val}"
        fi
    done
    if [ -n "${envvars}" ]; then
        echo "=> configuring environment variables for \"${OO_INSTALL_NAMESPACE}/${CONFIG_DEPLOYMENT}\" deployment (\"${CONFIG_CONTAINER}\" container)"
        oc -n "${OO_INSTALL_NAMESPACE}" set env deploy/${CONFIG_DEPLOYMENT} -c "${CONFIG_CONTAINER}" ${envvars}
    else
        echo "=> no valid key/value pairs found"
        exit 1
    fi
else
    echo "=> nothing to configure"
fi
