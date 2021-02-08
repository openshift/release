#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Run in the openshift namespace, to get access to the default ImageStreams.
# https://docs.openshift.com/container-platform/4.6/openshift_images/using-imagestreams-with-kube-resources.html#images-managing-images-enabling-imagestreams-kube_using-imagestreams-with-kube-resources
#cat >> "${SHARED_DIR}/manifest_workload-ns.yml" << EOF
#apiVersion: v1
#kind: Namespace
#metadata:
#  name: synthetic-workload
#EOF

cat >> "${SHARED_DIR}/manifest_loki-ss.yml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: synthetic-workload
  namespace: openshift
  annotations:
    alpha.image.policy.openshift.io/resolve-names: '*'
  selector:
    matchLabels:
      app: work
spec:
  replicas: 40  # this seems like it will be difficult to tune.  We want decent load on all of our update jobs, but no value will do that for 3-compute clusters while also working for compact, 0-compute clusters.
  template:
    metadata:
      labels:
        app: work
    spec:
      containers:
      - name: work
        image: openshift/cli:latest
        command:
        - "/bin/bash"
        - "-c"
        - 'i=1; while true; do if [[ "\$i" -gt 1 ]]; then i="\$((i-1))"; else i="\$((i+1))"; fi; done'
        resources:
          requests:  # FIXME: tune these to somewhat match reality
            cpu: 100m
            memory: 20Mi
      terminationGracePeriodSeconds: 600
EOF
