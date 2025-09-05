#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig
sleep 17600
# OCP_VERSION="4.20"

PULLSPEC="$(curl -fsSl "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/${OCP_VERSION_TO_UPGRADE}.0-0.nightly/latest" | jq -r '.pullSpec')"
echo $PULLSPEC


sleep 17600

oc create -f - <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: upgrade-cluster
  namespace: default
  annotations:
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
    policy.open-cluster-management.io/standards: NIST SP 800-53
spec:
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: upgrade-cluster
        spec:
          object-templates:
            - objectDefinition:
                apiVersion: config.openshift.io/v1
                kind: ClusterVersion
                metadata:
                  name: version
                spec:
                  channel: ""
                  desiredUpdate:
                    image: $PULLSPEC
                    force: true
              complianceType: musthave
          remediationAction: enforce
          severity: high
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: policy-upgrade-checkclusteroperator-available
        spec:
          object-templates:
            - objectDefinition:
                apiVersion: config.openshift.io/v1
                kind: ClusterOperator
                status:
                  conditions:
                    - type: Available
                      status: "False"
              complianceType: mustnothave
          remediationAction: inform
          severity: low
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: policy-upgrade-checkclusteroperator-degraded
        spec:
          object-templates:
            - objectDefinition:
                apiVersion: config.openshift.io/v1
                kind: ClusterOperator
                status:
                  conditions:
                    - type: Degraded
                      status: "True"
              complianceType: mustnothave
          remediationAction: inform
          severity: low
  remediationAction: enforce
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: upgrade-cluster-placement
  namespace: default
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
    - managed-cluster-set
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: upgrade-cluster-placement
  namespace: default
placementRef:
  name: upgrade-cluster-placement
  kind: Placement
  apiGroup: cluster.open-cluster-management.io
subjects:
  - name: upgrade-cluster
    kind: Policy
    apiGroup: policy.open-cluster-management.io
EOF
