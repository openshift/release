#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AAP_CONTROLLER_NAME=${AAP_CONTROLLER_NAME:-'interop-automation-controller-instance'}
PROJECT_NAMESPACE=${PROJECT_NAMESPACE:-'aap'}

echo "Creating ${PROJECT_NAMESPACE} namespace..."
oc apply -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
        name: "${PROJECT_NAMESPACE}"
EOF

echo "Provisioning Ansible Automation Controller for Interop testing..."
oc apply -f - <<EOF
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationController
metadata:
  name: ${AAP_CONTROLLER_NAME}
  namespace: ${PROJECT_NAMESPACE}
spec:
  admin_user: admin
  auto_upgrade: true
  create_preload_data: true
  garbage_collect_secrets: false
  image_pull_policy: IfNotPresent
  ingress_type: Route
  ipv6_disabled: false
  loadbalancer_ip: ""
  loadbalancer_port: 80
  loadbalancer_protocol: http
  no_log: true
  postgres_keepalives: true
  postgres_keepalives_count: 5
  postgres_keepalives_idle: 5
  postgres_keepalives_interval: 5
  projects_persistence: false
  projects_storage_access_mode: ReadWriteMany
  projects_storage_size: 8Gi
  replicas: 1
  route_tls_termination_mechanism: Edge
  set_self_labels: true
  task_privileged: false
EOF

# Wait for operator readiness 15 minutes or fail

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