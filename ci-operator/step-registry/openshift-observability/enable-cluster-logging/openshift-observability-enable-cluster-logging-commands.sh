#!/bin/bash
set -o nounset

storage_class=""
minio_secret=""
clo_csv="cluster-logging.v6"
lo_csv="loki-operator.v6"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

### common function ###
function prepare_namespace(){
    echo "Prepare namespace $1"
    if oc get project $1 -o name >/dev/null 2>&1; then
        echo "use existing namespace $1"
    else
        echo "create namespace $1"
        oc create ns $1  || exit 1
    fi
    oc label ns $1 openshift.io/cluster-monitoring="true"
    oc label ns $1 openshift.io/log-alerting="true"
}


function get_stroage_class()
{
    storage_class=$(oc get sc -ojsonpath="{.items[?(@.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class == \"true\")].metadata.name}")
    if [[ ${storage_class} == "" ]]; then
        storage_class=$(oc get sc -ojsonpath='{.items[0].metadata.name}')
    fi 
    if [[ ${storage_class} == "" ]]; then
        echo "exit, can not find storage class"
        exit 1
    fi
}

### validate if the cluster meet the pre-requisite for this step### check  ###
function check_envs()
{
    echo "### Valdiate if the cluster meet the pre-requisite for this step"
    if oc -n openshift-logging wait pod --for=condition=Ready  -l name=cluster-logging-operator --timeout=5s; then
         clo_csv=$(oc -n openshift-logging get csv -l operators.coreos.com/cluster-logging.openshift-logging -o name)
    else
	 echo "Exit, No cluster-logging operator"
	 exit 1
    fi
    if oc -n openshift-operators-redhat wait pod --for=condition=Ready  -l name=loki-operator-controller-manager --timeout=5s; then
         lo_csv=$(oc -n openshift-operators-redhat get csv -l operators.coreos.com/loki-operator.openshift-operators-redhat -o name)
    else
	 echo "Exit, No loki-operator "
	 exit 1
    fi
    get_stroage_class
}

### Deploy Lokistack ###
function deploy_minio()
{
    echo "### deploy minio for lokistack in ${MINIO_NAMESPACE}"
    prepare_namespace ${MINIO_NAMESPACE}
    minio_pod=$(oc -n ${MINIO_NAMESPACE} get pods -l app==minio -oname)
    if [[ "$minio_pod" == "" ]]; then
        minio_secret="minio$(date +%s)"
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
EOF
   else
        echo "use the existing minio" 
        minio_secret=$(oc get deployment minio -n ${MINIO_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MINIO_SECRET_KEY")].value}')
	if [[ "${minio_secret}" == "" ]]; then
            echo "exit 1, can not find minio secret for exisitng minio"
	    exit 1
        fi
    fi

    wait_minio_ready
    create_minio_bucket
}

function wait_minio_ready(){
    echo "### wait the mino ready up to 5 minutes"

    minio_ready=false
    count=1
    while [[ $count -le 5 ]]; do
        if oc -n ${MINIO_NAMESPACE} wait pod --for=condition=Ready  -l app=minio --timeout=30s; then
            minio_ready=true
            break
        fi
        sleep 30s
        (( count=count + 1 ))
    done

    if [[ $minio_ready == "false" ]]; then
       echo "minio is not ready in 5 minutes"
       echo "oc -n ${MINIO_NAMESPACE} get pods"
       oc -n ${MINIO_NAMESPACE} get pods 
       echo "oc -n ${MINIO_NAMESPACE} get events"
       oc -n ${MINIO_NAMESPACE} get events
       exit 1
    fi
}

function create_minio_bucket(){
   echo "Download mc binary"

    arch_info=$(uname -m )
    case $arch_info in 
        x86_64)
            arch="linux-amd64"
            ;;
        aarch64)
           arch="linux-arm64"
	   ;;
        ppc64le)
           arch="linux-ppc64le"
           ;;
        *)
           echo "Unknown arch, mc only x86_64,aarch64 and ppc64le"
           exit 1
    esac

    if [[ ! -s /tmp/mc ]] ; then
        echo "curl -s  https://dl.min.io/client/mc/release/${arch}/mc --create-dirs -o /tmp/mc"
        curl -s  https://dl.min.io/client/mc/release/${arch}/mc --create-dirs -o /tmp/mc
    fi

    # Exit, if we still can not find mc binary
    if [[ ! -s /tmp/mc ]] ; then
	echo "Exit, can not find the mc"
	exit 1
    fi
    chmod +x /tmp/mc
    echo "create bucket $MINIO_BUCKET"
    minio_url=$(oc get route minio -n ${MINIO_NAMESPACE} -o jsonpath='{.spec.host}')
    echo "/tmp/mc alias set myminio http://$minio_url minio <secret>"
    /tmp/mc alias set myminio http://$minio_url minio $minio_secret
    echo "/tmp/mc mb myminio/${MINIO_BUCKET} --ignore-existing"
    output=$(/tmp/mc mb myminio/${MINIO_BUCKET} --ignore-existing)
    if [[ ! "$output" =~ "Bucket created successfully" ]]; then
        echo "Exit, can not create bucket $MINIO_BUCKET"
	echo "${output}"
        exit 1
    fi
}

