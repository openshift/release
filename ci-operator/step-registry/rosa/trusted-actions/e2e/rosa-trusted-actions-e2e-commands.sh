#!/usr/bin/env bash
#
# Run the ROSA Trusted Actions end-to-end suite (tests/e2e) against a
# provisioned ROSA cluster, through staging backplane and staging OCM.
#
# The suite drives the server's HTTP API, so this step starts the server from
# the source under test and points the suite at it. Everything between the
# caller and the cluster then runs for real: JWT authentication, the AMS
# access review, the per-action role allowlist, the worker pipeline, backplane
# session creation and the action itself.
#
# Expects:
#   - ${SHARED_DIR}/cluster-id written by the provisioning chain
#   - ${SHARED_DIR}/e2e-fixture-* written by rosa-trusted-actions-seed-fixtures
#   - RTA service-account credentials mounted at /secrets/rta-ci
#   - Go toolchain available (from: src)
#
# Deliberately does NOT use:
#   - ${SHARED_DIR}/kubeconfig, nor any ambient KUBECONFIG
#   - ${CLUSTER_PROFILE_DIR} credentials
# Both belong to the test harness / provisioner, not to RTA. RTA holds no
# cluster access in production and must obtain it from backplane.

set -euo pipefail

export SHARED_DIR=${SHARED_DIR:-/tmp}
REPORT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
SECRETS_DIR=${SECRETS_DIR:-/secrets/rta-ci}
SERVER_LOG="${SHARED_DIR}/rta-server.log"
mkdir -p "${REPORT_DIR}"

log() { echo -e "\033[1m$(date "+%Y-%m-%dT%H:%M:%S")  ${*}\033[0m" >&2; }

# ---------------------------------------------------------------------------
# Credentials boundary
# ---------------------------------------------------------------------------
# The provisioning chain leaves a cluster-admin kubeconfig in SHARED_DIR and
# may export KUBECONFIG. The server picks KubeconfigProvider over
# BackplaneProvider whenever ROSA_TA_KUBECONFIG is set, which would bypass the
# entire path this job exists to test. Drop all three.
unset KUBECONFIG KUBECONFIG_B64 ROSA_TA_KUBECONFIG

# The suite is its own Go module, which may sit in a subdirectory of the
# repository being tested — components/trusted-actions inside rosa-boundary.
# Everything below (the build, the config file, the test package) is relative
# to it, so switch once here rather than prefixing each path.
cd "${SOURCE_DIR}" || {
	log "ERROR: SOURCE_DIR ${SOURCE_DIR} does not exist in the checkout"
	exit 1
}
log "Building from $(pwd)"

CLUSTER_ID="$(cat "${SHARED_DIR}/cluster-id")"
log "Target cluster: ${CLUSTER_ID}"

# Mirrors how the provisioning step picks a region: the lease is the region
# unless the job overrode it.
CLUSTER_REGION="${REGION:-${LEASED_RESOURCE}}"
log "Cluster region: ${CLUSTER_REGION}"

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
# Never trace through this block: these are live credentials. ci-operator
# censors mounted secret values in logs, but do not rely on it.
set +x
read_secret() {
	local f="${SECRETS_DIR}/${1}"
	[[ -r "${f}" ]] || {
		log "ERROR: missing credential file ${f}"
		exit 1
	}
	cat "${f}"
}

CLIENT_ID="$(read_secret "${CLIENT_ID_FILE}")"
CLIENT_SECRET="$(read_secret "${CLIENT_SECRET_FILE}")"
CALLER_CLIENT_ID="$(read_secret "${CALLER_CLIENT_ID_FILE}")"
CALLER_CLIENT_SECRET="$(read_secret "${CALLER_CLIENT_SECRET_FILE}")"

# One service account fills two roles today: the client RTA
# authenticates to OCM with and the client whose token it presents to backplane.
export ROSA_TA_OCM_CLIENT_ID="${CLIENT_ID}"
export ROSA_TA_OCM_CLIENT_SECRET="${CLIENT_SECRET}"
export ROSA_TA_BACKPLANE_CLIENT_ID="${CLIENT_ID}"
export ROSA_TA_BACKPLANE_CLIENT_SECRET="${CLIENT_SECRET}"

# ---------------------------------------------------------------------------
# Server configuration
# ---------------------------------------------------------------------------
export ROSA_TA_AUTH=enabled
export ROSA_TA_OCM_BASE_URL="${OCM_BASE_URL}"
export ROSA_TA_BACKPLANE_URL="${BACKPLANE_URL}"
export ROSA_TA_JWK_CERT_URL="${JWK_CERT_URL}"
# No default and no permissive mode: the server refuses to start without it,
# and the only correct value is where the cluster under test actually lives.
export ROSA_TA_AWS_ALLOWED_REGIONS="${CLUSTER_REGION}"
export DATABASE_URL="/tmp/rta-ci.db"

# Writes change the cluster's cloud infrastructure, so they stay off unless
# the job asked for them. This allowlist is the only thing between a suite
# that reads and a terminated instance.
if [[ "${ENABLE_AWS_WRITES}" == "true" ]]; then
	log "WARNING: AWS write operations are enabled (${AWS_ALLOWED_OPERATIONS})"
	export ROSA_TA_AWS_ALLOWED_OPERATIONS="${AWS_ALLOWED_OPERATIONS}"
fi

# Staging-only guards. Cheap, and they turn a misconfiguration into a failed
# job rather than traffic against production OCM or backplane.
case "${ROSA_TA_OCM_BASE_URL}" in
*stage* | *integration* | *int.*) ;;
*)
	log "ERROR: refusing to run against non-staging OCM: ${ROSA_TA_OCM_BASE_URL}"
	exit 1
	;;
