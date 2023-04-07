#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying Syndesis QE Test Runner"

oc project default
oc create --as system:admin user kubeadmin
oc create --as system:admin identity kube:admin
oc create --as system:admin useridentitymapping kube:admin kubeadmin
oc adm policy --as system:admin add-cluster-role-to-user cluster-admin kubeadmin

ADMIN_PASSWORD=$(cat "$SHARED_DIR"/kubeadmin-password)
export ADMIN_PASSWORD

URL=$(oc whoami --show-server)
export URL

cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-runner
  namespace: default
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - resources:
        requests:
          cpu: "100m"
          memory: "200Mi"
      name: cli
      command:
        - /bin/sh
        - '-c'
        - sleep 7200
      securityContext:
        capabilities:
          drop:
            - ALL
        runAsUser: 1200
        runAsGroup: 1201
      volumeMounts:
        - name: test-run-results
          mountPath: /test-run-results
      image: >-
        $CLI
    - resources:
        requests:
          cpu: "100m"
          memory: "2Gi"
      name: runner
      env:
        - name: ADMIN_USERNAME
          value: kubeadmin
        - name: ADMIN_PASSWORD
          value: $ADMIN_PASSWORD
        - name: NAMESPACE
          value: $FUSE_ONLINE_NAMESPACE
        - name: URL
          value: $URL
      securityContext:
        capabilities:
          add:
            - AUDIT_WRITE
        runAsUser: 1200
        runAsGroup: 1201
      volumeMounts:
        - name: test-run-results
          mountPath: /test-run-results
      image: >-
        $FUSE_ONLINE_TEST_RUNNER
      workingDir: /home/seluser/syndesis-qe
  volumes:
    - name: test-run-results
EOF

oc wait --for=condition=Ready pod/test-runner --timeout=15m
oc wait --for=condition=ContainersReady=false pod/test-runner --timeout=1h30m

oc cp -c cli default/test-runner:/test-run-results /tmp/test-run-results
cp /tmp/test-run-results/ui-tests/target/cucumber/cucumber-junit.xml "$ARTIFACT_DIR"/junit_ui-tests.xml
cp /tmp/test-run-results/ui-tests/target/cucumber/cucumber-report.json "$ARTIFACT_DIR"/cucumber-report-ui-tests.json
tar -czvf /tmp/test-run-results.tar.gz /tmp/test-run-results/
mv /tmp/test-run-results.tar.gz "$ARTIFACT_DIR"
