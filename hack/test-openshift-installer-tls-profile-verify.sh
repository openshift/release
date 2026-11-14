#!/bin/bash
# Run locally with: bash hack/test-openshift-installer-tls-profile-verify.sh
#
# Offline tests for the ipi-conf tlsProfileType input and the
# openshift-installer-tls-profile-verify step. Requires bash, jq and openssl.
# Cluster endpoints are emulated with local openssl s_server instances and the
# oc CLI is replaced by a mock, so no cluster or network access is needed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
verify_script="${root}/ci-operator/step-registry/openshift/installer/tls-profile/verify/openshift-installer-tls-profile-verify-commands.sh"
ipi_conf_script="${root}/ci-operator/step-registry/ipi/conf/ipi-conf-commands.sh"
test_dir="$(mktemp -d)"
server_pids=()
failures=0

# Named so that sourcing the step script, which defines cleanup(), does not
# replace the function this trap runs.
cleanup_test() {
    local pid
    for pid in "${server_pids[@]+"${server_pids[@]}"}"; do
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    rm -rf "${test_dir}"
}
trap cleanup_test EXIT

for tool in jq openssl; do
    command -v "${tool}" >/dev/null || { echo "FAIL: ${tool} is required" >&2; exit 1; }
done

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# Load the step functions without running the checks.
# shellcheck source=/dev/null
TLS_PROFILE_VERIFY_LIBRARY_ONLY=true source "${verify_script}"
set +o errexit

# --- Expected handshake results -----------------------------------------------
# Independent table of the results the step must expect, derived from
# openshift/api TLSProfiles and the component implementations: kube-apiserver
# keeps the profile minimum, etcd raises anything below TLS 1.2 to TLS 1.2, and
# only Old lists the ECDHE AES128-SHA (CBC) cipher suites. A version below the
# component minimum is refused for the protocol version before ciphers count.
# Probe order: tls13 tls12-aead tls12-cbc tls11-cbc tls10-cbc.
declare -A expected_table=(
    [kube-apiserver:Modern]="accept reject-protocol reject-protocol reject-protocol reject-protocol"
    [kube-apiserver:Intermediate]="accept accept reject-cipher reject-protocol reject-protocol"
    [kube-apiserver:Old]="accept accept accept accept accept"
    [etcd:Modern]="accept reject-protocol reject-protocol reject-protocol reject-protocol"
    [etcd:Intermediate]="accept accept reject-cipher reject-protocol reject-protocol"
    [etcd:Old]="accept accept accept reject-protocol reject-protocol"
)
for key in "${!expected_table[@]}"; do
    component="${key%%:*}"
    profile="${key##*:}"
    actual=""
    for probe in "${PROBES[@]}"; do
        actual+="$(expected_probe_result "${component}" "${profile}" "${probe}") "
    done
    if [[ "${actual% }" == "${expected_table[${key}]}" ]]; then
        pass "expectations for ${component} ${profile}"
    else
        fail "expectations for ${component} ${profile}: got '${actual% }', want '${expected_table[${key}]}'"
    fi
done
for case in "Old VersionTLS11" "Intermediate VersionTLS12" "Modern VersionTLS13"; do
    read -r profile want <<<"${case}"
    got="$(component_min_version ingress "${profile}")"
    if [[ "${got}" == "${want}" ]]; then
        pass "ingress minimum for ${profile}"
    else
        fail "ingress minimum for ${profile}: got ${got}, want ${want}"
    fi
done
if [[ "$(profile_ciphers Old | wc -l)" -eq 24 && "$(profile_ciphers Intermediate | wc -l)" -eq 9 && "$(profile_ciphers Modern | wc -l)" -eq 3 ]]; then
    pass "profile cipher list sizes match openshift/api"
else
    fail "profile cipher list sizes do not match openshift/api"
fi

