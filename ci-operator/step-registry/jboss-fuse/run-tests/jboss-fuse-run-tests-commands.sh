#!/bin/bash

set +u
set -o errexit
set -o pipefail

function create_dc_and_xpaas_pod()
{
  interopTestList=(
  "FisJavaDockerImageTest"
  "FisKarafDockerImageTest"
  "FisApicuritoDockerImageTest"
  "FisEapDockerImageTest"
  "KarafJolokiaTest"
  "SpringBootJolokiaTest"
  "PrometheusJonMetricsTest"
  "SpringBootCxfJaxrsXmlFabricTest"
  "SpringBootCxfJaxrsXmlS2ITest"
  "SpringBootCxfJaxrsFabricTest"
  "SpringBootCxfJaxrsS2ITest"
  )

  oc create -n jboss-fuse-interop serviceaccount jboss-fuse-sa || true
  oc adm policy add-scc-to-user privileged -z jboss-fuse-sa -n jboss-fuse-interop

  NGINX_ROUTE=$(oc get routes nginx -n jboss-fuse-interop --no-headers=true | awk '{print $2}')

  for i in "${!interopTestList[@]}"; do
    namespace=$(echo ${interopTestList[$i]} | tr '[:upper:]' '[:lower:]')
    namespace=${namespace/test/""}
    namespace=${namespace/karaf/k}
    namespace=${namespace/springboot/sb}
    namespace=${namespace/camel/c}
    namespace=${namespace/fabric/fab}
    namespace=${namespace/apicurito/ap}
    namespace=${namespace/prometheus/prom}

    oc create -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: ${namespace}
  namespace: jboss-fuse-interop
  annotations:
    image.openshift.io/triggers: '[{"from":{"kind":"ImageStreamTag","name":"xpaas-qe:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\"xpaas-qe\")].image"}]'
  labels:
    deployment: xpaas-qe
spec:
  strategy:
    type: Recreate
  triggers:
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
          - xpaas-qe
        from:
          kind: ImageStreamTag
          name: xpaas-qe:latest
    - type: ConfigChange
  replicas: 1
  selector:
    matchLabels:
      deployment: xpaas-qe
  template:
    metadata:
      name: xpaas-qe
      labels:
        deployment: xpaas-qe
        application: xpaas-qe
    spec:
      securityContext:
        runAsUser: 0
      serviceAccountName: jboss-fuse-sa
      terminationGracePeriodSeconds: 60
      volumes:
        - name: mvn-settings
          configMap:
            name: mvn-settings
            items:
            - key: settings.xml
              path: custom.settings.xml
        - name: test-properties
          secret:
            secretName: test-properties
            items:
              - key: test.properties
                path: test.properties
        - name: xpaas-qe-volume
          persistentVolumeClaim:
            claimName: persistent-xpaas-qe
      containers:
        - name: xpaas-qe
          image: xpaas-qe:latest
          ports:
            - containerPort: 22
              protocol: TCP
            - containerPort: 80
              protocol: TCP
            - containerPort: 443
              protocol: TCP
          env:
          - name: MVN_ARGS
            value: -Dlpinterop -Dxtf.custom.mirror.url=http://${NGINX_ROUTE}
          - name: MVN_SETTINGS_PATH
            value: /tmp/custom.settings.xml
          - name: MVN_PROFILES
            value: test-fuse,openshift4-current
          - name: TEST_EXPR
            value: ${interopTestList[$i]}
          - name: OPENSHIFT_NAMESPACE
            value: ${namespace}
          - name: NAMESPACE
            value: ${namespace}
          - name: NAMESPACE_PREFIX
            value: ${namespace}
          - name: SUREFIRE_REPORTS_FOLDER
            value: /deployments/xpaas-qe/test-fuse/target/surefire-reports
          securityContext:
            privileged: true
          volumeMounts:
            - name: mvn-settings
              mountPath: /tmp/
            - name: test-properties
              mountPath: /mnt/
              readOnly: true
            - name: xpaas-qe-volume
              mountPath: /tmp/xtf-oc-cache/
              subPath: xtf-oc-cache
            - name: xpaas-qe-volume
              mountPath: /tmp/surefire-reports/
              subPath: surefire-reports
            - name: xpaas-qe-volume
              mountPath: /tmp/log/
              subPath: log
            - name: xpaas-qe-volume
              mountPath: /deployments/.m2/
              subPath: maven-repo
            - name: xpaas-qe-volume
              mountPath: /tmp/reports
              subPath: reports
            - name: xpaas-qe-volume
              mountPath: /tmp/tests
              subPath: tests
EOF
    sleep 30
done
}

