#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi
cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

if [ -f "${SHARED_DIR}/runtime_env" ] ; then
    source "${SHARED_DIR}/runtime_env"
fi
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# prepare users
users=""
htpass_file=/tmp/users.htpasswd

for i in $(seq 1 30);
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
oc create secret generic htpass-secret --from-file=htpasswd=${htpass_file} -n openshift-config
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpassidp
    challenge: true
    login: true
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
EOF

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

# configure cucushift runtime environment variables
hosts=$(grep server "${KUBECONFIG}" | cut -d '/' -f 3 | cut -d ':' -f 1)
ver_cli=$(oc version --client | cut -d ' ' -f 3 | cut -d '.' -f1,2)
users=${users::-1}

runtime_env=${SHARED_DIR}/runtime_env

cat <<EOF >>"${runtime_env}"
export USERS=${users}
export CUCUMBER_PUBLISH_QUIET=true
export DISABLE_WAIT_PRINT=true
export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
export BUSHSLICER_LOG_LEVEL=INFO
export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"
export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=file:///tmp/kubeconfig
export BUSHSLICER_CONFIG="{'global': {'browser': 'chrome'}, 'environments': {'ocp4': {'version': '${ver_cli}'}}}"
EOF