# --- Classification of recorded s_client output ---------------------------------
# Excerpts recorded from OpenSSL 1.1.1k and 3.2.6 clients.
classify_case() {
    local name="$1" label="$2" rc="$3" want="$4" text="$5" got
    printf '%s\n' "${text}" >"${test_dir}/classify.out"
    got="$(classify_handshake "${label}" "${test_dir}/classify.out" "${rc}")"
    if [[ "${got}" == "${want}" ]]; then
        pass "classify ${name}"
    else
        fail "classify ${name}: got ${got}, want ${want}"
    fi
}
classify_case "TLS 1.2 handshake completed" 1.2 0 ACCEPTED \
'CONNECTED(00000003)
<<< TLS 1.2, Handshake [length 0041], ServerHello
<<< TLS 1.2, Handshake [length 0004], ServerHelloDone
New, TLSv1.2, Cipher is ECDHE-RSA-AES128-GCM-SHA256
    Protocol  : TLSv1.2'
classify_case "TLS 1.3 client certificate required after handshake" 1.3 1 ACCEPTED \
'<<< TLS 1.3, Handshake [length 007a], ServerHello
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
133386600306496:error:1409445C:SSL routines:ssl3_read_bytes:tlsv13 alert certificate required:ssl/record/rec_layer_s3.c:1544:SSL alert number 116'
classify_case "TLS 1.2 client certificate refused after ServerHello" 1.2 1 ACCEPTED \
'<<< TLS 1.2, Handshake [length 0041], ServerHello
<<< TLS 1.2, Handshake [length 0004], ServerHelloDone
40176431DD790000:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert handshake failure:ssl/record/rec_layer_s3.c:914:SSL alert number 40
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384'
classify_case "TLS 1.0 accepted, client rejects the server signature" 1.0 1 ACCEPTED \
'<<< TLS 1.0, Handshake [length 0045], ServerHello
>>> TLS 1.0, Alert [length 0002], fatal internal_error
40D7343AC27C0000:error:03000098:digital envelope routines:do_sigver_init:invalid digest:crypto/evp/m_sigver.c:342:'
classify_case "protocol version alert" 1.2 1 REJECTED_PROTOCOL \
'CONNECTED(00000003)
40474ED0107D0000:error:0A00042E:SSL routines:ssl3_read_bytes:tlsv1 alert protocol version:ssl/record/rec_layer_s3.c:914:SSL alert number 70
New, (NONE), Cipher is (NONE)
    Protocol  : TLSv1.2'
classify_case "no shared cipher" 1.2 1 REJECTED_CIPHER \
'138778762794816:error:14094410:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure:ssl/record/rec_layer_s3.c:1544:SSL alert number 40
New, (NONE), Cipher is (NONE)'
classify_case "insufficient security" 1.2 1 REJECTED_CIPHER \
'40E7:error:0A000447:SSL routines:ssl3_read_bytes:tlsv1 alert insufficient security:ssl/record/rec_layer_s3.c:914:SSL alert number 71'
classify_case "connection refused" 1.2 1 CONNECT_ERROR \
'4077A3DE8F7B0000:error:8000006F:system library:BIO_connect:Connection refused:crypto/bio/bio_sock2.c:178:calling connect()
connect:errno=111'
classify_case "timeout" 1.2 124 CONNECT_ERROR 'CONNECTED(00000003)'
classify_case "client cannot offer the protocol" 1.0 1 CLIENT_ERROR \
'40F7:error:0A0000BF:SSL routines:tls_setup_handshake:no protocols available:ssl/statem/statem_lib.c:153:'
classify_case "client cannot offer the cipher" 1.2 1 CLIENT_ERROR \
'40B72B322B7D0000:error:0A0000B9:SSL routines:SSL_CTX_set_cipher_list:no cipher match:ssl/ssl_lib.c:3332:'
classify_case "connection closed without an alert" 1.2 1 INCONCLUSIVE \
'CONNECTED(00000003)
write:errno=104
New, (NONE), Cipher is (NONE)'
classify_case "ServerHello for a version that was not offered" 1.3 1 INCONCLUSIVE \
'<<< TLS 1.2, Handshake [length 0041], ServerHello'
classify_case "unrelated alert" 1.2 1 INCONCLUSIVE \
'40E7:error:0A000438:SSL routines:ssl3_read_bytes:tlsv1 alert internal error:ssl/record/rec_layer_s3.c:914:SSL alert number 80'

