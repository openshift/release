#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# create the policies namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: policies
EOF

#THis is for ACS and QUAY
#oc scale --replicas=7 machineset "$(oc get machineset -n  openshift-machine-api -o jsonpath='{.items[0].metadata.name}')" -n openshift-machine-api

# cd to writeable directory
cd /tmp/

git clone https://github.com/stolostron/policy-collection.git

# apply the configure subscription admin policy
oc apply -f - <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-configure-subscription-admin-hub
  namespace: policies
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: policy-configure-subscription-admin-hub
        spec:
          remediationAction: enforce
          severity: low
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: rbac.authorization.k8s.io/v1
                kind: ClusterRole
                metadata:
                  name: open-cluster-management:subscription-admin
                rules:
                - apiGroups:
                  - app.k8s.io
                  resources:
                  - applications
                  verbs:
                  - '*'
                - apiGroups:
                  - apps.open-cluster-management.io
                  resources:
                  - '*'
                  verbs:
                  - '*'
                - apiGroups:
                  - ""
                  resources:
                  - configmaps
                  - secrets
                  - namespaces
                  verbs:
                  - '*'
            - complianceType: musthave
              objectDefinition:
                apiVersion: rbac.authorization.k8s.io/v1
                kind: ClusterRoleBinding
                metadata:
                  name: open-cluster-management:subscription-admin
                roleRef:
                  apiGroup: rbac.authorization.k8s.io
                  kind: ClusterRole
                  name: open-cluster-management:subscription-admin
                subjects:
                - apiGroup: rbac.authorization.k8s.io
                  kind: User
                  name: kube:admin
                - apiGroup: rbac.authorization.k8s.io
                  kind: User
                  name: system:admin
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: binding-policy-configure-subscription-admin-hub
  namespace: policies
placementRef:
  name: placement-policy-configure-subscription-admin-hub
  kind: PlacementRule
  apiGroup: apps.open-cluster-management.io
subjects:
- name: policy-configure-subscription-admin-hub
  kind: Policy
  apiGroup: policy.open-cluster-management.io
---
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: placement-policy-configure-subscription-admin-hub
  namespace: policies
spec:
  clusterConditions:
  - status: "True"
    type: ManagedClusterConditionAvailable
  clusterSelector:
    matchExpressions:
      - {key: name, operator: In, values: ["local-cluster"]}
EOF

# apply managedclusterset binding
oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: policies
spec:
  clusterSet: default
EOF

sleep 60

cd policy-collection/deploy/ 
echo 'y' | ./deploy.sh -p 2.7/policy-sets/openshift-plus-setup -n policies -u https://github.com/gparvin/grc-demo.git -a openshift-plus-setup

sleep 60

echo $(oc get policies -n policies)

# wait for storage nodes to be ready
RETRIES=60
for i in $(seq "${RETRIES}"); do
  if [[ $(oc get nodes -l cluster.ocs.openshift.io/openshift-storage= | grep Ready) ]]; then
    echo "storage worker nodes are up is Running"
    break
  else
    echo "Try ${i}/${RETRIES}: Storage nodes are not ready yet. Checking again in 30 seconds"
    sleep 30
  fi
done
