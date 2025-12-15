#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEMPO_NAMESPACE="tracing-system"
export OTEL_NAMESPACE="opentelemetrycollector"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

oc version

# cleaning leftovers if exists
oc delete istio default ${ISTIO_NAMESPACE} || true
oc delete istiocni default ${ISTIO_CNI_NAMESPACE} || true
oc delete project ${TEMPO_NAMESPACE} || true
oc delete project ${OTEL_NAMESPACE} || true
oc delete project ${ISTIO_NAMESPACE} || true
oc delete project ${ISTIO_CNI_NAMESPACE} || true  

oc new-project ${ISTIO_NAMESPACE}
oc new-project ${ISTIO_CNI_NAMESPACE}
oc new-project ${TEMPO_NAMESPACE}
oc new-project ${OTEL_NAMESPACE}

echo "===== Installing Minio for Tempo ====="

oc apply -n ${TEMPO_NAMESPACE} -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
 # This name uniquely identifies the PVC. Will be used in deployment below.
 name: minio-pv-claim
 labels:
   app: minio-storage-claim
spec:
 # Read more about access modes here: http://kubernetes.io/docs/user-guide/persistent-volumes/#access-modes
 accessModes:
   - ReadWriteOnce
 resources:
   # This is the request for storage. Should be available in the cluster.
   requests:
     storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
 name: minio
spec:
 selector:
   matchLabels:
     app: minio
 strategy:
   type: Recreate
 template:
   metadata:
     labels:
       # Label is used as selector in the service.
       app: minio
   spec:
     # Refer to the PVC created earlier
     volumes:
       - name: storage
         persistentVolumeClaim:
           # Name of the PVC created earlier
           claimName: minio-pv-claim
     initContainers:
       - name: create-buckets
         # !! when you change tag, do not forget to update mirror scripts in kiali-qe-utils repo !!
         image: mirror.gcr.io/busybox:1.28.0
         command:
           - "sh"
           - "-c"
           - "mkdir -p /storage/tempo-data"
         volumeMounts:
           - name: storage # must match the volume name, above
             mountPath: "/storage"
     containers:
       - name: minio
         # Pulls the default Minio image from Docker Hub. !! when you change tag, do not forget to update mirror scripts in kiali-qe-utils repo !!
         image: quay.io/minio/minio:RELEASE.2024-10-02T17-50-41Z
         args:
           - server
           - /storage
           - --console-address
           - ":9001"
         env:
           # Minio access key and secret key
           - name: MINIO_ROOT_USER
             value: "minio"
           - name: MINIO_ROOT_PASSWORD
             value: "minio123"
         ports:
           - containerPort: 9000
           - containerPort: 9001
         volumeMounts:
           - name: storage # must match the volume name, above
             mountPath: "/storage"
---
apiVersion: v1
kind: Service
metadata:
 name: minio
spec:
 type: ClusterIP
 ports:
   - port: 9000
     targetPort: 9000
     protocol: TCP
     name: api
   - port: 9001
     targetPort: 9001
     protocol: TCP
     name: console
 selector:
   app: minio
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: minio-route
spec:
  to:
    kind: Service
    name: minio
  port:
    targetPort: api
EOF
oc -n ${TEMPO_NAMESPACE} wait --for condition=Available deployment/minio --timeout 150s || (oc describe -n ${TEMPO_NAMESPACE} deployment/minio; oc describe pods -n ${TEMPO_NAMESPACE}; exit 1)
MINIO_HOST=$(oc get route minio-route -n ${TEMPO_NAMESPACE} -o=jsonpath='{.spec.host}')

