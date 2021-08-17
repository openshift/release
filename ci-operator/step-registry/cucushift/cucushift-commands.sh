#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# prepare users
users=""
htpass_file=/tmp/users.htpasswd

for i in $(seq 1 10);
do
    username="testuser-${i}"
    password=`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true`

    users+="${username}:${password},"

    if [ -f "${htpass_file}" ];
    then
        htpasswd -B -b ${htpass_file} ${username} ${password}
    else
        htpasswd -c -B -b ${htpass_file} ${username} ${password}
    fi
done

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
expected_replicas=`oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.replicas}'`
while $wait_auth;
do
    available_replicas=`oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.replicas}'`
    if [ $expected_replicas == $available_replicas ];
    then
        wait_auth=false
    else
        sleep 3
    fi
done

# cucumber setting
export CUCUMBER_PUBLISH_QUIET=true

# Export those parameters before running
hosts=`grep server ${KUBECONFIG} | cut -d '/' -f 3 | cut -d ':' -f 1`
export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"
export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=${KUBECONFIG}

ver_cli=`oc version | grep Client | cut -d ' ' -f 3`
export BUSHSLICER_CONFIG="{'environments': {'ocp4': {'version': '${ver_cli:0:3}'}}}"
export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
export BUSHSLICER_REPORT_DIR=${ARTIFACT_DIR}

users=${users::-1}
export USERS=${users}

cd verification-tests
parallel_cucumber -n 4 --first-is-1 --type cucumber --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER});
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"@smoke and not @admin and not @destructive and not @flake and not @inactive\" -p junit"'
