#!/bin/bash

# The SIPPY_IMAGE variable is defined in the sippy-e2e-ref.yaml file as a
# dependency so that the pipeline:sippy image (containing the sippy binary)
# will be available to start the sippy-load and sippy-server pods.
echo "The sippy CI image: ${SIPPY_IMAGE}"

# Launch the sippy api server pod.
cat << END | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sippy-server
  namespace: postgres
  labels:
    app: sippy-server
spec:
  containers:
  - name: sippy-server
    image: ${SIPPY_IMAGE}
    imagePullPolicy: Always
    ports:
    - name: www
      containerPort: 8080
      protocol: TCP
    - name: metrics
      containerPort: 12112
      protocol: TCP
    readinessProbe:
      exec:
        command:
        - echo
        - "Wait for a short time"
      initialDelaySeconds: 10
    resources:
      limits:
        memory: 2G
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    command:
    - /bin/sippy
    args:
    - --server
    - --listen
    - ":8080"
    - --listen-metrics
    -  ":12112"
    - --local-data
    -  /opt/sippy-testdata
    - --database-dsn=postgresql://postgres:password@postgres.postgres.svc.cluster.local:5432/postgres
    - --log-level
    - debug
    - --mode
    - ocp
  imagePullSecrets:
  - name: regcred
  dnsPolicy: ClusterFirst
  restartPolicy: Always
  schedulerName: default-scheduler
  securityContext: {}
  terminationGracePeriodSeconds: 30
END

# The basic readiness probe will give us at least 10 seconds before declaring the pod as ready.
echo "Waiting for sippy api server pod to be Ready ..."
oc -n postgres wait --for=condition=Ready pod/sippy-server --timeout=30s

is_ready=0
for i in `seq 1 20`; do
  c=$(oc -n postgres logs sippy-server|tail -1|grep "Refresh complete"|wc -l)
  if [ $c -eq 1 ]; then
    echo "sippy server is ready."
    is_ready=1
    break
  fi
  echo "sippy server pod not ready yet ..."
  echo "${i} Sleeping 30s ..."
  sleep 30
done
if [ $is_ready -eq 0 ]; then
  echo "sippy server didn't become ready in time."
  exit 1
fi

oc -n postgres get pod -o wide
oc -n postgres logs sippy-server > ${ARTIFACT_DIR}/sippy-server.log

echo "Setup services and port forwarding for the sippy api server ..."
set -x

function cleanup() {
  echo "Cleaning up port forward"
  pf_job=$(jobs -p)
  kill ${pf_job} && wait
  echo "Port forward is cleaned up"
}
trap cleanup EXIT

# Create the Kubernetes service for the sippy-server pod
# Setup port forward for port 18080 to get to the sippy-server pod
oc -n postgres expose pod sippy-server
oc -n postgres port-forward pod/sippy-server 8080:8080 &
SIPPY_API_PORT=8080
export SIPPY_API_PORT

oc -n postgres get svc,ep

oc -n postgres delete secret regcred

go test ./test/e2e/ -v