oc apply -n ${TEMPO_NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-storage-secret
type: Opaque
stringData:
  endpoint: http://${MINIO_HOST}
  bucket: tempo-data
  access_key_id: minio
  access_key_secret: minio123
EOF

echo "Installing TempoCR"
oc apply -n ${TEMPO_NAMESPACE} -f - <<EOF
kind: TempoStack
apiVersion: tempo.grafana.com/v1alpha1
metadata:
  name: sample
spec:
  storage:
    secret:
      name: my-storage-secret
      type: s3
  storageSize: 1Gi
  template:
    querier:
      resources:
        limits:
          cpu: "2"
    queryFrontend:
      component:
        resources:
          limits:
            memory: 6Gi
      jaegerQuery:
        enabled: true
EOF

oc -n ${TEMPO_NAMESPACE} wait --for condition=Ready TempoStack/sample --timeout 150s || (oc describe -n ${TEMPO_NAMESPACE} TempoStack/sample; oc describe pods -n ${TEMPO_NAMESPACE}; exit 1)
oc -n ${TEMPO_NAMESPACE} wait --for condition=Available deployment/tempo-sample-compactor --timeout 150s || (oc describe -n ${TEMPO_NAMESPACE} deployment/tempo-sample-compactor; exit 1)

echo "Exposing Jaeger UI route (will be used in kiali ui)"
oc apply -n ${TEMPO_NAMESPACE} -f - <<EOF
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: tracing-ui
  namespace: tracing-system
spec:
  to:
    kind: Service
    name: tempo-sample-query-frontend
    weight: 100
  port:
    targetPort: jaeger-ui
  wildcardPolicy: None
EOF
sleep 2s

if timeout 300 bash -c 'until oc -n '"${TEMPO_NAMESPACE}"' get route/tracing-ui &>/dev/null; do echo "Route tracing-ui does not exist"; sleep 2; done'; then
  echo "Route tracing-ui exists"
  oc -n ${TEMPO_NAMESPACE} get routes
else
  echo "Timeout: Route tracing-ui was not created within 5 minutes"
  oc -n ${TEMPO_NAMESPACE} get routes
  oc -n ${TEMPO_NAMESPACE} get services
  oc -n ${TEMPO_NAMESPACE} get service tempo-sample-query-frontend -o yaml
fi

echo "===== Installing OpenTelemetryCollector ====="
oc apply -n ${OTEL_NAMESPACE} -f - <<EOF
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
spec:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    exporters:
      otlp:
        endpoint: "tempo-sample-distributor.${TEMPO_NAMESPACE}.svc.cluster.local:4317"
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: []
          exporters: [otlp]
EOF
sleep 2s
oc -n ${OTEL_NAMESPACE} wait --for condition=Available deployment/otel-collector --timeout 120s || (oc describe -n ${OTEL_NAMESPACE} deployment/otel-collector; oc describe pods -n ${OTEL_NAMESPACE}; exit 1)

echo "===== Installing Istio ====="
oc apply -n ${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: ${ISTIO_NAMESPACE}
  values:
    global:
      defaultPodDisruptionBudget:
        enabled: false
    meshConfig:
      extensionProviders:
      - name: otel
        opentelemetry:
          port: 4317
          service: otel-collector.${OTEL_NAMESPACE}.svc.cluster.local
    pilot:
      autoscaleEnabled: false
  version: ${ISTIO_VERSION}
EOF
oc wait --for condition=Ready -n istio-system istio/default --timeout 120s || (oc describe -n istio-system istio/default; oc describe pods -n istio-system; exit 1)

echo "Installing Telemetry resource..."
oc apply -n ${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
spec:
  tracing:
  - providers:
    - name: otel
      randomSamplingPercentage: 100
EOF
echo "Adding OTEL namespace as a part of the mesh"
oc label namespace ${OTEL_NAMESPACE} istio-injection=enabled

echo "===== Installing Istio CNI ====="
oc apply -n ${ISTIO_CNI_NAMESPACE} -f - <<EOF
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  profile: openshift
  version: ${ISTIO_VERSION}
EOF
oc wait --for condition=Ready -n ${ISTIO_CNI_NAMESPACE} istiocni/default --timeout 120s || (oc describe -n ${ISTIO_CNI_NAMESPACE} istiocni/default; oc describe pods -n ${ISTIO_CNI_NAMESPACE}; exit 1)

echo "===== Installing Kiali... ====="
oc project ${ISTIO_NAMESPACE}
echo "Creating cluster role binding for kiali to read ocp monitoring"
oc apply -n ${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali-monitoring-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
- kind: ServiceAccount
  name: kiali-service-account
  namespace: ${ISTIO_NAMESPACE}
EOF
echo "Installing KialiCR..."
TRACING_INGRESS_ROUTE="http://$(oc get -n ${TEMPO_NAMESPACE} route tracing-ui -o jsonpath='{.spec.host}')"

oc apply -n ${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
spec:
  auth:
    strategy: openshift
  deployment:
    cluster_wide_access: true
    namespace: istio-system
    pod_labels:
      sidecar.istio.io/inject: 'false'
  external_services:
    grafana:
      enabled: false
    prometheus:
      auth:
        type: bearer
        use_kiali_token: true
      query_scope:
        mesh_id: ossm-3
      thanos_proxy:
        enabled: true
      url: 'https://thanos-querier.openshift-monitoring.svc.cluster.local:9091'
    tracing:
      enabled: true
      internal_url: "http://tempo-sample-query-frontend.${TEMPO_NAMESPACE}.svc.cluster.local:3200"
      external_url: ${TRACING_INGRESS_ROUTE} 
      query_timeout: 60
      use_grpc: false
      provider: tempo
      tempo_config:
        url_format: "jaeger"
  installation_tag: "Kiali [istio-system]"
  istio_namespace: istio-system
  server:
    write_timeout: 60
EOF
oc wait --for condition=Successful kiali/kiali --timeout 200s -n ${ISTIO_NAMESPACE} || (oc describe -n ${ISTIO_NAMESPACE} kiali/kiali; oc describe pods -n ${ISTIO_NAMESPACE}; exit 1)
oc annotate route kiali haproxy.router.openshift.io/timeout=60s -n ${ISTIO_NAMESPACE}

echo "=== Enabling user-monitoring workflow"
wget -N https://raw.githubusercontent.com/kiali/kiali/master/hack/use-openshift-prometheus.sh
chmod +x use-openshift-prometheus.sh
./use-openshift-prometheus.sh -in ${ISTIO_NAMESPACE} -np true -ml ossm-3 -kcns ${ISTIO_NAMESPACE}
oc wait --for condition=Successful kiali/kiali --timeout 200s -n ${ISTIO_NAMESPACE} || (oc describe -n ${ISTIO_NAMESPACE} kiali/kiali; oc describe pods -n ${ISTIO_NAMESPACE}; exit 1)

echo "Installing Kiali OSSMC CR..."

oc apply -n ${ISTIO_NAMESPACE} -f - <<EOF
apiVersion: kiali.io/v1alpha1
kind: OSSMConsole
metadata:
  name: ossmconsole
EOF

oc wait --for=condition=Successful OSSMConsole ossmconsole --timeout 200s -n ${ISTIO_NAMESPACE} || (oc describe -n ${ISTIO_NAMESPACE} OSSMConsole ossmconsole; oc describe pods -n ${ISTIO_NAMESPACE}; exit 1)
