#!/bin/bash

set +u
set -o errexit
set -o pipefail

function create_openshift_role_permissions() {
  oc delete project tnb-tests || true
  oc new-project tnb-tests
  oc label --overwrite ns tnb-tests pod-security.kubernetes.io/enforce=privileged
  oc label --overwrite ns tnb-tests pod-security.kubernetes.io/enforce-version-
  oc adm policy add-scc-to-user privileged -z default -n tnb-tests

  oc create -f - <<EOF
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: tnb-tests
  name: tnb-tests
rules:
- apiGroups:
  - "*"
  resources:
  - "*"
  verbs:
  - "*"
EOF

  oc create -f - <<EOF
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: tnb-tests-rolebind
  namespace: tnb-tests
subjects:
  - kind: ServiceAccount
    name: default
    namespace: csb-interop
roleRef:
  kind: Role
  name: tnb-tests
  apiGroup: rbac.authorization.k8s.io
EOF

oc project csb-interop

}

function create_dc_and_tnb_tests_pod() {
  oc create -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: tnb-tests
  namespace: csb-interop
  annotations:
      image.openshift.io/triggers: '[{"from":{"kind":"ImageStreamTag","name":"tnb-tests:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\"tnb-tests\")].image"}]'
  labels:
    application: tnb
spec:
  strategy:
    type: Recreate
  triggers:
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
          - tnb-tests
        from:
          kind: ImageStreamTag
          name: tnb-tests:latest
    - type: ConfigChange
  replicas: 1
  selector:
    matchLabels:
      deployment: tnb-tests
  template:
    metadata:
      name: tnb-tests
      labels:
        deployment: tnb-tests
        application: tnb
    spec:
      securityContext:
        runAsUser: 0
      terminationGracePeriodSeconds: 60
      volumes:
        - name: mvn-settings
          configMap:
            name: mvn-settings
            items:
            - key: settings.xml
              path: custom.settings.xml
        - name: test-properties
          configMap:
            name: test-properties
            items:
            - key: test.properties
              path: test.properties
        - name: tnb-volume
          persistentVolumeClaim:
            claimName: persistent-tnb-tests
      containers:
        - name: tnb-tests
          image: csb-interop/tnb-tests:latest
          ports:
            - containerPort: 22
              protocol: TCP
            - containerPort: 80
              protocol: TCP
            - containerPort: 443
              protocol: TCP
          env:
          - name: MVN_ARGS
            value: -Dlpinterop -Drerun.failing.tests.count=1 -Drepo.maven-central -Drepo.redhat-ea -Drepo.redhat-ga -Drepo.atlassian-public -Drepo.jboss-qa-releases
          - name: MVN_SETTINGS_PATH
            value: /tmp/custom.settings.xml
          - name: MVN_PROFILES
            value: springboot-openshift
          - name: TEST_EXPR
            value: '!Sap*,!Soap*,!Validator*'
          - name: OPENSHIFT_NAMESPACE
            value: tnb-tests
          - name: NGINX_ROUTE
            value: $(oc get routes nginx -n csb-interop --no-headers=true | awk '{print $2}')
          - name: NAMESPACE
            value: tnb-tests
          - name: NAMESPACE_PREFIX
            value: ''
          - name: NAMESPACE_NAME
            value: 'tnb-tests'
          - name: FAILSAFE_REPORTS_FOLDER
            value: /deployments/tnb-tests/tests/springboot/examples/target/failsafe-reports
          securityContext:
            privileged: true
          volumeMounts:
            - name: mvn-settings
              mountPath: /tmp/
            - name: test-properties
              mountPath: /mnt/
            - name: tnb-volume
              mountPath: /tmp/failsafe-reports/
              subPath: failsafe-reports
            - name: tnb-volume
              mountPath: /tmp/surefire-root/
              subPath: surefire-root
            - name: tnb-volume
              mountPath: /tmp/log/
              subPath: log
            - name: tnb-volume
              mountPath: /deployments/.m2/
              subPath: maven-repo
EOF

sleep 120
}

