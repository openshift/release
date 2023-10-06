#!/bin/bash

set -u
set -e
set -o pipefail

mkdir -p /tmp/openjdk
cp $KUBECONFIG /tmp/openjdk/kubeconfig

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

oc new-project openjdk-runner

oc create sa anyuid

oc create -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scc-anyuid
  namespace: openjdk-runner
rules:
- apiGroups:
  - security.openshift.io
  resourceNames:
  - hostmount-anyuid
  resources:
  - securitycontextconstraints
  verbs:
  - use
EOF

oc create -f - <<EOF
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: sa-to-scc-anyuid
  namespace: openjdk-runner
subjects:
  - kind: ServiceAccount
    name: anyuid
roleRef:
  kind: Role
  name: scc-anyuid
  apiGroup: rbac.authorization.k8s.io
EOF

status=0

for JDK_VER in $OPENJDK_VERSION
do
    status1=0
    mkdir -p $ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER || :

    # Run tests
    echo "Executing tests for Open JDK $JDK_VER..."
    # ./run.sh --jdk-version=$JDK_VER || : ; 
    oc create -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: "openjdk-runner-$JDK_VER"
  labels:
    app: openjdk
  namespace: openjdk-runner
spec:
  serviceAccount: anyuid
  serviceAccountName: anyuid
  restartPolicy: Never
  containers:
    - name: rh-openjdk-runner
      image: quay.io/smatula/rh-openjdk-test-image
      env:
        - name: KUBECONFIG
          value: /tmp/openjdk/kubeconfig
      volumeMounts:
        - mountPath: /tmp/openjdk
          name: openjdk
          readOnly: false
      command: ["sleep", "3600"]
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
  volumes:
    - name: openjdk
      hostPath:
        path: $KUBECONFIG
        type: File
EOF

    SOURCE_DIR="/tmp/rhscl_openshift_dir/openjdk"
    DEST_DIR="$ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER"

    POD_NAME=$(oc get pods -o jsonpath='{.items[0].metadata.name}')

    while oc get pod "$POD_NAME" | grep -q Running; do
        oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/test-openjdk/log" "$DEST_DIR"
        oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/test-openjdk/target/surefire-reports" "$DEST_DIR"
        sleep 5
    done

    if [ "$status1" -ne "0" ]
    then
        status="$status1"
    fi

    # Copy results and artifacts to $ARTIFACT_DIR
    #echo "Archiving logs for Open JDK $JDK_VER..."
    #mv /tmp/openjdk/kubeconfig/* $ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER || :

    #echo "Archiving results for Open JDK $JDK_VER..."
    #cp -r ./test-openjdk/target/surefire-reports  $ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER || :

    # Rename result xml files
    NAME=/junit_jdk${JDK_VER}_TEST- || :
    rename '/TEST-' $NAME ${ARTIFACT_DIR}/test-run-results/openjdk-$JDK_VER/surefire-reports/TEST-*.xml 2>/dev/null || :
done

sleep 3600

exit $status

