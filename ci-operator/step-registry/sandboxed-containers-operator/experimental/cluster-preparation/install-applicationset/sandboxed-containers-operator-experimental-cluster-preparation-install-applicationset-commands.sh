#!/bin/bash
set -euo pipefail

echo "*** Applying OSC baremetal ApplicationSet..."

# Wait for ApplicationSet CRD to exist (controller is part of OpenShift GitOps)
echo "*** Waiting for ApplicationSet CRD to be established..."
oc wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=10m

echo "*** Applying ApplicationSet..."
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: osc-coco-baremetal-as
  namespace: openshift-gitops
  annotations:
    description: >
      Deploys OpenShift Sandboxed Containers on baremetal with Confidential
      Containers enabled. Installs the OSC Operator and configures Kata with
      Trustee for confidential workload support, without PeerPods. Useful for
      environments requiring workload isolation with hardware-based
      confidentiality on baremetal.

      Attention: Requires worker nodes with bare-metal or nested virtualization
      and supported confidential hardware (TDX/SNP).

spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/beraldoleal/coco-scenarios.git
        revision: main
        directories:
          - path: charts/trustee-operator
          - path: charts/trustee-config
          - path: charts/osc-operator
          - path: charts/osc-config
  template:
    metadata:
      name: '{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/beraldoleal/coco-scenarios.git
        targetRevision: main
        path: '{{.path.path}}'
        helm:
          valuesObject:
            confidential:
              enabled: true
            peerpods:
              enabled: false
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ if (hasPrefix "trustee-" .path.basename) }}trustee-operator-system{{ else if (hasPrefix "osc-" .path.basename) }}openshift-sandboxed-containers-operator{{ else if (hasPrefix "argocd-" .path.basename) }}openshift-gitops{{ else }}default{{ end }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
EOF

echo "*** ApplicationSet applied successfully."