# --- Probe client self-test against local servers -----------------------------
WORK_DIR="${test_dir}/self-test"
mkdir -p "${WORK_DIR}"
write_probe_openssl_conf
if self_test_probe_client >"${test_dir}/self-test.log" 2>&1; then
    pass "probe client self-test ($(openssl version))"
else
    fail "probe client self-test"
    cat "${test_dir}/self-test.log" >&2
fi
for pid in "${BACKGROUND_PIDS[@]+"${BACKGROUND_PIDS[@]}"}"; do
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
done
BACKGROUND_PIDS=()

# --- ipi-conf writes tlsProfileType -------------------------------------------
run_ipi_conf() {
    local value="$1" out_dir="$2"
    mkdir -p "${out_dir}/profile" "${out_dir}/shared"
    echo "ssh-rsa AAAATEST test" >"${out_dir}/profile/ssh-publickey"
    echo '{"auths":{}}' >"${out_dir}/profile/pull-secret"
    env NAMESPACE=ci-op-test UNIQUE_HASH=abcde RELEASE_IMAGE_LATEST=example.invalid/release:latest \
        CLUSTER_PROFILE_DIR="${out_dir}/profile" SHARED_DIR="${out_dir}/shared" \
        FIPS_ENABLED=false OS_IMAGE_STREAM="" BASELINE_CAPABILITY_SET="" ADDITIONAL_ENABLED_CAPABILITIES="" \
        PUBLISH="" FEATURE_SET="" FEATURE_GATES="" INSTALL_CONFIG_TLS_PROFILE_TYPE="${value}" \
        bash "${ipi_conf_script}" >"${out_dir}/ipi-conf.log" 2>&1
}
for profile in Modern Intermediate Old; do
    if run_ipi_conf "${profile}" "${test_dir}/ipi-conf-${profile}" \
        && [[ "$(grep -c '^tlsProfileType: '"${profile}"'$' "${test_dir}/ipi-conf-${profile}/shared/install-config.yaml")" == "1" ]]; then
        pass "ipi-conf writes tlsProfileType ${profile}"
    else
        fail "ipi-conf writes tlsProfileType ${profile}"
    fi
done
if run_ipi_conf "" "${test_dir}/ipi-conf-unset" && ! grep -q 'tlsProfileType' "${test_dir}/ipi-conf-unset/shared/install-config.yaml"; then
    pass "ipi-conf leaves tlsProfileType unset by default"
else
    fail "ipi-conf leaves tlsProfileType unset by default"
fi
if ! run_ipi_conf "Custom" "${test_dir}/ipi-conf-invalid"; then
    pass "ipi-conf rejects an unsupported tlsProfileType"
else
    fail "ipi-conf rejects an unsupported tlsProfileType"
fi

# --- End-to-end runs against emulated endpoints ---------------------------------
make_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/OU=openshift/CN=$1" \
        -keyout "${test_dir}/$1.key" -out "${test_dir}/$1.crt" >/dev/null 2>&1
}
make_cert kube-apiserver-lb-signer
make_cert etcd-signer
server_conf="${test_dir}/server-openssl.cnf"
cp "${WORK_DIR}/openssl-probe.cnf" "${server_conf}"

