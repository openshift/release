#!/bin/bash
set -euo pipefail

# Clear GOFLAGS so `make deploy`'s controller-gen/kustomize `go install` is not
# blocked by the builder image's `-mod=vendor` default.
export GOFLAGS=''

# The Makefile deploy target invokes `kubectl`, but the `cli: latest` image only
# ships `oc`. Make `kubectl` resolve to `oc` (a functional superset).
mkdir -p "${HOME}/bin"
ln -sf "$(command -v oc)" "${HOME}/bin/kubectl"
export PATH="${HOME}/bin:${PATH}"

make deploy IMG="${OPERATOR_IMAGE}" MCPLO_OPERAND_IMAGE="${MCPLO_OPERAND_IMAGE}"

oc -n "${OPERATOR_NAMESPACE}" wait --for=condition=Available \
  deployment --all --timeout=5m
