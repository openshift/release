#!/bin/bash

# In Prow CI, SIPPY_IMAGE variable is defined in the sippy-e2e-ref.yaml file as a
# dependency so that the pipeline:sippy image (containing the sippy binary)
# will be available to start the sippy-load and sippy-server pods.
# When running locally, the user has to define SIPPY_IMAGE.
echo "The sippy CI image: ${SIPPY_IMAGE}"

# The BIG_QUERY_CRED is so you login to Big Query.
# Redefine BIG_QUERY_CRED to use your own.
BIG_QUERY_CRED="${BIG_QUERY_CRED:=/var/run/sippy-ci-gcs-sa/gcs-sa}"
echo "The Big Query cred is: ${BIG_QUERY_CRED}"

# If you're using Openshift, we use oc, if you're using plain Kubernetes,
# we use kubectl.
#
KUBECTL_CMD="${KUBECTL_CMD:=oc}"
echo "The kubectl command is: ${KUBECTL_CMD}"

echo "The Docker config.json is: ${DOCKERCONFIGJSON}"

is_ready=0
echo "Waiting for cluster-pool cluster to be usable ..."

e2e_pause() {
  if [ -z $OPENSHIFT_CI ]; then
    return
  fi

  # In prow, we need these sleeps to keep things consistent -- TODO: we need to figure out why.
  echo "Sleeping 30 seconds ..."
  sleep 30
}

# We need this for Linux version of base64 to suppress the line breaks.
BASE64_OPTION="-w0"
if [[ "${OSTYPE}" == "darwin"* ]]; then
  # On MacOS, the -w0 option is an error.
  BASE64_OPTION=""
fi

set +e
# We don't want to exit on timeouts if the cluster we got was not quite ready yet.
for i in `seq 1 20`; do
  echo -n "${i})"
  e2e_pause
  echo "Checking cluster nodes"
  ${KUBECTL_CMD} get node
  if [ $? -eq 0 ]; then
    echo "Cluster looks ready"
    is_ready=1
    break
  fi
  echo "Cluster-pool cluster not ready yet ..."
done
set -e

# This should be set to the KUBECONFIG for the cluster claimed from the cluster-pool.
echo "KUBECONFIG=${KUBECONFIG}"

echo "Showing kube context"
${KUBECTL_CMD} config current-context

if [ $is_ready -eq 0 ]; then
  echo "Cluster never became ready aborting"
  exit 1
fi

e2e_pause

echo "Checking for presense of GCS credentials ..."
if [ -f ${BIG_QUERY_CRED} ]; then
  ls -l ${BIG_QUERY_CRED}
else
  echo "Aborting: Big Query credential file ${BIG_QUERY_CRED} not found"
  exit 1
fi

echo "Starting postgres on cluster-pool cluster..."

# Make the "postgres" namespace and pod.
cat << END | ${KUBECTL_CMD} apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: postgres
  labels:
    openshift.io/run-level: "0"
    openshift.io/cluster-monitoring: "true"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
END

e2e_pause

cat << END | ${KUBECTL_CMD} apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postg1
  namespace: postgres
  labels:
    app: postgres
spec:
  volumes:
    - name: postgredb
      emptyDir: {}
  containers:
  - name: postgres
    image: quay.io/enterprisedb/postgresql
    ports:
    - containerPort: 5432
    env:
    - name: POSTGRES_PASSWORD
      value: password
    - name: POSTGRESQL_DATABASE
      value: postgres
    volumeMounts:
      - mountPath: /var/lib/postgresql/data
        name: postgredb
    securityContext:
      privileged: false
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      runAsNonRoot: true
      runAsUser: 3
      seccompProfile:
        type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: postgres
  name: postgres
  namespace: postgres
spec:
  ports:
  - name: postgres
    port: 5432
    protocol: TCP
  selector:
    app: postgres
END

echo "Waiting for postgres pod to be Ready ..."

