#!/bin/bash
set -o nounset

storage_class=""
idp_user1=""
minio_secret=""
bucket_name=""

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

### check if the cluster is Ok for openshift-logging ###
function get_stroage_class()
{
    storage_class=$(oc get storageclass --no-headers=true |cut -d" " -f1 |head -1)
    if [[ ${storage_class} == "" ]]; then
        echo "no stroage class for lokistack"
        exit 1
    fi 
    default_class=$(oc get storageclass |grep '(default)' |cut -d" " -f1)
    if [[ ${storage_class} != "" ]]; then
        storage_class=${default_class}
    fi
}

function ensure_envs()
{
    echo "# Check the step requirement"
    # exit if the cluster is not ready for cluster-logging
    if [[ "${KUBECONFIG}"  == "" ]] ; then 
        echo "no KUBECONFIG is defined !"
        exit 1
    fi
    if [[ ! -f "${KUBECONFIG}" ]] ; then 
        echo "kubeconfig ${KUBECONFIG} file does not exist ! "
        exit 1
    fi
    if [[ ! "${CHANNEL}" =~ "stable-" ]] ; then 
        echo "${CHANNEL} is not validi!"
        exit 1
    fi
    get_stroage_class
}

### deploy operators ###
function prepare_namespace(){
    echo "Prepare namespace $1"
    oc get project $1 -o name  && return 0
    echo "create namespace $1"
    oc adm new-project $1  || exit 1 
    oc label ns $1 openshift.io/cluster-monitoring="true"
    oc label ns $1 openshift.io/logging-alert="true"
}

function prepare_operator_group(){
    echo "Prepare operatorGroup in $1"
    og=$(oc get operatorgroup -n $1 -o name)
    if [[ $og == "" ]];then
        echo "create operator group global-operators"
        cat <<EOF| oc create -f - 
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: global-operators
  namespace: $1
spec:
  upgradeStrategy: Default
EOF
    else
       echo "use existing operator group=$og"
    fi
}

function deploy_clo_operator()
{
    echo "# deploy cluster-logging operator"
    prepare_namespace openshift-logging
    prepare_operator_group openshift-logging

    echo "# Subscribe cluster-logging to ${CATALOG}"
cat <<EOF|oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: cluster-logging
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
EOF
}

function deploy_lo_operator()
{
    echo "# deploy loki-operator"
    prepare_namespace openshift-operators-redhat
    prepare_operator_group openshift-operators-redhat

    echo "# Subscribe cluster-logging to ${CATALOG}"
cat <<EOF|oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: loki-operator
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
EOF
}

function wait_operators_ready(){
    echo "# wait the operators ready up to 2 minutes"
    
    clo_ready=false
    lo_ready=false
    count=1
    while [[ $count < 8 ]]; do
        if oc -n openshift-logging wait pod --for=condition=Ready  -l name=cluster-logging-operator; then
            clo_ready=true
        fi
        if oc -n openshift-operators-redhat wait pod --for=condition=Ready  -l name=loki-operator-controller-manager; then
            lo_ready=true
        fi
        if [[ $clo_ready == "true" && $lo_ready == "true" ]]; then
            break
        fi
        sleep 15s
        (( count=count + 1 ))
    done
    
    if [[ $clo_ready == "false" ]]; then
       echo "show status in openshift-logging "
       oc -n openshift-logging get sub
       oc -n openshift-logging get ip
       oc -n openshift-logging get pod
       oc -n openshift-operators-redhat get sub
       oc -n openshift-logging get ip
    fi
    
    if [[ $lo_ready == "false" ]]; then
       echo "show status in openshift-operators-redhat "
       oc -n openshift-operators-redhat get sub
       oc -n openshift-operators-redhat get ip
       oc -n openshift-operators-redhat get pod
    fi
    
    if [[ $clo_ready == "false" || $lo_ready == "false" ]]; then
       echo "The openshift-marketplace status"
       oc -n openshift-marketplace get pod
       echo "Operator are not ready!"
       exit 1
    fi
}

