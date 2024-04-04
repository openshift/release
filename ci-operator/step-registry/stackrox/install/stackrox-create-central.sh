#!/usr/bin/env bash

set +ve

kubectl -n stackrox delete persistentvolumeclaims stackrox-db || true

kubectl apply -n stackrox -f https://raw.githubusercontent.com/stackrox/stackrox/3dd9095d844f359d842af5950b433e628e5bc6ad/operator/tests/common/central-cr.yaml

kubectl -n stackrox exec deploy/central -- \
  roxctl central init-bundles generate my-test-bundle --insecure-skip-tls-verify --password letmein --output-secrets - \
  | kubectl -n stackrox apply -f -

kubectl get -n stackrox centrals.platform.stackrox.io
kubectl get -n stackrox centrals.platform.stackrox.io stackrox-central-services --output=json

