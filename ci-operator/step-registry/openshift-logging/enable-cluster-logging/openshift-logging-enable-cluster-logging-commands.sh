#!/bin/bash
set -o nounset

storage_class=""
minio_secret=""

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi


### common function ###
function prepare_namespace(){
    echo "Prepare namespace $1"
    if oc get project $1 -o name; then
        echo "use existing namespace $1"
    else
        echo "create namespace $1"
        oc adm new-project $1  || exit 1
    fi
    oc label ns $1 openshift.io/cluster-monitoring="true"
    oc label ns $1 openshift.io/log-alerting="true"
}

function are_operators_ready(){
    echo " Wait the operators ready up to 1 minutes"
    clo_ready=false
    lo_ready=false
    count=1
    while [[ $count -lt 4 ]]; do
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

### check if the cluster is Ok for openshift-logging ###
function ensure_envs()
{
    echo "### Check the step requirement"
    # exit if the cluster is not ready for cluster-logging
    if [[ "${KUBECONFIG}"  == "" ]] ; then 
        echo "no KUBECONFIG is defined !"
        exit 1
    fi
    if [[ ! -f "${KUBECONFIG}" ]] ; then 
        echo "kubeconfig ${KUBECONFIG} file does not exist ! "
        exit 1
    fi
    are_operators_ready
    get_stroage_class
}

### Deploy Lokistack ###
function deploy_minio()
{
    echo "### deploy minio for lokistack in ${MINIO_NAMESPACE}"
    prepare_namespace ${MINIO_NAMESPACE}
    minio_secret="minio_$(date +%s)"

    cat <<EOF |oc create -f -
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: minio-pv-claim
  namespace: ${MINIO_NAMESPACE}
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
  namespace: ${MINIO_NAMESPACE}
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
  namespace: ${MINIO_NAMESPACE}
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
  namespace: ${MINIO_NAMESPACE}
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
  namespace: ${MINIO_NAMESPACE}
spec:
  port:
    targetPort: 9000
  to:
    kind: Service
    name: minio-service
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  labels:
    app: minio
  name: minio-console
  namespace: ${MINIO_NAMESPACE}
spec:
  port:
    targetPort: 9001
  to:
    kind: Service
    name: minio-service-console
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
}

function wait_minio_ready(){
    echo "### wait the mino ready up to 2 minutes"

    minio_ready=false
    count=1
    while [[ $count -lt 8 ]]; do
        if oc -n ${MINIO_NAMESPACE} wait pod --for=condition=Ready  -l app=minio; then
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
       oc -n ${MINIO_NAMESPACE} get pods 
       exit 1
    fi
}

function deploy_lokistack()
{
    echo "### deploy lokistack logging-loki"
    prepare_namespace ${LOKI_NAMESPACE}

    echo " Create lokitack secret s3-secret"
    oc -n ${LOKI_NAMESPACE} create secret generic s3-secret --from-literal=bucketnames="logging-loki" \
        --from-literal=region="" \
        --from-literal=endpoint="https://minio-service.${MINIO_NAMESPACE}.svc:9000" \
        --from-literal=access_key_id="minio" --from-literal=access_key_secret="${minio_secret}"

cat <<EOF|oc create -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: ${LOKI_NAME}
  namespace: ${LOKI_NAMESPACE}
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
        openshift.io/log-alerting: 'true'
    namespaceSelector:
      matchLabels:
        openshift.io/log-alerting: 'true'
EOF
}

function wait_lokistack_ready(){
    echo "### Wait the lokistack ready up to 2 minutes"

    lokistack_ready=false
    count=1
    while [[ $count -lt 8 ]]; do
        if oc -n ${LOKI_NAMESPACE} wait pod --for=condition=Ready  -l app.kubernetes.io/instance=logging-loki; then
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
       oc -n ${LOKI_NAMESPACE} get pod
       oc -n ${LOKI_NAMESPACE} get lokistack ${LOKI_NAME} -o json|jq '.status'
       exit 1
    fi
}

function enable_logging_uiplugin(){
    echo "### Enable_logging_uiplugin"
    coo=$(oc get csv -o name |grep observability-operator)
    if [[ $coo == "" ]];then
        echo "Skip LoggingUI -- no observability-operator"
    else
        echo "deploy LoggingUI Plugin"
        cat <<EOF|oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  logging:
    logsLimit: 20
    lokiStack:
      name: ${LOKI_NAME}
      namespace: ${LOKI_NAMESPACE}
    schema: select
    timeout: 5m
  type: Logging
EOF
    fi

}

## deploy clusterloggingforwarder
function send_logs_to_lokistack()
{
echo "### Create obsclf/lfme "

prepare_namespace ${CLF_NAMESPACE}
oc project ${CLF_NAMESPACE}
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
  namespace: ${CLF_NAMESPACE}
  annotations:
    observability.openshift.io/tech-preview-otlp-output: "enabled"
spec:
  outputs:
  - name: my-lokistack
    lokiStack:
      dataModel: Viaq
      authentication:
        token:
          from: serviceAccount
      target:
        name: ${LOKI_NAME}
        namespace: ${LOKI_NAMESPACE}
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

echo " deploy LogFileMetricExporter "
oc apply -f - <<EOF
apiVersion: logging.openshift.io/v1alpha1
kind: LogFileMetricExporter
metadata:
  name: instance
  namespace: openshift-logging
spec:
  nodeSelector: {}
EOF
}

### Create application and alerts
function create_pod_alert()
{
    user_namespace=$1
    echo "# Create app/alert under namespace ${user_namespace}"
    prepare_namespace "$1"

    echo "create pod centos-logtest in ${user_namespace}"
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

    echo "create alertingrule in ${user_namespace}"
    cat <<EOF |oc -n ${user_namespace} apply -f -
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  labels:
    openshift.io/log-alerting: "true"
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

    echo "Note: you can grant the common user to access logs the alerts using below command"
    echo " oc -n ${user_namespace} policy add-role-to-user view  <test_user_x>"
    echo " oc -n ${user_namespace} policy add-role-to-user cluster-logging-application-view <test_user_x>"
    echo " oc -n ${user_namespace} policy add-role-to-user monitoring-rules-edit <test_user_x>"
    echo " oc -n ${user_namespace} policy add-role-to-user cluster-monitoring-view <test_user_x> "
}

function create_infra_audit_alert()
{
   echo "Create Infra and audit alert"
cat <<EOF |oc apply -f -
---
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  labels:
    openshift.io/log-alerting: "true"
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

---
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  name: test-audit-alert
  namespace: openshift-logging
  labels:
    openshift.io/log-alerting: "true"
spec:
  groups:
    - interval: 1m
      name: TestAuditalert
      rules:
        - alert: TestAuditHighAllowRate
          annotations:
            description: testing1,2
            summary: testing1,2
          expr: >
            sum(rate({ log_type="audit" } |= "authorization.k8s.io/decision" |= "allow" [15s] )) > 0.01
          for: 1m
          labels:
            severity: critical
  tenantID: audit
EOF
}

function create_test_data()
{
    echo "### Prepare test logs and alerts"
    create_pod_alert log-test-app
    create_infra_aduit_alert
}

function report_status()
{   
    echo "### show cluster-logging status"
    oc get pods -n $LOKI_NAMESPACE
    if [[ "$CLF_NAMESPACE" != "$LOKI_NAMESPACE" ]];then
        oc get pods -n $CLF_NAMESPACE
    fi
    oc get uiplugin logging
}


######Main ##############
ensure_envs
deploy_minio
wait_minio_ready
deploy_lokistack
enable_logging_uiplugin
wait_lokistack_ready
send_logs_to_lokistack
if [[ $CREATE_DATA == "true" ]];then
    create_test_data
fi
report_status

