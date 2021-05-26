#!/usr/bin/bash

set -euo pipefail

cd $(dirname $0)/..

BOOTSTRAP_BINARY=${BOOTSTRAP_BINARY:-/usr/bin/ci-secret-bootstrap}

if [[ ! -x ${BOOTSTRAP_BINARY} ]]; then
  cd ../ci-tools && go build -race=true -o ${BOOTSTRAP_BINARY} ./cmd/ci-secret-bootstrap && cd -
fi

exec ${BOOTSTRAP_BINARY} \
		--vault-addr=https://vault.ci.openshift.org \
		--vault-role=secret-bootstrap \
		--vault-prefix=kv \
		--config=core-services/ci-secret-bootstrap/_config.yaml \
		--generator-config=core-services/ci-secret-generator/_config.yaml \
		--validate-only
