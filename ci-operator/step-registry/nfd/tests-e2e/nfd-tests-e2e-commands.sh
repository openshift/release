#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Run NFD Interop testing..."

# create secret for cluster login
oc create secret generic kubeconfig-secret --from-file $SHARED_DIR/kubeconfig

cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: testpod
spec:
  restartPolicy: Never
  containers:
  - name: run-nfd
    image: quay.io/rh_ee_ggordani/nfd_test:latest
    command: [ "python3", "/app/nfd_test.py" ]
    args: [ ]
    env:
    - name: KUBECONFIG
      value: "/kubeconfig/kubeconfig"
    imagePullPolicy: Always
    resources:
      limits:
        cpu: 500m
        memory: 1000Mi
      requests:
        cpu: 500m
        memory: 1000Mi
    securityContext:
      privileged: true
      runAsNonRoot: false
    volumeMounts:
    - name: kubeconfig
      mountPath: /kubeconfig
    - name: reports-volume
      mountPath: /home/testuser/reports
  volumes:
  - name: kubeconfig
    secret:
      secretName: kubeconfig-secret
  - name: reports-volume
    hostPath:
      path: /tmp/reports
      type: DirectoryOrCreate
EOF

echo "Check pod status"
oc wait --for=condition=ContainersReady=true pod/testpod --timeout=300s
oc get pod testpod

echo "Waiting for pod to complete..."
oc wait --for=condition=PodReadyCondition=false pod/testpod --timeout=1800s || true
oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/testpod --timeout=300s
echo "Pod completed, checking final status and logs..."
oc get pod testpod
oc logs testpod

echo "Retrieve test results..."
oc cp testpod:/home/testuser/reports/nfd_suite_test_junit.xml ${ARTIFACT_DIR}/junit_nfd_suite_test.xml || \
  echo "Warning: Could not copy nfd_suite_test_junit.xml"
oc cp testpod:/home/testuser/reports/report_testrun.xml ${ARTIFACT_DIR}/junit_report_testrun.xml || \
  echo "Warning: Could not copy report_testrun.xml"