# We set +e to avoid the script aborting before we can retrieve logs.
set +e
TIMEOUT=120s
echo "Waiting up to ${TIMEOUT} for the postgres to come up..."
${KUBECTL_CMD} -n postgres wait --for=condition=Ready pod/postg1 --timeout=${TIMEOUT}
retVal=$?
set -e
echo
echo "Saving postgres logs ..."
${KUBECTL_CMD} -n postgres logs postg1 > ${ARTIFACT_DIR}/postgres.log
if [ ${retVal} -ne 0 ]; then
  echo "Postgres pod never came up"
  exit 1
fi

${KUBECTL_CMD} -n postgres get po -o wide
${KUBECTL_CMD} -n postgres get svc,ep

# Get the gcs credentials out to the cluster-pool cluster.
# These credentials are in vault and maintained by the TRT team (e.g. for updates and rotations).
# See https://vault.ci.openshift.org/ui/vault/secrets/kv/show/selfservice/technical-release-team/sippy-ci-gcs-read-sa
cat << END | sed s/CONTENT/"$(cat ${BIG_QUERY_CRED} |base64 ${BASE64_OPTION})"/| ${KUBECTL_CMD} apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gcs-cred
  namespace: postgres
data:
  openshift-ci-data-analysis-ro: CONTENT
END

# Get the registry credentials for all build farm clusters out to the cluster-pool cluster.
${KUBECTL_CMD} -n postgres create secret generic regcred --from-file=.dockerconfigjson=${DOCKERCONFIGJSON} --type=kubernetes.io/dockerconfigjson

# Make the "sippy loader" pod.
cat << END | ${KUBECTL_CMD} apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: sippy-load-job
  namespace: postgres
spec:
  template:
    spec:
      containers:
      - name: sippy
        image: ${SIPPY_IMAGE}
        imagePullPolicy: Always
        resources:
          limits:
            memory: 2G
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        command:  ["/bin/sh", "-c"]
        args:
          - /bin/sippy --load-database --log-level=debug --load-prow=true --load-testgrid=false --release 4.7 --database-dsn=postgresql://postgres:password@postgres.postgres.svc.cluster.local:5432/postgres --mode=ocp --config ./config/openshift.yaml --google-service-account-credential-file /tmp/secrets/openshift-ci-data-analysis-ro
        env:
        - name: GCS_SA_JSON_PATH
          value: /tmp/secrets/openshift-ci-data-analysis-ro
        volumeMounts:
        - mountPath: /tmp/secrets
          name: gcs-cred
          readOnly: true
      imagePullSecrets:
      - name: regcred
      volumes:
        - name: gcs-cred
          secret:
            secretName: gcs-cred
      dnsPolicy: ClusterFirst
      restartPolicy: Never
      schedulerName: default-scheduler
      securityContext: {}
      terminationGracePeriodSeconds: 30
  backoffLimit: 1
END

date
echo "Waiting for sippy loader job to finish ..."
${KUBECTL_CMD} -n postgres get job sippy-load-job
${KUBECTL_CMD} -n postgres describe job sippy-load-job

# We set +e to avoid the script aborting before we can retrieve logs.
set +e
# This takes under 3 minutes so 5 minutes (300 seconds) should be plenty.
TIMEOUT=300s
echo "Waiting up to ${TIMEOUT} for the sippy-load-job to complete..."
${KUBECTL_CMD} -n postgres wait --for=condition=complete job/sippy-load-job --timeout ${TIMEOUT}
retVal=$?
set -e

job_pod=$(${KUBECTL_CMD} -n postgres get pod --selector=job-name=sippy-load-job --output=jsonpath='{.items[0].metadata.name}')
${KUBECTL_CMD} -n postgres logs ${job_pod} > ${ARTIFACT_DIR}/sippy-load.log

if [ ${retVal} -ne 0 ]; then
  echo "sippy loading never finished on time."
  exit 1
fi

date
