#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Get the apps URL
URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
APPS_URL=${URL#"console-openshift-console."}

echo "export APPS_URL=${APPS_URL}" >> ${SHARED_DIR}/env.sh

chmod +x ${SHARED_DIR}/env.sh



# console_route=$(oc get route -n openshift-console console -o yaml)
# echo "CONSOLE ROUTE"
# echo $console_route



# MTA operator installed and Windup deployed.
# DEBUGGING...

# CONSOLE ROUTE
# apiVersion: route.openshift.io/v1 kind: Route metadata: creationTimestamp: "2022-11-19T20:28:15Z" labels: app: console name: console namespace: openshift-console resourceVersion: "20247" uid: 3a43fdde-7dc1-4d79-a6f3-c005930fa0a2 spec: host: console-openshift-console.apps.ci-op-0cw42cd9-d7155.aws.interop.ccitredhat.com port: targetPort: https tls: insecureEdgeTerminationPolicy: Redirect termination: reencrypt to: kind: Service name: console weight: 100 wildcardPolicy: None status: ingress: - conditions: - lastTransitionTime: "2022-11-19T20:28:15Z" status: "True" type: Admitted host: console-openshift-console.apps.ci-op-0cw42cd9-d7155.aws.interop.ccitredhat.com routerCanonicalHostname: router-default.apps.ci-op-0cw42cd9-d7155.aws.interop.ccitredhat.com routerName: default wildcardPolicy: None

# PWD
# /

# ENVIRONMENT VARIABLES
# ARTIFACT_DIR=/logs/artifacts BUILD_ID=1594059884851105792 BUILD_LOGLEVEL=0 BUILD_RELEASE=202211032036.p0.g7e8a010.assembly.stream BUILD_VERSION=v4.12.0 CI=true CLUSTER_PROFILE_DIR=/var/run/secrets/ci.openshift.io/cluster-profile CLUSTER_TYPE=aws ENTRYPOINT_OPTIONS={"timeout":7200000000000,"grace_period":15000000000,"artifact_dir":"/logs/artifacts","args":["/bin/bash","-c","#!/bin/bash\nset -eu\n#!/bin/bash\n\nset -o nounset\nset -o errexit\nset -o pipefail\n\n# Deploy windup\n# oc apply -f - \u003c\u003cEOF\n# apiVersion: windup.jboss.org/v1\n# kind: Windup\n# metadata:\n# name: mta\n# namespace: mta\n# spec:\n# mta_Volume_Cpacity: \"5Gi\"\n# volumeCapacity: \"5Gi\"\n# EOF\n\n\necho \"MTA operator installed and Windup deployed.\"\n\necho \"DEBUGGING...\"\n\nconsole_route=$(oc get route -n openshift-console console -o yaml)\necho \"CONSOLE ROUTE\"\necho $console_route\n\npwd=$(pwd)\necho \"PWD\"\necho $pwd\n\nenv=$(env | sort)\necho \"ENVIRONMENT VARIABLES\"\necho $env\n\nhostname=$(hostname)\necho \"HOSTNA...

# HOSTNAME
# deploy-mta-mta-prepare

# USER
# 1003610000