intermediate_ciphers="$(profile_ciphers Intermediate | grep -v '^TLS_' | paste -sd: -)"
# openssl s_server options emulating each component configured with a profile.
declare -A server_options=(
    [kube-apiserver:Old]="-cipher ALL:@SECLEVEL=0"
    [kube-apiserver:Intermediate]="-no_tls1 -no_tls1_1 -cipher ${intermediate_ciphers}"
    [kube-apiserver:Modern]="-tls1_3"
    [etcd:Old]="-no_tls1 -no_tls1_1 -cipher ALL:@SECLEVEL=0 -Verify 1"
    [etcd:Intermediate]="-no_tls1 -no_tls1_1 -cipher ${intermediate_ciphers} -Verify 1"
    [etcd:Modern]="-tls1_3 -Verify 1"
    [regression:kube-apiserver-min-tls12-all-ciphers]="-no_tls1 -no_tls1_1 -cipher ALL:@SECLEVEL=0"
    [regression:etcd-accepts-tls10]="-cipher ALL:@SECLEVEL=0 -Verify 1"
    [regression:kube-apiserver-min-tls10-intermediate-ciphers]="-cipher ${intermediate_ciphers}"
)

# Starts an emulated endpoint and prints its port.
start_endpoint() {
    local cert="$1" options="$2" port pid i attempt
    for ((attempt = 0; attempt < 10; attempt++)); do
        port=$((20000 + RANDOM % 40000))
        # shellcheck disable=SC2086
        OPENSSL_CONF="${server_conf}" openssl s_server -accept "127.0.0.1:${port}" -www \
            -cert "${test_dir}/${cert}.crt" -key "${test_dir}/${cert}.key" ${options} \
            >"${test_dir}/endpoint-${port}.log" 2>&1 &
        pid=$!
        for ((i = 0; i < 50; i++)); do
            if grep -q '^ACCEPT' "${test_dir}/endpoint-${port}.log"; then
                server_pids+=("${pid}")
                echo "${port}"
                return 0
            fi
            kill -0 "${pid}" 2>/dev/null || break
            sleep 0.1
        done
        kill "${pid}" 2>/dev/null || true
    done
    return 1
}

mock_bin="${test_dir}/bin"
mkdir -p "${mock_bin}"
cat >"${mock_bin}/oc" <<'MOCK'
#!/bin/bash
# Mock oc for the TLS profile verify step; state lives in ${MOCK_DIR}.
args="$*"
case "${args}" in
    "adm wait-for-stable-cluster"*) exit 0 ;;
    "get apiserver.config.openshift.io cluster -o json") cat "${MOCK_DIR}/apiserver.json" ;;
    "get featuregate cluster -o json") echo '{"status":{"featureGates":[]}}' ;;
    "get ingresscontroller.operator.openshift.io default -n openshift-ingress-operator -o json") cat "${MOCK_DIR}/ingress.json" ;;
    "get kubeapiserver.operator.openshift.io cluster -o json"|"get etcd.operator.openshift.io cluster -o json")
        echo '{"spec":{"observedConfig":{"servingInfo":{"minTLSVersion":"VersionTLS12","cipherSuites":["TLS_AES_128_GCM_SHA256"],"namedCertificates":[{"names":["api.private.example.invalid"],"certFile":"/etc/tls.crt"}]}}}}'
        ;;
    "whoami --show-server") echo "https://localhost:$(cat "${MOCK_DIR}/external-port")" ;;
    "get nodes -l node-role.kubernetes.io/control-plane -o name") printf 'node/master-0\nnode/master-1\n' ;;
    "get pods -n openshift-kube-apiserver -l apiserver=true -o json") cat "${MOCK_DIR}/kube-apiserver-pods.json" ;;
    "get pods -n openshift-etcd -l app=etcd,etcd=true -o json") cat "${MOCK_DIR}/etcd-pods.json" ;;
    "-n "*" port-forward pod/"*)
        pod="${4#pod/}"
        remote="${5#:}"
        port="$(cat "${MOCK_DIR}/forward-${pod}" 2>/dev/null)" || { echo "error: pod ${pod} not found" >&2; exit 1; }
        echo "Forwarding from 127.0.0.1:${port} -> ${remote}"
        echo "Forwarding from [::1]:${port} -> ${remote}"
        # Emulates client-go ending the port-forward after a failed connection.
        if [[ -f "${MOCK_DIR}/exit-once-${pod}" ]]; then
            rm -f "${MOCK_DIR}/exit-once-${pod}"
            echo "error: lost connection to pod" >&2
            exit 1
        fi
        exec sleep 600
        ;;
    *) echo "mock oc: unexpected arguments: ${args}" >&2; exit 2 ;;