esac
case "${ROSA_TA_BACKPLANE_URL}" in
https://*stage* | https://*int*) ;;
*)
	log "ERROR: refusing to run against non-staging backplane: ${ROSA_TA_BACKPLANE_URL}"
	exit 1
	;;
esac

# ---------------------------------------------------------------------------
# Caller token
# ---------------------------------------------------------------------------
# A client-credentials grant against SSO. No scope is requested by default:
# the service account's access token already carries the claims OCM and RTA
# read (email, preferred_username). SSO_SCOPE exists so a future account that
# needs one can ask without changing this step.
log "Requesting an access token for the calling identity"
token_request=(-d grant_type=client_credentials
	-d "client_id=${CALLER_CLIENT_ID}"
	-d "client_secret=${CALLER_CLIENT_SECRET}")
[[ -n "${SSO_SCOPE:-}" ]] && token_request+=(-d "scope=${SSO_SCOPE}")

token_response="$(curl -sS --fail-with-body -X POST "${SSO_TOKEN_URL}" "${token_request[@]}")" || {
	log "ERROR: the token request to ${SSO_TOKEN_URL} failed"
	exit 1
}

# Extracted without jq, which the source image does not carry. A JWT contains
# nothing that needs unescaping, so this is exact rather than merely
# convenient.
RTA_TOKEN="$(printf '%s' "${token_response}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
unset token_response
if [[ -z "${RTA_TOKEN}" ]]; then
	log "ERROR: no access_token in the SSO response"
	exit 1
fi
export RTA_TOKEN
log "Access token acquired"

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
SERVER_PID=""
cleanup() {
	if [[ -n "${SERVER_PID}" ]]; then
		kill "${SERVER_PID}" 2>/dev/null || true
		wait "${SERVER_PID}" 2>/dev/null || true
	fi
	# The suite cannot report why an execution failed — the API does not expose
	# a reason — so the server log is the only diagnosis available. Archive it
	# always, especially when the suite failed.
	if [[ -f "${SERVER_LOG}" ]]; then
		cp "${SERVER_LOG}" "${REPORT_DIR}/rta-server.log" || true
	fi
}
trap cleanup EXIT

log "Building the server"
go build -o /tmp/rosa-trusted-actions-server ./cmd/server

log "Starting the server"
# Staging backplane is not reachable directly: the request dials its address
# and times out. rosa-cluster-credentials-backplane routes through the same
# corp proxy for the same reason.
#
# Exported for the server process alone, and only as HTTPS_PROXY. Scoping it
# keeps the SSO token request, the Go module downloads and the suite's own
# localhost traffic off the proxy; leaving HTTP_PROXY unset keeps the plain
# HTTP calls to the server local.
(
	if [[ -n "${BACKPLANE_PROXY_URL}" ]]; then
		export HTTPS_PROXY="${BACKPLANE_PROXY_URL}"
		export NO_PROXY="localhost,127.0.0.1${NO_PROXY:+,${NO_PROXY}}"
		# Also as configuration, which is where backplane-cli's credential flow
		# reads its proxy from. AWS traffic needs no separate setting: awsapi
		# falls back to the backplane proxy when ROSA_TA_AWS_PROXY_URL is unset,
		# the same way backplane-cli does.
		export ROSA_TA_BACKPLANE_PROXY_URL="${BACKPLANE_PROXY_URL}"
	fi
	exec /tmp/rosa-trusted-actions-server \
		--config-file "${RTA_CONFIG_FILE}" \
		--listen-addr ":8080" \
		--log-level "${RTA_LOG_LEVEL}"
) >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!
[[ -n "${BACKPLANE_PROXY_URL}" ]] && log "Server reaching backplane through ${BACKPLANE_PROXY_URL}"

for _ in $(seq 1 60); do
	curl -sf http://localhost:8080/health >/dev/null 2>&1 && break
	kill -0 "${SERVER_PID}" 2>/dev/null || {
		log "ERROR: the server exited early; see rta-server.log in the artifacts"
		exit 1
	}
	sleep 1
done
curl -sf http://localhost:8080/health >/dev/null || {
	log "ERROR: the server never became healthy"
	exit 1
}
export RTA_BASE_URL="http://localhost:8080"
log "Server healthy at ${RTA_BASE_URL}"

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------
export E2E_CLUSTER_ID="${CLUSTER_ID}"
export E2E_FIXTURE_NAMESPACE
E2E_FIXTURE_NAMESPACE="$(cat "${SHARED_DIR}/e2e-fixture-namespace")"
export E2E_FIXTURE_CONFIGMAP
E2E_FIXTURE_CONFIGMAP="$(cat "${SHARED_DIR}/e2e-fixture-configmap")"
export E2E_FIXTURE_POD
E2E_FIXTURE_POD="$(cat "${SHARED_DIR}/e2e-fixture-pod")"

log "Installing gotestsum"
export GOFLAGS="-mod=mod"
go install gotest.tools/gotestsum@latest

TEST_ARGS=(-tags=e2e -count=1 -v -timeout "${TEST_TIMEOUT}" ./tests/e2e/...)
[[ -n "${TEST_FILTER:-}" ]] && TEST_ARGS+=(-run "${TEST_FILTER}")

log "Running the end-to-end suite against ${CLUSTER_ID}"
gotestsum \
	--junitfile="${REPORT_DIR}/junit_rosa-trusted-actions-e2e.xml" \
	--jsonfile="${REPORT_DIR}/rosa-trusted-actions-e2e.json" \
	-- "${TEST_ARGS[@]}"