function check_tests() {
  oc wait pods -n csb-interop -l deployment=tnb-tests --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 10
  runningPod=true
  count=0
  maxFailures=10
  while $runningPod; do
    tnbtestsPod=$(oc get pods -n csb-interop -l deployment=tnb-tests --no-headers=true | awk '{print $1}')
    sleep 60
    podlog=$(while read line; do echo "$line"; done <<< "$(oc logs --tail=50 "$tnbtestsPod" -n csb-interop)")
    if [[ "$podlog" == *"[INFO] Results:"* ]]; then
      echo "tnb-tests exited with results"
      runningPod=false
      oc logs --tail=5000 "$tnbtestsPod" -n csb-interop > "${ARTIFACT_DIR}"/run-tests.log
      oc -n csb-interop exec $tnbtestsPod -- find /deployments/tnb-tests/tests/springboot/examples/target/ -name '*.log' -exec cp {} /tmp/log \;
    elif [[ "$podlog" == *"BUILD FAILURE"* ]]; then
      echo "Failure during the build on $tnbtestsPod"
      oc exec $tnbtestsPod -n csb-interop -- /bin/bash -c 'cp -rf /artifacts-tests/* /deployments/.m2/repository' || true
      echo "Artifacts re-sync, wait 10 seconds ..."
      sleep 10
      echo "Store tnb-tests logs"
      oc logs --tail=5000 "$tnbtestsPod" -n csb-interop > "${ARTIFACT_DIR}"/run-tests.log
      echo "deploy/tnb-tests rolling out"
      restartPodAfterFailure
      count=$(expr $count + 1)
      if [[ $count -gt $maxFailures ]]; then
        echo "Max retries reached: exiting ..."
        break
      fi
      sleep 60
    elif [[ "$podlog" == *"[ERROR]"* ]] || [[ "$podlog" == *"Exception"* ]]; then
      echo "Exception occurred during execution"
      echo $podlog
      oc logs --tail=5000 "$tnbtestsPod" -n csb-interop > "${ARTIFACT_DIR}"/run-tests.log
      runningPod=false
      break
    fi
    echo "Check if tnb-tests are still running: $runningPod - attempt # $count"
  done
  echo "Tests completed on $tnbtestsPod"
  sleep 20
}

function restartPodAfterFailure() {
  create_openshift_role_permissions
  oc rollout restart deploy/tnb-tests -n csb-interop
  oc rollout status deploy/tnb-tests -n csb-interop --timeout=120s
  oc wait pods -n csb-interop -l deployment=tnb-tests --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 30
  echo "NGINX Server rollout ..."
  oc rollout restart deploy/nginx-server -n csb-interop || true
  oc rollout status deploy/nginx-server -n csb-interop --timeout=120s
  oc wait pods -n csb-interop -l deployment=nginx --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 30
  NGINX_ROUTE=$(oc get routes nginx -n csb-interop --no-headers=true | awk '{print $2}')
  echo "NGINX Route ${NGINX_ROUTE} deletion ..."
  oc delete route nginx -n csb-interop
  oc expose svc/nginx --hostname=${NGINX_ROUTE} -n csb-interop
  echo "NGINX Route recreated."
}

function copy_logs() {
  oc rollout restart deploy/nginx-server -n csb-interop
  sleep 120
  NGINX_POD=$(oc get pods -n csb-interop -l deployment=nginx --no-headers=true | awk '{print $1}')
  echo "get logs from pod ${NGINX_POD}"
  oc -n csb-interop exec ${NGINX_POD} -c nginx -- mkdir -p /tmp/reports
  oc -n csb-interop exec ${NGINX_POD} -c nginx -- find /tmp/failsafe-reports/ -name '*.xml' -exec cp {} /tmp/reports \;
  echo "failsafe logs stored"
  mkdir -p "${ARTIFACT_DIR}"/tests
  echo "creating test log sub-folder"
  oc cp csb-interop/"${NGINX_POD}":/tmp/log "${ARTIFACT_DIR}/tests"
  oc cp csb-interop/"${NGINX_POD}":/tmp/reports "${ARTIFACT_DIR}"
  echo "Waiting for copy synchronization between shared volumes"
  sleep 180
  echo "Prefix renaming for xmls"
  rename TEST junit_TEST ${ARTIFACT_DIR}/TEST*.xml
  echo "test log stored"
}

echo "Create permissions for sidecar tnb-tests project"
create_openshift_role_permissions

echo "Running the tests after deployment and tnb-tests pod creation"
create_dc_and_tnb_tests_pod

echo "Check tests status"
check_tests

echo "Copy logs for reporting"
copy_logs