### Deploy Lokistack ###
function deploy_minio()
{
    minio_secret="minio_$(date +%s)"
    echo "# deploy minio for lokistack in openshift-logging-minio"
    if oc get project openshift-logging-minio ; then
	echo " use existing project openshift-logging-minio"
    else
	echo " create project openshift-logging-minio"
        oc adm new-project openshift-logging-minio  || exit 1
    fi
    cat <<EOF >/tmp/minio-deploy.yaml
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: minio-pv-claim
  namespace: openshift-logging-minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: minio
  namespace: openshift-logging-minio
spec:
  selector:
    matchLabels:
      app: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: minio
    spec:
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pv-claim
      containers:
      - name: minio
        volumeMounts:
        - name: data
          mountPath: "/data"
        image: quay.io/openshifttest/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ACCESS_KEY
          value: "minio"
        - name: MINIO_SECRET_KEY
          value: "${minio_secret}"
        ports:
        - containerPort: 9000
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 120
          periodSeconds: 20
        livenessProbe:
          httpGet:
            path: /minio/health/live
            port: 9000
          initialDelaySeconds: 120
          periodSeconds: 20
---
kind: Service
apiVersion: v1
metadata:
  name: minio-service
  namespace: openshift-logging-minio
spec:
  ports:
    - port: 9000
      targetPort: 9000
      protocol: TCP
  selector:
    app: minio
---
kind: Service
apiVersion: v1
metadata:
  name: minio-service-console
  namespace: openshift-logging-minio
spec:
  ports:
    - port: 9001
      targetPort: 9001
      protocol: TCP
  selector:
    app: minio
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  labels:
    app: minio
  name: minio
  namespace: openshift-logging-minio
spec:
  port:
    targetPort: 9000
  to:
    kind: Service
    name: minio-service
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  labels:
    app: minio
  name: minio-console
  namespace: openshift-logging-minio
spec:
  port:
    targetPort: 9001
  to:
    kind: Service
    name: minio-service-console
EOF

oc create -f /tmp/minio-deploy.yaml
}

function wait_minio_ready(){
    echo "# wait the mino ready up to 2 minutes"

    minio_ready=false
    count=1
    while [[ $count < 8 ]]; do
        if oc -n openshift-logging-minio wait pod --for=condition=Ready  -l app=minio; then
            minio_ready=true
        fi
        if [[ $minio_ready == "true" ]]; then
            break
        fi
        sleep 15s
        (( count=count + 1 ))
    done

    if [[ $minio_ready == "false" ]]; then
       echo "minio is not ready in 2 minutes"
       oc get pods -n openshift-logging-minio
       exit 1
    fi
}

function deploy_lokistack()
{
    echo "# deploy lokistack logging-loki"
    oc -n openshift-logging create secret generic s3-secret --from-literal=bucketnames="logging-loki" \
        --from-literal=region="" \
        --from-literal=endpoint="https://minio-service.openshift-logging-minio.svc:9000" \
        --from-literal=access_key_id="minio" --from-literal=access_key_secret="${minio_secret}"

cat <<EOF|oc create -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  managementState: Managed
  size: 1x.demo
  storage:
    schemas:
      - effectiveDate: '2023-10-15'
        version: v13
    secret:
      name: s3-secret
      type: s3
  storageClassName: ${storage_class}
  tenants:
    mode: openshift-logging
  rules:
    enabled: true
    selector:
      matchLabels:
        openshift.io/logging-alert: 'true'
    namespaceSelector:
      matchLabels:
        openshift.io/logging-alert: 'true'
EOF
}

function wait_lokistack_ready(){
    echo "# wait the lokistack ready up to 2 minutes"

    lokistack_ready=false
    count=1
    while [[ $count < 8 ]]; do
        if oc -n openshift-logging wait pod --for=condition=Ready  -l app.kubernetes.io/instance=logging-loki; then
            lokistack_ready=true
        fi
        if [[ $lokistack_ready == "true" ]]; then
            break
        fi
        sleep 15s
        (( count=count + 1 ))
    done

    if [[ $lokistack_ready == "false" ]]; then
       echo "lokistack is not ready in 2 minutes"
       oc get pods -n openshift-logging
       oc get lokistack logging-loki -o json|jq '.status'
       exit 1
    fi
}