function deploy_lokistack()
{
    echo "### deploy lokistack logging-loki"
    prepare_namespace ${LOKI_NAMESPACE}

    echo " Create lokitack secret s3-secret"
    oc -n ${LOKI_NAMESPACE} create secret generic s3-secret --from-literal=bucketnames="${MINIO_BUCKET}" \
        --from-literal=region="" \
        --from-literal=endpoint="http://minio-service.${MINIO_NAMESPACE}.svc:9000" \
        --from-literal=access_key_id="minio" --from-literal=access_key_secret="${minio_secret}"
    schema_version="v13"
    if [[ "$lo_csv" =~ loki-operator.v5 ]];then
        schema_version="v12"
    fi

    cat <<EOF | oc create -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: ${LOKI_NAME}
  namespace: ${LOKI_NAMESPACE}
spec:
  managementState: Managed
  size: ${SIZE}
  storage:
    schemas:
      - effectiveDate: '2023-10-15'
        version: ${schema_version}
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
    echo "### Wait the lokistack ready up to 5 minutes"

    lokistack_ready=false
    count=1
    # Only validate the ingester pod herae
    while [[ $count -le 5 ]]; do
        if oc -n ${LOKI_NAMESPACE} wait pod --for=condition=Ready  -l app.kubernetes.io/instance=${LOKI_NAME} --timeout=30s; then
            lokistack_ready=true
	    break
        fi
        sleep 30s
        (( count=count + 1 ))
    done

    if [[ $lokistack_ready == "false" ]]; then
       echo "Exit, lokistack is not ready in 5 minutes"
       oc -n ${LOKI_NAMESPACE} get pod
       oc -n ${LOKI_NAMESPACE} get lokistack ${LOKI_NAME} -o jsonpath='.status'
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

## Gather logs and send to Lokistack
function enable_clf_5x(){
    echo "Create clf for cluster-logging:v5.x"
    #Note: for 5.x, we only deploy collector in openshift-logging namespace
    input_ref=$(echo $INPUTS|sed 's/,/\n/g'| sed 's/^/    - /')
    cat <<EOF|oc create -f -
apiVersion: "logging.openshift.io/v1"
kind: "ClusterLogging"
metadata:
  name: "instance"
  namespace: openshift-logging
spec:
  managementState: "Managed"
  logStore:
    type: "lokistack"
    lokistack:
      name: ${LOKI_NAME}
  collection:
    type: "vector"
  visualization:
    type: ocp-console
EOF

    cat <<EOF|oc create -f -
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  pipelines:
    - name: all-to-default
      inputRefs:
${input_ref}
      outputRefs:
      - default
EOF

}

function enable_clf_6x(){
    echo "Create clf for cluster-logging:v6.x"
    oc -n ${CLF_NAMESPACE} create sa logcollector
    oc -n ${CLF_NAMESPACE} adm policy add-cluster-role-to-user lokistack-tenant-logs -z logcollector
    oc -n ${CLF_NAMESPACE} adm policy add-cluster-role-to-user collect-application-logs -z logcollector
    oc -n ${CLF_NAMESPACE} adm policy add-cluster-role-to-user collect-infrastructure-logs -z logcollector
    oc -n ${CLF_NAMESPACE} adm policy add-cluster-role-to-user collect-audit-logs -z logcollector
    oc -n ${CLF_NAMESPACE} adm policy add-cluster-role-to-user logging-collector-logs-writer  -z logcollector

    input_ref=$(echo $INPUTS|sed 's/,/\n/g'| sed 's/^/    - /')
    cat << EOF | oc apply -f -
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
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
${input_ref}
    outputRefs:
    - my-lokistack
  serviceAccount:
    name: logcollector
EOF

}

function send_logs_to_lokistack()
{
    echo "### Send $INPUTS logs to Lokistack"

    prepare_namespace ${CLF_NAMESPACE}
    if [[ $clo_csv =~ cluster-logging.v5 ]]; then
        enable_clf_5x
    else
        enable_clf_6x
    fi

    wait_collector_ready

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

function wait_collector_ready(){
    echo "### Wait all collector pod  ready up to 5 minutes"

    collector_ready=false
    count=1
    # validate the collectord pod are in ready status
    while [[ $count -le 5 ]]; do
        if oc -n ${CLF_NAMESPACE} wait pod --for=condition=Ready  -l app.kubernetes.io/component=collector --timeout=30s; then
            collector_ready=true
	    break
        fi
        sleep 30s
        (( count=count + 1 ))
    done

    if [[ $collector_ready == "false" ]]; then
       echo "Exit, collector is not ready in 5 minutes"
       echo "oc -n ${CLF_NAMESPACE} get pod"
       oc -n ${CLF_NAMESPACE} get pod
       echo "oc -n ${CLF_NAMESPACE} get events"
       oc -n ${CLF_NAMESPACE} get events
       exit 1
    fi
}


### Create application and alerts
function create_pod_alert()
{
    user_namespace=$1
    echo "# Create app alert under namespace ${user_namespace}"
    prepare_namespace "$user_namespace"

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

---
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
}

function create_infra_aduit_alerts()
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
    create_pod_alert log-test-app1
    create_pod_alert log-test-app2
    create_infra_aduit_alerts
}

function report_status()
{   
    echo "### show cluster-logging status"
    echo "oc get pods -n $LOKI_NAMESPACE"
    oc get pods -n $LOKI_NAMESPACE
    if [[ "$CLF_NAMESPACE" != "$LOKI_NAMESPACE" ]];then
        echo "oc get pods -n $CLF_NAMESPACE"
        oc get pods -n $CLF_NAMESPACE
    fi
    echo "oc get pod -n openshift-cluster-observability-operator"
    oc get pod -n openshift-cluster-observability-operator
}


######Main ##############
check_envs
deploy_minio
deploy_lokistack
enable_logging_uiplugin
wait_lokistack_ready
send_logs_to_lokistack
if [[ $CREATE_DATA == "true" ]];then
    create_test_data
fi
report_status
