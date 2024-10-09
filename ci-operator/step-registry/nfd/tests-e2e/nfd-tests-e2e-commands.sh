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
     image: quay.io/rh_ee_ggordani/eco-go:latest
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "scripts/test-runner.sh && sleep 300" ]
    env:
    - name: KUBECONFIG
      value: "/kubeconfig/kubeconfig"
    - name: ECO_TEST_FEATURES
      value: "nfd"
    - name: ECO_TEST_LABELS
      value: "NFD"
    - name: ECO_TEST_VERBOSE
      value: "true"
    - name: ECO_VERBOSE_LEVEL
      value: "100"
    - name: ECO_TC_PREFIX
      value: "OCP"
    - name: ECO_HWACCEL_NFD_SUBSCRIPTION_NAME
      value: "nfd"
    - name: ECO_HWACCEL_NFD_CATALOG_SOURCE
      value: "redhat-operators"
    - name: ECO_DUMP_FAILED_TESTS
      value: "true"
    - name: ECO_HWACCEL_NFD_CPU_FLAGS_HELPER_IMAGE
      value: quay.io/rh_ee_ggordani/cpuinfo:release-4.15
    - name: ECO_REPORTS_DUMP_DIR
      value: /home/testuser/reports
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
oc wait --for=condition=ContainersReady=true pod/testpod --timeout=500s
oc get pod testpod


while : ; do
  oc exec testpod -- ls /home/testuser/reports > /tmp/Files
  if ! grep -q 'nfd_suite_test_junit.xml' /tmp/Files ; then
    echo
    echo "Waiting for test results..."
    sleep 30
  else
    echo
    echo "Test results found."
    break
  fi
done

echo "Retrieve test results..."
oc exec testpod -- cat /home/testuser/reports/nfd_suite_test_junit.xml > ${ARTIFACT_DIR}/junit_nfd_suite_test.xml
oc exec testpod -- cat /home/testuser/reports/report_testrun.xml > ${ARTIFACT_DIR}/junit_report_testrun.xml