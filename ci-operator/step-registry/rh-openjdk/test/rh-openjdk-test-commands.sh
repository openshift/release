#!/bin/bash

set -x
set -u
set -e
set -o pipefail

mkdir -p /tmp/openjdk

cp $KUBECONFIG /tmp/openjdk/kubeconfig
cp /usr/bin/oc /tmp/openjdk

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
      command: ["sleep", "3600"]
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
EOF

    # Wait for pod to start
	POD_NAME=$(oc get pods -o jsonpath='{.items[0].metadata.name}')
	count=30
	while ! (oc get pod "$POD_NAME" | grep -q Running); do
    	echo $count
    	if [ "$count" -eq "0" ]
    	then
       		echo "Error: Timeout waiting for container to start"
        	exit 1
    	fi
    	sleep 10
    	count=$((count-1))
	done

    # Inject kubeconfgi and oc
    oc rsync /tmp/openjdk $POD_NAME:/tmp

    # Run tests on pod
    CMD="export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/s2i:/tmp/openjdk;export KUBECONFIG=/tmp/openjdk/kubeconfig;cd /tmp/rhscl_openshift_dir/openjdk;./run.sh --jdk-version=$JDK_VER"

    oc exec $POD_NAME -- bash -c "$CMD" 

    SOURCE_DIR="/tmp/rhscl_openshift_dir/openjdk"
    DEST_DIR="$ARTIFACT_DIR/test-run-results/openjdk-$JDK_VER"

    # Get results and artifacts and save to $ARTIFACT_DIR
    oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/test-openjdk/log" "$DEST_DIR" || :
    oc rsync --compress=true "$POD_NAME:$SOURCE_DIR/test-openjdk/target/surefire-reports" "$DEST_DIR" || :

    if [ "$status1" -ne "0" ]
    then
        status="$status1"
    fi

    # Rename result xml files
    NAME=/junit_jdk${JDK_VER}_TEST- || :
    rename '/TEST-' $NAME ${ARTIFACT_DIR}/test-run-results/openjdk-$JDK_VER/surefire-reports/TEST-*.xml 2>/dev/null || :

    oc delete pod $POD_NAME
done

exit $status