esac
MOCK
chmod +x "${mock_bin}/oc"

pods_json() {
    local ready="$1"
    shift
    local pod items=()
    for pod in "$@"; do
        items+=("{\"metadata\":{\"name\":\"${pod}\"},\"status\":{\"phase\":\"Running\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"${ready}\"}]}}")
    done
    local IFS=,
    echo "{\"items\":[${items[*]}]}"
}

# Runs the step against emulated endpoints.
#   $1 scenario name  $2 profile  $3 expected exit (0 or 1)
#   $4 kube-apiserver server options key  $5 etcd server options key
#   $6 optional modifier: no-adherence, no-install-config, naive-ingress,
#      explicit-ingress-profile, etcd-unreachable, etcd-wrong-certificate,
#      etcd-not-ready, port-forward-exits
#   $7 optional text the summary must contain
run_scenario() {
    local name="$1" profile="$2" want_rc="$3" kas_key="$4" etcd_key="$5" modifier="${6:-}" must_contain="${7:-}"
    local dir="${test_dir}/scenario-${name}" rc etcd_cert=etcd-signer pod ingress_min
    mkdir -p "${dir}/mock" "${dir}/shared" "${dir}/artifacts"
    export MOCK_DIR="${dir}/mock"

    if [[ "${modifier}" != "no-install-config" ]]; then
        cp "${test_dir}/ipi-conf-${profile}/shared/install-config.yaml" "${dir}/shared/install-config.yaml"
    else
        cp "${test_dir}/ipi-conf-unset/shared/install-config.yaml" "${dir}/shared/install-config.yaml"
    fi
    if [[ "${modifier}" == "no-adherence" ]]; then
        jq -n --arg t "${profile}" '{spec:{tlsSecurityProfile:{type:$t}}}' >"${MOCK_DIR}/apiserver.json"
    else
        jq -n --arg t "${profile}" '{spec:{tlsSecurityProfile:{type:$t, ($t|ascii_downcase):{}}, tlsAdherence:"StrictAllComponents"}}' >"${MOCK_DIR}/apiserver.json"
    fi
    ingress_min="$(component_min_version ingress "${profile}")"
    if [[ "${modifier}" == "naive-ingress" ]]; then
        ingress_min="$(profile_min_version "${profile}")"
    fi
    profile_ciphers "${profile}" | jq -R . | jq -s --arg m "${ingress_min}" '{status:{tlsProfile:{minTLSVersion:$m, ciphers:.}}}' >"${MOCK_DIR}/ingress.json"
    if [[ "${modifier}" == "explicit-ingress-profile" ]]; then
        jq --arg t "${profile}" '.spec.tlsSecurityProfile = {type: $t}' "${MOCK_DIR}/ingress.json" >"${MOCK_DIR}/ingress.json.new"
        mv "${MOCK_DIR}/ingress.json.new" "${MOCK_DIR}/ingress.json"
    fi
    if [[ "${modifier}" == "port-forward-exits" ]]; then
        touch "${MOCK_DIR}/exit-once-kube-apiserver-master-0" "${MOCK_DIR}/exit-once-etcd-master-1"
    fi

    start_endpoint kube-apiserver-lb-signer "${server_options[${kas_key}]}" >"${MOCK_DIR}/external-port"
    pods_json True kube-apiserver-master-0 kube-apiserver-master-1 >"${MOCK_DIR}/kube-apiserver-pods.json"
    for pod in kube-apiserver-master-0 kube-apiserver-master-1; do
        start_endpoint kube-apiserver-lb-signer "${server_options[${kas_key}]}" >"${MOCK_DIR}/forward-${pod}"
    done
    if [[ "${modifier}" == "etcd-not-ready" ]]; then
        { pods_json True etcd-master-0 | jq '.items'; pods_json False etcd-master-1 | jq '.items'; } | jq -s '{items: add}' >"${MOCK_DIR}/etcd-pods.json"
    else
        pods_json True etcd-master-0 etcd-master-1 >"${MOCK_DIR}/etcd-pods.json"
    fi
    [[ "${modifier}" == "etcd-wrong-certificate" ]] && etcd_cert=kube-apiserver-lb-signer
    for pod in etcd-master-0 etcd-master-1; do
        if [[ "${modifier}" == "etcd-unreachable" ]]; then
            # A port nothing listens on: the forward works but the connection fails.
            start_endpoint "${etcd_cert}" "${server_options[${etcd_key}]}" >"${MOCK_DIR}/forward-${pod}"
            kill "${server_pids[${#server_pids[@]} - 1]}"
            wait "${server_pids[${#server_pids[@]} - 1]}" 2>/dev/null
        else
            start_endpoint "${etcd_cert}" "${server_options[${etcd_key}]}" >"${MOCK_DIR}/forward-${pod}"
        fi
    done

    # Run the step script itself, as ci-operator does, in a separate process.
    rc=0
    env PATH="${mock_bin}:${PATH}" MOCK_DIR="${MOCK_DIR}" SHARED_DIR="${dir}/shared" ARTIFACT_DIR="${dir}/artifacts" \
        INSTALL_CONFIG_TLS_PROFILE_TYPE="${profile}" PROBE_RETRY_DELAY_SECONDS=0 PROBE_TIMEOUT_SECONDS=10 \
        INGRESS_STATUS_TIMEOUT_SECONDS=0 \
        bash "${verify_script}" >"${dir}/step.log" 2>&1 || rc=$?

    local summary="${dir}/artifacts/tls-profile-verify/summary.txt" junit="${dir}/artifacts/junit_openshift_installer_tls_profile_verify.xml"
    if [[ "${rc}" != "${want_rc}" ]]; then
        fail "scenario ${name}: exit ${rc}, want ${want_rc} (log: see below)"
        tail -n 40 "${dir}/step.log" >&2
    elif [[ ! -s "${summary}" || ! -s "${junit}" ]]; then
        fail "scenario ${name}: summary or JUnit report missing"
    elif [[ -n "${must_contain}" ]] && ! grep -Fq -- "${must_contain}" "${summary}"; then
        fail "scenario ${name}: summary lacks '${must_contain}'"
        cat "${summary}" >&2
    elif [[ "${want_rc}" == "0" ]] && grep -q '^fail' "${summary}"; then
        fail "scenario ${name}: passing run recorded failures"
    else
        pass "scenario ${name} ($(grep -c '^pass' "${summary}") passed, $(grep -c '^fail' "${summary}" || true) failed checks)"
    fi
}

