#!/bin/bash

# Proxy configuration and temporary registry credentials must never be traced.
set +x
set -euo pipefail
umask 077

# Report an unsuitable execution image before sourcing credentials or calling
# the cluster, rather than misdiagnosing a missing tool as missing route data.
for required_command in bash oc jq openssl curl timeout awk grep cmp cat mktemp mkdir rm basename tr sleep; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "ERROR: required command '${required_command}' is missing from the step image" >&2
        exit 1
    fi
done

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

workdir=$(mktemp -d)
probe_namespace=""
transfer_pid=""
# Reserve three minutes for the last API polling calls and bounded cleanup.
step_deadline=$((SECONDS + 1620))
cleanup() {
    local status=$?
    trap - EXIT
    trap '' TERM INT
    # Credentials must disappear before any potentially slow network cleanup.
    rm -rf "${workdir}" || true
    if [[ -n "${transfer_pid}" ]]; then
        # GNU timeout forwards TERM and enforces its existing kill-after bound.
        kill -TERM "${transfer_pid}" 2>/dev/null || true
    fi
    if [[ -n "${probe_namespace}" ]]; then
        # request-timeout bounds one request, not discovery or a multi-resource
        # get. Bound finalization as a whole and reserve time for deletion even
        # if diagnostics stall. These shells do not inherit the oc API helper.
        timeout --signal=TERM --kill-after=2s 40s bash -c '
            trap "" TERM INT
            namespace=$1 status=$2 artifacts=$3
            if (( status != 0 )) && [[ -n "${artifacts}" ]]; then
                timeout --signal=TERM --kill-after=2s 20s bash -c '\''
                    trap "" TERM INT
                    namespace=$1 artifacts=$2
                    mkdir -p "${artifacts}/registry-route-trust" || exit 0
                    # Only nonsecret workload diagnostics.
                    command oc --request-timeout=5s -n "${namespace}" get daemonset,pods -o json \
                        > "${artifacts}/registry-route-trust/workloads.json" 2>/dev/null || true
                    command oc --request-timeout=5s -n "${namespace}" get events -o json \
                        > "${artifacts}/registry-route-trust/events.json" 2>/dev/null || true
                '\'' bash "${namespace}" "${artifacts}" || true
            fi
            command oc --request-timeout=10s delete namespace "${namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        ' bash "${probe_namespace}" "${status}" "${ARTIFACT_DIR:-}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${transfer_pid}" ]]; then
        wait "${transfer_pid}" 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Bound individual API calls and keep credential-bearing proxy errors private.
oc() {
    local status
    if command oc --request-timeout=30s "$@" 2>"${workdir}/api.err"; then
        return 0
    else
        status=$?
    fi
    echo "Cluster API command failed (exit ${status}; raw errors withheld to protect credentials)" >&2
    return "${status}"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

oc -n openshift-image-registry get route default-route -o json > "${workdir}/route.json"
route_host=$(jq -er '.spec.host | select(type == "string" and length > 0)' "${workdir}/route.json") \
    || fail "The integrated registry default route has no hostname"
[[ "${route_host}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] \
    || fail "The integrated registry default route must have a DNS hostname"
jq -e '
    ((.spec.tls.certificate // "") == "") and
    any(.status.ingress[]?; .routerName == "default" and
        any(.conditions[]?; .type == "Admitted" and .status == "True"))
    ' "${workdir}/route.json" >/dev/null \
    || fail "The registry route must use the default router and its default ingress certificate"
ca_configmap=$(oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA.name}')
[[ -n "${ca_configmap}" ]] || fail "The preceding mirror trust step must configure additionalTrustedCA"
oc -n openshift-config get configmap "${ca_configmap}" -o json > "${workdir}/before.json"
oc -n openshift-config-managed get configmap default-ingress-cert -o json \
    | jq -er '.data["ca-bundle.crt"] | select(type == "string" and length > 0)' > "${workdir}/ingress.pem" \
    || fail "The managed default-ingress-cert bundle is missing or empty"

# Split a PEM bundle strictly: openssl x509 alone accepts a valid first
# certificate followed by malformed input. Reject stray text and incomplete
# certificates, then have openssl validate every certificate individually.
split_bundle() {
    local input=$1 prefix=$2 cert
    awk -v prefix="${prefix}" '
        { sub(/\r$/, "") }
        $0 == "-----BEGIN CERTIFICATE-----" {
            if (inside) exit 1
            inside = 1
            count++
            file = prefix count ".pem"
        }
        !inside && $0 !~ /^[[:space:]]*$/ { exit 1 }
        inside { print > file }
        $0 == "-----END CERTIFICATE-----" {
            if (!inside) exit 1
            close(file)
            inside = 0
        }
        END { if (inside || count == 0) exit 1 }
    ' "${input}" || fail "Malformed certificate bundle"
    for cert in "${prefix}"*.pem; do
        openssl x509 -in "${cert}" -noout >/dev/null || fail "Invalid certificate in bundle"
    done
}

split_bundle "${workdir}/ingress.pem" "${workdir}/ingress-"
jq -er --arg host "${route_host}" \
    '(.binaryData // {}) | has($host) | not' "${workdir}/before.json" >/dev/null \
    || fail "The route hostname already exists in binaryData"
jq -j --arg host "${route_host}" '.data[$host] // empty' "${workdir}/before.json" > "${workdir}/route.pem"

# Preserve trust already configured for this hostname too. Fingerprints avoid
# appending the same CA on reruns, even when its PEM formatting differs.
declare -A fingerprints=()
if [[ -s "${workdir}/route.pem" ]]; then
    split_bundle "${workdir}/route.pem" "${workdir}/existing-"
    for cert in "${workdir}"/existing-*.pem; do
        fingerprint=$(openssl x509 -in "${cert}" -noout -fingerprint -sha256)
        fingerprints["${fingerprint}"]=1
    done
fi
ca_count=0
: > "${workdir}/ingress-ca.pem"
for cert in "${workdir}"/ingress-*.pem; do
    if ! openssl x509 -in "${cert}" -noout -ext basicConstraints | grep 'CA:TRUE' >/dev/null; then
        continue
    fi
    ca_count=$((ca_count + 1))
    openssl x509 -in "${cert}" -outform PEM >> "${workdir}/ingress-ca.pem"
    fingerprint=$(openssl x509 -in "${cert}" -noout -fingerprint -sha256)
    if [[ -z "${fingerprints[${fingerprint}]:-}" ]]; then
        # Existing PEM need not end with a newline.
        if [[ -s "${workdir}/route.pem" ]]; then
            printf '\n' >> "${workdir}/route.pem"
        fi
        openssl x509 -in "${cert}" -outform PEM >> "${workdir}/route.pem"
        fingerprints["${fingerprint}"]=1
    fi
done
(( ca_count > 0 )) || fail "The authoritative ingress bundle contains no CA certificate"

# Verify the live client-to-router chain AND hostname before installing trust.
# Use only managed ingress CAs, not the existing route trust or system roots:
# either could otherwise hide a stale or unrelated managed ingress bundle.
# Ignore curlrc (which could disable verification), disable the default CA path,
# and do not follow redirects to a different TLS endpoint. The proxy environment
# remains active so private route DNS is resolved through the bastion.
mkdir "${workdir}/empty-ca"
if route_http_status=$(timeout --signal=TERM --kill-after=5s 40s \
    curl --disable --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    --cacert "${workdir}/ingress-ca.pem" --capath "${workdir}/empty-ca" \
    "https://${route_host}/v2/" 2>"${workdir}/route-tls.err"); then
    case "${route_http_status}" in
        200|401) ;;
        *) fail "Verified registry route TLS, but /v2/ returned unexpected HTTP status ${route_http_status}" ;;
    esac
else
    route_tls_status=$?
    # Raw errors may include a proxy URL with credentials; keep them private.
    fail "Registry route TLS verification against managed ingress CAs failed (exit ${route_tls_status}; raw errors withheld)"
fi
echo "Verified live registry route serving chain and hostname against managed ingress CAs"

# A merge patch changes just this data key. Use resourceVersion to reject
# concurrent writers instead of accidentally overwriting their changes.
jq --arg host "${route_host}" --rawfile ca "${workdir}/route.pem" \
    '{metadata: {resourceVersion: .metadata.resourceVersion}, data: {($host): $ca}}' \
    "${workdir}/before.json" > "${workdir}/patch.json"
if ! jq -e --arg host "${route_host}" --rawfile ca "${workdir}/route.pem" \
    '.data[$host] == $ca' "${workdir}/before.json" >/dev/null; then
    oc -n openshift-config patch configmap "${ca_configmap}" --type=merge --patch-file="${workdir}/patch.json" >/dev/null
fi
oc -n openshift-config get configmap "${ca_configmap}" -o json > "${workdir}/after.json"
for snapshot in before after; do
    jq -S --arg host "${route_host}" \
        '{data: ((.data // {}) | del(.[$host])), binaryData: (.binaryData // {})}' \
        "${workdir}/${snapshot}.json" > "${workdir}/${snapshot}-siblings.json"
done
cmp "${workdir}/before-siblings.json" "${workdir}/after-siblings.json" \
    || fail "Existing registry trust data changed unexpectedly"
jq -e --arg host "${route_host}" --rawfile ca "${workdir}/route.pem" \
    '.data[$host] == $ca' "${workdir}/after.json" >/dev/null \
    || fail "The registry route CA was not retained"
[[ "$(oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA.name}')" == "${ca_configmap}" ]] \
    || fail "The additionalTrustedCA reference changed unexpectedly"

echo "Integrated registry route CA merged without replacing existing registry trust"

# Seed from the job's payload CLI dependency, not a public image or an
# ImageStream that the e2e suite has not initialized yet. Source pulls go
# directly to the build farm; only target-cluster traffic uses the bastion.
source_host="${ROUTE_TRUST_CLI_IMAGE%%/*}"
[[ -n "${source_host}" && "${source_host}" != "${ROUTE_TRUST_CLI_IMAGE}" ]] \
    || fail "ROUTE_TRUST_CLI_IMAGE must be a fully qualified image pullspec"
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}${source_host}"
export no_proxy="${no_proxy:+${no_proxy},}${source_host}"

system_ca=""
for candidate in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
    if [[ -s "${candidate}" ]]; then
        system_ca="${candidate}"
        break
    fi
done
[[ -n "${system_ca}" ]] || fail "Cannot find the system CA bundle for verified image transfer"
cat "${system_ca}" > "${workdir}/registry-ca.pem"
printf '\n' >> "${workdir}/registry-ca.pem"
cat "${workdir}/route.pem" >> "${workdir}/registry-ca.pem"

oc get nodes -l 'node-role.kubernetes.io/worker,kubernetes.io/os=linux' -o json > "${workdir}/workers.json"
jq -e '.items | length > 0' "${workdir}/workers.json" >/dev/null \
    || fail "No Linux worker nodes are available for the registry pull probe"

# Arm cleanup before creating anything. All authorization is namespace-local.
probe_namespace="registry-route-trust-$(basename "${workdir}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
oc create namespace "${probe_namespace}" >/dev/null
oc -n "${probe_namespace}" create serviceaccount probe >/dev/null
for role in image-builder image-puller; do
    oc -n "${probe_namespace}" create rolebinding "probe-${role}" \
        --clusterrole="system:${role}" --serviceaccount="${probe_namespace}:probe" >/dev/null
done
oc -n "${probe_namespace}" create imagestream probe >/dev/null

# The target kubeconfig can authenticate with a client certificate and need
# not have a bearer token. Request a dedicated, short-lived SA token instead.
oc -n "${probe_namespace}" create token probe --duration=30m > "${workdir}/token"
jq -n --arg host "${route_host}" --rawfile token "${workdir}/token" \
    '{auths: {($host): {auth: ("serviceaccount:" + ($token | rtrimstr("\n")) | @base64)}}}' \
    > "${workdir}/auth.json"
oc -n "${probe_namespace}" create secret generic probe-pull \
    --type=kubernetes.io/dockerconfigjson --from-file=".dockerconfigjson=${workdir}/auth.json" >/dev/null

probe_image="${route_host}/${probe_namespace}/probe:latest"
# This flag sets registry roots, not API roots. Both source and destination
# remain TLS-verified, using system roots plus the authoritative route CA.
timeout --signal=TERM --kill-after=10s 10m \
    oc image mirror "${ROUTE_TRUST_CLI_IMAGE}" "${probe_image}" \
    --registry-config="${workdir}/auth.json" --certificate-authority="${workdir}/registry-ca.pem" \
    >/dev/null 2>"${workdir}/transfer.err" &
transfer_pid=$!
# A builtin wait is interrupted by trapped signals; a foreground external
# transfer would defer Bash's TERM/INT handler until it finished.
if wait "${transfer_pid}"; then
    transfer_pid=""
else
    transfer_status=$?
    transfer_pid=""
    echo "Verified image transfer failed (exit ${transfer_status}; raw errors withheld to protect credentials)" >&2
    exit "${transfer_status}"
fi

cat > "${workdir}/probe.yaml" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: registry-route-trust
  namespace: ${probe_namespace}
spec:
  selector:
    matchLabels:
      app: registry-route-trust
  template:
    metadata:
      labels:
        app: registry-route-trust
    spec:
      serviceAccountName: probe
      automountServiceAccountToken: false
      imagePullSecrets:
      - name: probe-pull
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: Exists
      tolerations:
      - operator: Exists
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: probe
        image: ${probe_image}
        imagePullPolicy: Always
        command: ["/bin/sh", "-c", "sleep 3600"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        resources:
          requests:
            cpu: 10m
            memory: 40Mi
EOF
oc create -f "${workdir}/probe.yaml" >/dev/null

# MCO can propagate ControllerConfig certificates without rendering a new
# MachineConfig. Prove effective trust through real authenticated CRI-O pulls
# on every Linux worker instead of requiring a rendered configuration change.
pull_deadline=$((SECONDS + 900))
if (( pull_deadline > step_deadline )); then
    pull_deadline=${step_deadline}
fi
while (( SECONDS < pull_deadline )); do
    if oc -n "${probe_namespace}" get daemonset registry-route-trust -o json > "${workdir}/daemonset.json" \
        && oc -n "${probe_namespace}" get pods -l app=registry-route-trust -o json > "${workdir}/pods.json" \
        && oc get nodes -l 'node-role.kubernetes.io/worker,kubernetes.io/os=linux' -o json > "${workdir}/workers.json"; then
        if jq -e -n --arg image "${probe_image}" --slurpfile ds "${workdir}/daemonset.json" \
            --slurpfile pods "${workdir}/pods.json" --slurpfile workers "${workdir}/workers.json" '
                $ds[0] as $d |
                ($workers[0].items | map(.metadata.name) | sort) as $expected |
                ($pods[0].items | map(select(.metadata.deletionTimestamp == null)
                    | select(any(.metadata.ownerReferences[]?;
                        .kind == "DaemonSet" and .uid == $d.metadata.uid and .controller == true))
                    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
                    | select(any(.spec.containers[]?; .name == "probe" and
                        .image == $image and .imagePullPolicy == "Always"))
                    | select(any(.status.containerStatuses[]?; .name == "probe" and
                        .ready == true and (.imageID | type == "string" and length > 0)))
                    | .spec.nodeName) | unique | sort) as $ready |
                ($expected | length) > 0 and $expected == $ready and
                $d.status.observedGeneration >= $d.metadata.generation and
                $d.status.desiredNumberScheduled == ($expected | length) and
                $d.status.numberReady == $d.status.desiredNumberScheduled and
                $d.status.updatedNumberScheduled == $d.status.desiredNumberScheduled
            ' >/dev/null; then
            echo "Verified authenticated integrated registry route pulls on every Linux worker"
            exit 0
        fi
    fi
    sleep 10
done
fail "Timed out waiting for authenticated registry route pulls on all Linux workers"
