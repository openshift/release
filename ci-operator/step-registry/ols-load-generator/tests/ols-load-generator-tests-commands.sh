#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

# shellcheck disable=SC2153
IFS=',' read -ra test_durations <<< "$OLS_TEST_DURATIONS"

for OLS_TEST_DURATION in "${test_durations[@]}"; do
  # Create namespace and set monitoring labels
  oc create namespace openshift-lightspeed || true
  oc label namespaces openshift-lightspeed openshift.io/cluster-monitoring=true --overwrite=true

  # Deploy fake secret
  oc create secret generic fake-secret \
    --from-literal=apitoken="fake-api-key" \
    -n openshift-lightspeed

  # Get the controller manager running
  git clone https://github.com/openshift/lightspeed-operator.git --branch main --depth 1 || true
  pushd lightspeed-operator
  make deploy
  oc wait --for=condition=Available -n openshift-lightspeed deployment lightspeed-operator-controller-manager --timeout=300s
  popd

  # Deploy olsconfig with fake values
  cat <<EOF | oc apply -f - -n openshift-lightspeed
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
  namespace: openshift-lightspeed
spec:
  llm:
    providers:
    - credentialsSecretRef:
        name: fake-secret
      models:
      - name: fake_model
      name: fake_provider
      type: fake_provider
  ols:
    defaultModel: fake_model
    defaultProvider: fake_provider
    enableDeveloperUI: false
    logLevel: INFO
    deployment:
      replicas: 1
EOF

  # Wait for the app server deployment
  oc wait --for=condition=Available -n openshift-lightspeed deployment lightspeed-app-server --timeout=300s

  # Deploy service monitor for application metrics
  cat <<EOF | oc apply -f - -n openshift-lightspeed
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ols-service-monitor
  namespace: openshift-lightspeed
  labels:
    app: ols
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: application-server
      app.kubernetes.io/managed-by: lightspeed-operator
      app.kubernetes.io/name: lightspeed-service-api
  endpoints:
  - port: "8443"
    path: /metrics
    interval: 30s
EOF

  # Wait before the test
  sleep 30

  # Create a separate namespace for load testing
  oc create namespace ols-load-test || true
  oc create secret generic kubeconfig-secret --from-file=kubeconfig=${KUBECONFIG} -n ols-load-test

  # Trigger the load test
  OLS_TEST_AUTH_TOKEN=$(oc whoami -t)
  cat <<EOF | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ols-load-generator-serviceaccount
  namespace: ols-load-test
rules:
- apiGroups: ["extensions", "apps", "batch", "security.openshift.io", "policy"]
  resources: ["deployments", "jobs", "pods", "services", "jobs/status", "podsecuritypolicies", "securitycontextconstraints"]
  verbs: ["use", "get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ols-load-generator-role
  namespace: ols-load-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ols-load-generator-serviceaccount
subjects:
- kind: ServiceAccount
  name: default
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ols-load-generator-orchestrator
  namespace: ols-load-test
  labels:
    ols-load-generator-component: orchestrator
spec:
  template:
    spec:
      containers:
      - name: ols-load-generator
        image: quay.io/vchalla/ols-load-generator:amd64
        securityContext:
          privileged: true
          env:
            - name: OLS_TEST_HOST
              value: "https://lightspeed-app-server.openshift-lightspeed.svc.cluster.local:8443"
            - name: OLS_TEST_AUTH_TOKEN
              value: "${OLS_TEST_AUTH_TOKEN}"
            - name: OLS_TEST_DURATION
              value: "${OLS_TEST_DURATION}"
            - name: OLS_TEST_WORKERS
              value: "${OLS_TEST_WORKERS}"
            - name: OLS_TEST_PROFILES
              value: "${OLS_TEST_PROFILES}"
            - name: KUBECONFIG
              value: /etc/kubeconfig/kubeconfig
            - name: OLS_TEST_METRIC_STEP
              value: "${OLS_TEST_METRIC_STEP}"
            - name: OLS_TEST_ES_HOST
              value: 'https://${ES_USERNAME}:${ES_PASSWORD}@search-perfscale-pro-wxrjvmobqs7gsyi3xvxkqmn7am.us-west-2.es.amazonaws.com'
            - name: OLS_TEST_ES_INDEX
              value: "${OLS_TEST_ES_INDEX}"
            - name: OLS_QUERY_ONLY
              value: "${OLS_QUERY_ONLY}"
          volumeMounts:
            - name: kubeconfig-volume
              mountPath: /etc/kubeconfig
              readOnly: true
          resources:
            requests:
              cpu: "1"
              memory: "512Mi"
          imagePullPolicy: Always
        restartPolicy: Never
        volumes:
          - name: kubeconfig-volume
            secret:
              secretName: kubeconfig-secret
    backoffLimit: 0
EOF

  # Wait for job completion
  oc wait --for=condition=complete job/ols-load-generator-orchestrator -n ols-load-test --timeout=600s

  # Delete load testing namespace
  oc delete namespace ols-load-test
  oc wait --for=delete ns/ols-load-test --timeout=300s

  pushd lightspeed-operator
  make undeploy
  popd

  sleep 300
done

popd