run_scenario modern Modern 0 kube-apiserver:Modern etcd:Modern
run_scenario intermediate Intermediate 0 kube-apiserver:Intermediate etcd:Intermediate
run_scenario old Old 0 kube-apiserver:Old etcd:Old
run_scenario old-etcd-accepts-tls10 Old 1 kube-apiserver:Old regression:etcd-accepts-tls10 "" \
    "etcd etcd-master-0:2379 tls10-cbc handshake is rejected (protocol version) | the endpoint accepted a handshake the Old profile forbids"
run_scenario old-apiserver-rejects-tls10 Old 1 regression:kube-apiserver-min-tls12-all-ciphers etcd:Old "" \
    "external API endpoint tls10-cbc handshake is accepted | the endpoint rejected (REJECTED_PROTOCOL) a handshake the Old profile allows"
run_scenario intermediate-apiserver-accepts-cbc Intermediate 1 regression:kube-apiserver-min-tls12-all-ciphers etcd:Intermediate "" \
    "tls12-cbc handshake is rejected (cipher suite) | the endpoint accepted a handshake the Intermediate profile forbids"
run_scenario intermediate-apiserver-min-tls10 Intermediate 1 regression:kube-apiserver-min-tls10-intermediate-ciphers etcd:Intermediate "" \
    "tls10-cbc handshake is rejected (protocol version) | the endpoint refused the cipher suites, not the protocol version, so it does not enforce the Intermediate minimum TLS version"
