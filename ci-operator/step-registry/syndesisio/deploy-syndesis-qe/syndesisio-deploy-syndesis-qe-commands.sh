#!/bin/bash

set -u
set -e
set -o pipefail

URL=$(oc whoami --show-server)
export URL

ADMIN_PASSWORD="admin"
export ADMIN_PASSWORD

export ADMIN_USERNAME="admin"

export FUSE_ONLINE_NAMESPACE="fuse-online"

SOURCE_DIR="/home/seluser/syndesis-qe"
export SOURCE_DIR

DEST_DIR="/tmp/test-artifacts"
export DEST_DIR

mkdir -p $DEST_DIR/endpoints
mkdir -p $DEST_DIR/rest-common
mkdir -p $DEST_DIR/rest-tests
mkdir -p $DEST_DIR/target
mkdir -p $DEST_DIR/ui-common
mkdir -p $DEST_DIR/ui-tests
mkdir -p $DEST_DIR/utilities
mkdir -p $DEST_DIR/validation

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

oc new-project test-runner

oc adm policy add-scc-to-user anyuid -z default

htpasswd -c -B -b /tmp/users.htpasswd admin "$ADMIN_PASSWORD"
htpasswd -B -b /tmp/users.htpasswd user "user"

oc create secret generic htpass-secret --from-file=htpasswd=/tmp/users.htpasswd -n openshift-config

cat <<EOF > /tmp/htpasswd-oa.yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: my_htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
EOF

oc apply -f /tmp/htpasswd-oa.yaml

oc adm policy add-cluster-role-to-user cluster-admin admin --rolebinding-name=cluster-admin

count=0
status=0
while [ $count -lt 60 ]; do
    oc login --insecure-skip-tls-verify=true -u "admin" -p "admin" "$(oc whoami --show-server)" || status=$? || :
    ((count=count+1))
    if [ $status -eq 0 ]; then
        break
    fi
    echo "Waiting to log in"
    sleep 5
    status=0
done

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

oc run test-runner --image="$FUSE_ONLINE_TEST_RUNNER" --env="ADMIN_USERNAME=$ADMIN_USERNAME" --env="ADMIN_PASSWORD=$ADMIN_PASSWORD" --env="URL=$(oc whoami --show-server)" --env="NAMESPACE=$FUSE_ONLINE_NAMESPACE" --port=8080 --restart=Never -- sleep 300

POD_NAME="test-runner"

oc wait --for=condition=Ready pod/"$POD_NAME" --timeout=-1s

while oc get pod "$POD_NAME" | grep -q Running; do
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/endpoints" "$DEST_DIR/endpoints" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/rest-common" "$DEST_DIR/rest-common" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/rest-tests" "$DEST_DIR/rest-tests" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/target" "$DEST_DIR/target" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/ui-common" "$DEST_DIR/ui-common" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/ui-tests" "$DEST_DIR/ui-tests" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/utilities" "$DEST_DIR/utilities" || :
  oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/validation" "$DEST_DIR/validation" || :
  oc logs "$POD_NAME" &> $DEST_DIR/test-runner.log || :
  sleep 5
done

mkdir -p $ARTIFACT_DIR/test-run-results

#while read -r FILE; do mkdir -p "$ARTIFACT_DIR"/test-run-results/"$(dirname "$FILE")"; cp "$FILE" "$ARTIFACT_DIR"/test-run-results/"$(dirname "$FILE")"; done <<< "$(find "$DEST_DIR" -type f -name "*.log")"

#while read -r DIR; do mkdir -p "$ARTIFACT_DIR"/test-run-results/"$DIR"; cp -r "$DIR"/* "$ARTIFACT_DIR"/test-run-results/"$DIR"; done <<< "$(find "$DEST_DIR" -maxdepth 2 -type d -wholename "*target/cucumber*")"

#cp $DEST_DIR/test-runner.log $ARTIFACT_DIR/test-run-results/ || :

cp -r $DEST_DIR $ARTIFACT_DIR/test-run-results/ || :

if oc get pod "$POD_NAME" | grep -q Completed; then
	exit 0
else
	exit 1
fi 
