#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AAP_CONTROLLER_NAME="interop-automation-controller-instance"
PROJECT_NAMESPACE="aap"

oc apply -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
        name: ${PROJECT_NAMESPACE}
EOF

oc apply -f - <<EOF
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationController
metadata:
  name: ${AAP_CONTROLLER_NAME}
  namespace: ${PROJECT_NAMESPACE}
spec:
  postgres_keepalives_count: 5
  postgres_keepalives_idle: 5
  metrics_utility_cronjob_report_schedule: '@monthly'
  create_preload_data: true
  route_tls_termination_mechanism: Edge
  garbage_collect_secrets: false
  ingress_type: Route
  loadbalancer_port: 80
  no_log: true
  image_pull_policy: IfNotPresent
  projects_storage_size: 8Gi
  auto_upgrade: true
  task_privileged: false
  postgres_keepalives: true
  metrics_utility_enabled: false
  postgres_keepalives_interval: 5
  ipv6_disabled: false
  projects_storage_access_mode: ReadWriteMany
  metrics_utility_pvc_claim_size: 5Gi
  set_self_labels: true
  projects_persistence: false
  replicas: 3
  admin_user: admin
  loadbalancer_protocol: http
  metrics_utility_cronjob_gather_schedule: '@hourly'
EOF

x=0
taskDeploy=""
while [[ -z ${taskDeploy} && ${x} -lt 180 ]]; do
  echo "Waiting for deployments..."
  sleep 15
  taskDeploy="$(oc get deployments ${AAP_CONTROLLER_NAME}-task -n ${PROJECT_NAMESPACE} -o=jsonpath='{.metadata.name}' --ignore-not-found)"
  echo "$(oc get deployments -n ${PROJECT_NAMESPACE} --ignore-not-found)"
  echo "Task deploy: ${taskDeploy}"
  x=$(( ${x} + 1 ))
done
echo "Task Deployment found."

x=0
webDeploy=""
while [[ -z ${webDeploy} && ${x} -lt 180 ]]; do
  echo "Waiting for deployments..."
  sleep 15
  webDeploy="$(oc get deployments ${AAP_CONTROLLER_NAME}-web -n ${PROJECT_NAMESPACE} -o=jsonpath='{.metadata.name}' --ignore-not-found)"
  echo "$(oc get deployments -n ${PROJECT_NAMESPACE} --ignore-not-found)"
  echo "Web Deploy: ${webDeploy}"
  x=$(( ${x} + 1 ))
done
echo "Web Deployment found."

oc wait --for=condition=Available deployment/${AAP_CONTROLLER_NAME}-task -n ${PROJECT_NAMESPACE} --timeout=-1s
oc wait --for=condition=Available deployment/${AAP_CONTROLLER_NAME}-web -n ${PROJECT_NAMESPACE} --timeout=-1s
echo "Deployments found and available."