run_scenario modern-endpoints-for-intermediate Intermediate 1 kube-apiserver:Modern etcd:Modern "" \
    "tls12-cbc handshake is rejected (cipher suite) | the endpoint refused the protocol version, so its minimum TLS version is above the Intermediate minimum"
run_scenario missing-adherence Modern 1 kube-apiserver:Modern etcd:Modern no-adherence \
    "APIServer tlsAdherence | expected StrictAllComponents"
run_scenario missing-install-config-field Old 1 kube-apiserver:Old etcd:Old no-install-config \
    "install-config requested tlsProfileType | expected one top-level tlsProfileType Old"
run_scenario naive-ingress-expectation Old 1 kube-apiserver:Old etcd:Old naive-ingress \
    "IngressController default status.tlsProfile minTLSVersion | expected VersionTLS11"
run_scenario explicit-ingress-profile Modern 1 kube-apiserver:Modern etcd:Modern explicit-ingress-profile \
    "IngressController default inherits the cluster TLS profile | spec.tlsSecurityProfile selects 'Modern'"
run_scenario port-forward-exits Old 0 kube-apiserver:Old etcd:Old port-forward-exits
if grep -q 'port-forward to kube-apiserver-master-0 exited; restarting it' "${test_dir}/scenario-port-forward-exits/step.log" \
    && grep -q 'port-forward to etcd-master-1 exited; restarting it' "${test_dir}/scenario-port-forward-exits/step.log"; then
    pass "exited port-forwards were restarted"
else
    fail "exited port-forwards were not restarted"
fi
run_scenario etcd-unreachable Intermediate 1 kube-apiserver:Intermediate etcd:Intermediate etcd-unreachable \
    "etcd etcd-master-0:2379 tls11-cbc handshake is rejected (protocol version) | inconclusive result CONNECT_ERROR"
run_scenario etcd-wrong-certificate Modern 1 kube-apiserver:Modern etcd:Modern etcd-wrong-certificate \
    "serves a etcd certificate | issuer CN 'kube-apiserver-lb-signer' does not match etcd"
run_scenario etcd-not-ready Modern 1 kube-apiserver:Modern etcd:Modern etcd-not-ready \
    "etcd instances are ready | found 1 ready pods for 2 control plane nodes"

# Diagnostic artifacts keep only the TLS fields of the observed servingInfo.
observed="${test_dir}/scenario-modern/artifacts/tls-profile-verify/kube-apiserver-observed-tls.json"
if [[ -s "${observed}" ]] && jq -e '.minTLSVersion == "VersionTLS12" and (.cipherSuites | length) == 1' "${observed}" >/dev/null \
    && ! grep -rq 'api.private.example.invalid' "${test_dir}/scenario-modern/artifacts"; then
    pass "observed servingInfo artifacts keep TLS fields and drop host names"
else
    fail "observed servingInfo artifacts keep TLS fields and drop host names"
fi

# A rejected handshake must never be reported as passing when the endpoint is unreachable.
if grep -q '^pass .*etcd etcd-master-0:2379.*handshake' "${test_dir}/scenario-etcd-unreachable/artifacts/tls-profile-verify/summary.txt"; then
    fail "unreachable etcd endpoint produced passing handshake checks"
else
    pass "unreachable etcd endpoint produced no passing handshake checks"
fi

if (( failures > 0 )); then
    echo "${failures} test(s) failed" >&2
    exit 1
fi
echo "All tests passed"
