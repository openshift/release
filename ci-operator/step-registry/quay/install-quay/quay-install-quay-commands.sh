#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat <<EOF | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.6.2
  creationTimestamp: null
  name: quayregistries.quay.redhat.com
spec:
  group: quay.redhat.com
  names:
    kind: QuayRegistry
    listKind: QuayRegistryList
    plural: quayregistries
    singular: quayregistry
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        description: QuayRegistry is the Schema for the quayregistries API.
        properties:
          apiVersion:
            description: 'APIVersion defines the versioned schema of this representation
              of an object. Servers should convert recognized schemas to the latest
              internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
            type: string
          kind:
            description: 'Kind is a string value representing the REST resource this
              object represents. Servers may infer this from the endpoint the client
              submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
            type: string
          metadata:
            type: object
          spec:
            description: QuayRegistrySpec defines the desired state of QuayRegistry.
            properties:
              components:
                description: Components declare how the Operator should handle backing
                  Quay services.
                items:
                  description: Component describes how the Operator should handle
                    a backing Quay service.
                  properties:
                    kind:
                      description: Kind is the unique name of this type of component.
                      type: string
                    managed:
                      description: Managed indicates whether or not the Operator is
                        responsible for the lifecycle of this component. Default is
                        true.
                      type: boolean
                  required:
                  - kind
                  - managed
                  type: object
                type: array
              configBundleSecret:
                description: ConfigBundleSecret is the name of the Kubernetes \`Secret\`
                  in the same namespace which contains the base Quay config and extra
                  certs.
                type: string
            type: object
          status:
            description: QuayRegistryStatus defines the observed state of QuayRegistry.
            properties:
              conditions:
                description: Conditions represent the conditions that a QuayRegistry
                  can have.
                items:
                  description: 'Condition is a single condition of a QuayRegistry.
                    Conditions should follow the "abnormal-true" principle in order
                    to only bring the attention of users to "broken" states. Example:
                    a condition of \`type: "Ready", status: "True"\`\` is less useful
                    and should be omitted whereas \`type: "NotReady", status: "True"\`
                    is more useful when trying to monitor when something is wrong.'
                  properties:
                    lastTransitionTime:
                      format: date-time
                      type: string
                    lastUpdateTime:
                      format: date-time
                      type: string
                    message:
                      type: string
                    reason:
                      type: string
                    status:
                      type: string
                    type:
                      type: string
                  type: object
                type: array
              configEditorCredentialsSecret:
                description: ConfigEditorCredentialsSecret is the Kubernetes \`Secret\`
                  containing the config editor password.
                type: string
              configEditorEndpoint:
                description: ConfigEditorEndpoint is the external access point for
                  a web-based reconfiguration interface for the Quay registry instance.
                type: string
              currentVersion:
                description: CurrentVersion is the actual version of Quay that is
                  actively deployed.
                type: string
              lastUpdated:
                description: LastUpdate is the timestamp when the Operator last processed
                  this instance.
                type: string
              registryEndpoint:
                description: RegistryEndpoint is the external access point for the
                  Quay registry.
                type: string
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
status:
  acceptedNames:
    kind: ""
    plural: ""
  conditions: []
  storedVersions: []
EOF

cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbType: postgres
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
EOF

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay
EOF

cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay
spec:
  components:
  - kind: clair
    managed: false
EOF

for _ in {1..60}; do
    if [[ "$(oc -n quay get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
        echo "Quay is ready"
        exit 0
    fi
    sleep 10
done
echo "Timed out waiting for Quay to become ready"
oc -n quay get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
exit 1
