#!/usr/bin/bash

set -euo pipefail

exec /usr/bin/ci-secret-bootstrap \
		--vault-addr=https://vault.ci.openshift.org \
		--vault-role=secret-bootstrap \
		--vault-prefix=kv/dptp \
		--config=core-services/ci-secret-bootstrap/_config.yaml \
		--validate-only
