#!/bin/bash

set -e
set -u
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function set_users () {
    # log in the cluster
    if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
    fi

    # prepare users
    users=""
    htpass_file=/tmp/users.htpasswd

    for i in $(seq 1 50);
    do
        username="testuser-${i}"
        password=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
        users+="${username}:${password},"
        if [ -f "${htpass_file}" ]; then
            htpasswd -B -b ${htpass_file} "${username}" "${password}"
        else
            htpasswd -c -B -b ${htpass_file} "${username}" "${password}"
        fi
    done

    # current generation
    gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

    # add users to cluster
    oc create secret generic cucushift-htpass-secret --from-file=htpasswd=${htpass_file} -n openshift-config
    oauth_file_src=/tmp/cucushift-oauth-src.yaml
    oauth_file_dst=/tmp/cucushift-oauth-dst.yaml
    oc get oauth cluster -o json > "${oauth_file_src}"
    jq '.spec.identityProviders += [{"htpasswd":{"fileData":{"name":"cucushift-htpass-secret"}},"challenge":"true","login":"true","mappingMethod":"claim","name":"cucushift-htpasswd-provider","type":"HTPasswd"}]' "${oauth_file_src}" > "${oauth_file_dst}"
    oc replace -f "${oauth_file_dst}"

    # wait for oauth-openshift to rollout
    wait_auth=true
    expected_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.spec.replicas}')
    while $wait_auth;
    do
        available_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.availableReplicas}')
        new_gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
        if [[ $expected_replicas == "$available_replicas" && $((new_gen)) -gt $((gen)) ]]; then
            wait_auth=false
        else
            sleep 10
        fi
    done

    # store users in a shared file
    if [ -f "${SHARED_DIR}/runtime_env" ] ; then
    source "${SHARED_DIR}/runtime_env"
    fi
    runtime_env=${SHARED_DIR}/runtime_env
    users=${users::-1}


    cat <<EOF >>"${runtime_env}"
export USERS=${users}
EOF
}

set_proxy
set_users