function check_tests() {
  declare -a trymap
	mapfile -t podlist < <(oc get pods -n jboss-fuse-interop -l deployment=xpaas-qe --no-headers=true | awk '{print $1}')
	echo "LIST ----"
	echo "${podlist[@]}"
	for k in "${!podlist[@]}"; do
	  currentTest=$(echo ${podlist[$k]} | awk -F"[-]" '{print $1}')
	  trymap[$currentTest]=0
	done

  while (( ${#podlist[@]} )); do
    echo "Number running pods still: ${#podlist[@]}"
    for i in "${!podlist[@]}"; do
       currentPod=${podlist[$i]}
       currentTest=$(echo $currentPod | awk -F"[-]" '{print $1}')
       currentRetriesNumber=${trymap[$currentTest]}
       echo "Evaluating $currentPod ... Number of retries: $currentRetriesNumber"
       echo "-------------------------------------------------------------------"
       podlog=$(while read line; do echo $line; done <<< "$(oc logs --tail=50 $currentPod -n jboss-fuse-interop)")
       if [[ "$podlog" == *"BUILD SUCCESS"* ]]; then
         echo "pod $currentPod terminating"
         if [[ "$podlog" == *"Failures: 0, Errors: 0"* ]]; then
           echo "$currentPod was successful"
           echo "get surefire xml pod reports"
           oc -n jboss-fuse-interop exec $currentPod -- /bin/bash -c 'cp -rf /deployments/xpaas-qe/test-fuse/target/surefire-reports/*.xml /tmp/reports' || true
           oc -n jboss-fuse-interop exec $currentPod -- /bin/bash -c 'cp -f /deployments/xpaas-qe/test-fuse/log/test.log /tmp/tests/'$currentPod'.log' || true
           sleep 20
           todelete=$(echo $currentPod | awk -F"[-]" '{print $1}')
           echo "DC TO DELETE: $todelete"
           oc delete deployment $todelete -n jboss-fuse-interop --ignore-not-found=true
           oc wait --for=delete deployment/$todelete -n jboss-fuse-interop --timeout=120s
           sleep 120
         else
           echo "Store $currentPod logs"
           oc logs --tail=5000 "$currentPod" -n jboss-fuse-interop > "${ARTIFACT_DIR}"/run-"$currentPod".log
           trymap[$currentTest]=$(expr ${trymap[$currentTest]} + 1)
           currentRetriesNumber=${trymap[$currentTest]}
           echo "$currentPod was unsuccessful at first attempt, rerun #$currentRetriesNumber"
           restartPodAfterFailure $currentPod ${trymap[$currentTest]}
         fi
       elif [[ "$podlog" == *"BUILD FAILURE"* ]]; then
         echo "Store $currentPod logs"
         oc logs --tail=5000 "$currentPod" -n jboss-fuse-interop > "${ARTIFACT_DIR}"/run-"$currentPod".log
         trymap[$currentTest]=$(expr ${trymap[$currentTest]} + 1)
         currentRetriesNumber=${trymap[$currentTest]}
         echo "$currentPod was in build failure at first attempt, rerun #$currentRetriesNumber"
         restartPodAfterFailure $currentPod ${trymap[$currentTest]}
      fi
      echo "-------------------------------------------------------------------"
    done
    mapfile -t podlist < <(oc get pods -n jboss-fuse-interop -l deployment=xpaas-qe --no-headers=true | awk '{print $1}')
  done
}

function restartPodAfterFailure() {
  local currentPod=$1
  local podFailures=$2
  maxFailures=15
  currentTest=$(echo $currentPod | awk -F"[-]" '{print $1}')

  oc rollout restart deploy/nginx-server -n jboss-fuse-interop || true
  oc wait pods -n jboss-fuse-interop -l deployment=nginx --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 30
  echo "NGINX Route deletion ..."
  NGINX_ROUTE=$(oc get routes nginx -n jboss-fuse-interop --no-headers=true | awk '{print $2}')
  oc delete route nginx -n jboss-fuse-interop
  oc expose svc/nginx --hostname=${NGINX_ROUTE} -n jboss-fuse-interop
  echo "NGINX Route recreated."
  if [[ "$podFailures" -lt $maxFailures ]]; then
    oc exec $currentPod -n jboss-fuse-interop -- /bin/bash -c 'rm -rf /tmp/log/'$currentPod'' || true
    oc exec $currentPod -n jboss-fuse-interop -- /bin/bash -c 'rm -rf /tmp/surefire-reports/'$currentPod'' || true
    oc delete pod $currentPod -n jboss-fuse-interop
    oc wait --for=delete pod/$currentPod -n jboss-fuse-interop --timeout=120s
    sleep 60
  else
    echo "max retries reached for $currentTest --- get surefire xml pod reports"
    oc -n jboss-fuse-interop exec $currentPod -- /bin/bash -c 'cp -rf /deployments/xpaas-qe/test-fuse/target/surefire-reports/*.xml /tmp/reports' || true
    oc -n jboss-fuse-interop exec $currentPod -- /bin/bash -c 'cp -f /deployments/xpaas-qe/test-fuse/log/test.log /tmp/tests/'$currentPod'.log' || true
    echo "DC TO DELETE: $currentTest"
    oc delete deployment $currentTest -n jboss-fuse-interop --ignore-not-found=true
    oc wait --for=delete deployment/$currentTest -n jboss-fuse-interop --timeout=120s
  fi
  sleep 100
}

function copy_logs() {
  oc rollout restart deploy/nginx-server -n jboss-fuse-interop
  oc wait pods -n jboss-fuse-interop -l deployment=nginx --for jsonpath="{status.phase}"=Running --timeout=120s
  sleep 30
  NGINX_POD=$(oc get pods -n jboss-fuse-interop -l deployment=nginx --no-headers=true | awk '{print $1}')
  echo "get logs from pod ${NGINX_POD} at /tmp/reports"
  export kubeadminpwd
  kubeadminpwd=$(cat $SHARED_DIR/kubeadmin-password)
  oc -n jboss-fuse-interop exec ${NGINX_POD} -c nginx -- /bin/bash -c 'find /tmp/reports/ -name *.xml -exec sed -i "s/\"$kubeadminpwd\"/\"XXXXXXXX\"/g" {} \;'
  echo "surefire logs stored"
  mkdir -p ${ARTIFACT_DIR}/tests
  echo "creating test log sub-folder"
  oc cp jboss-fuse-interop/"${NGINX_POD}":/tmp/tests "${ARTIFACT_DIR}/tests"
  oc cp jboss-fuse-interop/"${NGINX_POD}":/tmp/reports "${ARTIFACT_DIR}"
  echo "Prefix renaming for xmls"
  sleep 180
  rename TEST junit_TEST ${ARTIFACT_DIR}/TEST*.xml
  echo "test log stored"
  sleep 300
}

echo "Running the tests after deployment-config and xpaas-qe pod creation"
create_dc_and_xpaas_pod

echo "Check results copy logs for successful pods then delete DCs"
check_tests

echo "waiting before copy logs"
sleep 60
echo "Copy logs for reporting"
copy_logs
