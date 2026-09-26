#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# The OIDC client credentials are mounted as files by the aro-hcp-ci-oidc-sa
# credential. Read them with tracing disabled so the secret never lands in the
# build log, and keep tracing off through the authenticated request.
set +o xtrace
CLIENT_ID="$(cat /var/run/aro-hcp-ci-oidc-sa/client-id)"
CLIENT_SECRET="$(cat /var/run/aro-hcp-ci-oidc-sa/client-secret)"

# JOB_SPEC is provided by prow and describes the PR (or batch) under test. Every
# input is passed explicitly; the tool reads no environment variables of its own.
test/aro-hcp-tests merge-gate \
	--url "${RELEASE_DASHBOARD_URL}" \
	--job-spec "${JOB_SPEC}" \
	--token-url "${RELEASE_DASHBOARD_TOKEN_URL}" \
	--scope "${RELEASE_DASHBOARD_SCOPE}" \
	--client-id "${CLIENT_ID}" \
	--client-secret "${CLIENT_SECRET}"