## deploy clusterloggingforwarder
function send_logs_to_lokistack()
{
echo "# Create CLF in openshift-logging"

oc project openshift-logging
oc create sa logcollector
oc adm policy add-cluster-role-to-user lokistack-tenant-logs -z logcollector
oc adm policy add-cluster-role-to-user collect-application-logs -z logcollector
oc adm policy add-cluster-role-to-user collect-infrastructure-logs -z logcollector
oc adm policy add-cluster-role-to-user collect-audit-logs -z logcollector
oc adm policy add-cluster-role-to-user logging-collector-logs-writer  -z logcollector

cat << EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
  annotations:
    observability.openshift.io/tech-preview-otlp-output: "enabled"
spec:
  outputs:
  - name: my-lokistack
    lokiStack:
      dataModel: Otel
      authentication:
        token:
          from: serviceAccount
      target:
        name: logging-loki
        namespace: openshift-logging
    tls:
      ca:
        key: service-ca.crt
        configMapName: openshift-service-ca.crt
    type: lokiStack
  pipelines:
  - name: pipe1
    inputRefs:
    - infrastructure
    - application
    outputRefs:
    - my-lokistack
  serviceAccount:
    name: logcollector
EOF

echo " deploy lmfe "
oc apply -f - <<EOF
apiVersion: logging.openshift.io/v1alpha1
kind: LogFileMetricExporter
metadata:
  name: instance
  namespace: openshift-logging
spec:
  nodeSelector: {}
EOF

echo "oc get pods -n openshift-logging"
oc get pods -n openshift-logging

}

function create_loggen_pod()
{
    echo "# Create app/alert under namespace ${1}"
    user_namespace=$1

    cat <<EOF |oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${user_namespace}
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
    openshift.io/logging-alert: "true"
EOF

    cat <<EOF|oc -n $user_namespace create -f -
---
apiVersion: v1
data:
  ocp_logtest.cfg: |
    --num-lines 0 --line-length 200 --word-length 9 --rate 60 --fixed-line
kind: ConfigMap
metadata:
  name: logtest-config

apiVersion: v1
kind: ReplicationController
metadata:
  labels:
    run: centos-logtest
    test: centos-logtest
  name: centos-logtest
spec:
  replicas: 1
  template:
    metadata:
      generateName: centos-logtest-
      labels:
        run: centos-logtest
        test: centos-logtest
    spec:
      containers:
        - env: []
          image: quay.io/openshifttest/ocp-logtest@sha256:6e2973d7d454ce412ad90e99ce584bf221866953da42858c4629873e53778606
          imagePullPolicy: Always
          name: centos-logtest
          resources: {}
          terminationMessagePath: /dev/termination-log
          volumeMounts:
            - mountPath: /var/lib/svt
              name: config
      imagePullSecrets:
        - name: default-dockercfg-ukomu
      volumes:
        - configMap:
            name: logtest-config
          name: config
EOF

cat <<EOF |oc -n ${user_namespace} apply -f -
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  labels:
    openshift.io/cluster-monitoring: 'true'
  name: dev-workload-alerts
spec:
  groups:
    - interval: 1m
      name: devAppAlert
      rules:
        - alert: DevAppLogVolumeIsHigh
          annotations:
            description: My application has high amount of logs.
            summary: project "{${user_namespace}" log volume is high.
          expr: >
            count_over_time({kubernetes_namespace_name="${user_namespace}"}[2m])
            > 10
          for: 5m
          labels:
            severity: info
            devApp: 'true'
  tenantID: application
EOF

}

function create-infra_alert()
{
   echo "# Create InfraLogVolumeIsHigh alert"
cat <<EOF |oc apply -f -
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  labels:
    openshift.io/cluster-monitoring: 'true'
  name: infra-workload-alert
  namespace: openshift-logging
spec:
  groups:
    - interval: 1m
      name: InfraAppAlert
      rules:
        - alert: InfraLogVolumeIsHigh
          annotations:
            description: Infra has high amount of logs.
            summary: project "openshift-logging" log volume is high.
          expr: >
            count_over_time({kubernetes_namespace_name="openshift-logging"}[2m]) > 0
          for: 5m
          labels:
            severity: info
            devApp: 'false'
  tenantID: infrastructure
EOF



}

function create_test_data()
{
    oc new-project log-test-user
    create_loggen_pod log-test-user
    echo "
    create infra_alert
    echo "# grant ${user_name} view logs/alerts to ${user_namespace}"
    echo oc -n ${user_namespace} policy add-role-to-user view ${user_name}
    echo oc -n ${user_namespace} policy add-role-to-user cluster-logging-application-view ${user_name}
    echo oc -n ${user_namespace} policy add-role-to-user monitoring-rules-edit ${user_name}
    echo oc -n ${user_namespace} policy add-role-to-user cluster-monitoring-view  ${user_name}
}

######Main ##############
ensure_envs
deploy_clo_operator
deploy_lo_operator
deploy_minio
wait_operators_ready
wait_minio_ready
deploy_lokistack
wait_lokistack_ready
send_logs_to_lokistack
create_test_data

