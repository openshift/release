#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

scl enable rh-ruby27 bash

# prepare users
users=""
data_htpasswd=""

for i in $(seq 1 10);
do
    username="testuser-${i}"
    password=`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true`

    users+="${username}:${password},"

    data_htpasswd+=`htpasswd -B -b -n ${username} ${password}`
    data_htpasswd+="\n"
done

users=${users::-1}

oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: htpass-secret
  namespace: openshift-config
stringData:
  htpasswd: ${data_htpasswd}
EOF

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

# Export those parameters before running
hosts=`grep server ${KUBECONFIG} | cut -d '/' -f 3 | cut -d ':' -f 1`
export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"
export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=${KUBECONFIG}

ver_cli=`oc version | grep Client | cut -d ' ' -f 3`
export BUSHSLICER_CONFIG="{'environments': {'ocp4': {'version': '${ver_cli:0:3}'}}}"
export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
export BUSHSLICER_REPORT_DIR=${ARTIFACT_DIR}

cd verification-tests
parallel_cucumber -n 4 --first-is-1 --type cucumber --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${users} | cut -d "," -f ${TEST_ENV_NUMBER});
     export WORKSPACE=$HOME/workdir/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"@smoke and not @admin and not @destructive and not @flake and not @inactive\" -p junit"'
