#!/bin/bash
set -euo pipefail

DIR=$(realpath "$(dirname "${BASH_SOURCE}")/..")
readonly DIR

JOB_FILE_PATH=${DIR}/ci-operator/jobs/infra-origin-release-images.yaml


echo "#Do NOT Modify: Generate BY hack/generate-periodic-build-origin-release-image-jobs.sh" > "${JOB_FILE_PATH}"
echo "periodics:" >> "${JOB_FILE_PATH}"

JOB='- agent: kubernetes
  cluster: build01
  cron: 0 1 * * 1
  decorate: true
  decoration_config:
    skip_cloning: true
  labels:
    ci.openshift.io/role: infra
  max_concurrency: 1
  name: periodic-build-origin-release-image-BUILD
  spec:
    containers:
    - args:
      - --namespace=ci
      - start-build
      - BUILD
      - --wait=true
      command:
      - oc
      image: registry.ci.openshift.org/ocp/4.7:cli
      imagePullPolicy: Always
      name: ""
      resources:
        requests:
          cpu: 500m
    serviceAccountName: origin-release-images-builder
'

oc --context build01 get bc -n ci -l app=origin-release -o custom-columns=":metadata.name" --no-headers | while read bc;
do 
  echo -n "${JOB}" | sed "s/BUILD/${bc}/g" >> "${JOB_FILE_PATH}"
done
