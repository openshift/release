#!/bin/bash

# SNO unified-DNS read-only validation (OCPEDGE-3224, OCPSTRAT-3609 test plan §5.3).
#
# Shared by two refs: baremetalds-sno-unified-dns-validation and its
# baremetalds-sno-unified-dns-validation-post alias (a symlink to this file;
# ci-operator forbids listing one ref twice in a test). SNO_DNS_STEP only labels
# the run so JUnit and evidence of the two runs do not collide.
#
# One `oc debug node` session dumps the node facts to files; the checks run on the
# hypervisor, which also supplies dig for the DNS queries (RHCOS has no dig).
# Runs over SSH on the dev-scripts hypervisor (${SHARED_DIR}/packet-conf.sh), where `oc`
# and the kubeconfig live; the node is inspected with `oc debug node`. Each check writes
# a log and a result row; the step container turns the rows into JUnit in ${ARTIFACT_DIR}
# and copies the evidence. Hard checks fail the step; soft checks only warn until the
# first runs confirm the values.

set -o nounset
set -o pipefail

STEP="${SNO_DNS_STEP:-validation}"
case "${STEP}" in
    validation | validation-post) ;;
    *)
        echo "ERROR: SNO_DNS_STEP must be validation or validation-post (got '${STEP}')" >&2
        exit 2
        ;;
esac

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

EVIDENCE_DIR="${ARTIFACT_DIR}/sno-unified-dns-evidence/${STEP}"
JUNIT_FILE="${ARTIFACT_DIR}/junit_sno-unified-dns-${STEP}.xml"
REMOTE_DIR="/tmp/sno-unified-dns-${STEP}"
mkdir -p "${EVIDENCE_DIR}"

SSH_RC=0
HARD_FAILURES=0

function xml_escape() {
    tr -d '\000-\010\013\014\016-\037' | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# build_junit: one testcase per row of results.tsv; a missing or incomplete remote
# run is reported as a failing "remote-run" testcase so it can never pass silently.
function build_junit() {
    local tsv="${EVIDENCE_DIR}/results.tsv" total=0 body="" level name state log msg
    HARD_FAILURES=0
    if [[ -s "${tsv}" ]]; then
        while IFS=$'\t' read -r level name state; do
            total=$((total + 1))
            log="${EVIDENCE_DIR}/checks/${name}.log"
            msg=""
            if [[ -f "${log}" ]]; then
                msg=$(tail -n 40 "${log}" | xml_escape)
            fi
            case "${state}" in
                fail)
                    HARD_FAILURES=$((HARD_FAILURES + 1))
                    body+="    <testcase classname=\"sno-unified-dns-${STEP}\" name=\"${name}\"><failure message=\"hard check failed\">${msg}</failure></testcase>"$'\n'
                    ;;
                warn)
                    body+="    <testcase classname=\"sno-unified-dns-${STEP}\" name=\"${name}\"><system-out>soft check (${level}) warned: ${msg}</system-out></testcase>"$'\n'
                    ;;
                *)
                    body+="    <testcase classname=\"sno-unified-dns-${STEP}\" name=\"${name}\"/>"$'\n'
                    ;;
            esac
        done < "${tsv}"
    fi
    if [[ "${total}" -eq 0 || "${SSH_RC}" -ne 0 ]]; then
        total=$((total + 1))
        HARD_FAILURES=$((HARD_FAILURES + 1))
        body+="    <testcase classname=\"sno-unified-dns-${STEP}\" name=\"remote-run\"><failure message=\"remote run incomplete\">remote script exited ${SSH_RC}, or no results were recorded</failure></testcase>"$'\n'
    fi
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"sno-unified-dns-${STEP}\" tests=\"${total}\" failures=\"${HARD_FAILURES}\">"
        printf '%s' "${body}"
        echo '</testsuite>'
    } > "${JUNIT_FILE}" || { echo "ERROR: could not write ${JUNIT_FILE}" >&2; HARD_FAILURES=$((HARD_FAILURES + 1)); return 1; }
    echo "wrote ${JUNIT_FILE}: ${total} testcases, ${HARD_FAILURES} hard failures"
}

function finish() {
    local exit_code=$?
    trap - EXIT
    echo "### fetching evidence"
    if ! ssh "${SSHOPTS[@]}" "root@${IP}" tar -C "${REMOTE_DIR}" -czf - . | tar -C "${EVIDENCE_DIR}" -xzf -; then
        echo "ERROR: could not fetch evidence from ${REMOTE_DIR}" >&2
        printf 'hard\tevidence-transfer\tfail\n' >> "${EVIDENCE_DIR}/results.tsv"
    fi
    build_junit
    if [[ "${HARD_FAILURES}" -ne 0 || "${exit_code}" -ne 0 ]]; then
        exit 1
    fi
    exit 0
}
trap finish EXIT

# The remote script is shipped as a file and run with stdin closed, so no command
# in it can swallow the rest of the script from stdin.
REMOTE_SCRIPT="/tmp/sno-unified-dns-${STEP}.sh"
# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" "cat > '${REMOTE_SCRIPT}'" << 'REMOTE' || SSH_RC=$?
STEP="$1"
OUT="$2"
set -o nounset
set -o pipefail
export LC_ALL=C

rm -rf "${OUT}"
mkdir -p "${OUT}/checks" "${OUT}/facts"
: > "${OUT}/results.tsv"

function record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${OUT}/results.tsv"; }
function upper() { tr '[:lower:]' '[:upper:]' <<< "$1"; }

# setup_fail <name> <message>: record a hard failure and stop (nothing can be checked).
function setup_fail() {
    echo "ERROR: $2" >&2
    printf '%s\n' "$2" > "${OUT}/checks/$1.log"
    record hard "$1" fail
    exit 1
}

# run_check <hard|soft> <name> <function>: the function logs to stdout/stderr and
# returns non-zero when the check fails. Checks never rely on errexit.
function run_check() {
    local level="$1" name="$2" state
    shift 2
    echo "=== [${level}] ${name} ==="
    if "$@" > "${OUT}/checks/${name}.log" 2>&1; then
        state=pass
    elif [[ "${level}" == hard ]]; then
        state=fail
    else
        state=warn
    fi
    cat "${OUT}/checks/${name}.log"
    echo "-> $(upper "${state}")"
    record "${level}" "${name}" "${state}" || { echo "ERROR: could not record ${name}" >&2; exit 1; }
}

# wait_until <seconds> <command...>: poll every 10s until the command succeeds.
function wait_until() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        (( SECONDS < deadline )) || return 1
        sleep 10
    done
}

# node_shell <script> [arg]: run a script on the node; the arg becomes $1.
function node_shell() {
    timeout 180 oc debug node/"${NODE_NAME}" --to-namespace=default -- chroot /host bash -c "$1" _ "${2:-}"
}
# dq <name> <server> [tcp]: A answers, one per line.
function dq() {
    local proto=()
    if [[ "${3:-}" == tcp ]]; then
        proto=(+tcp)
    fi
    dig +short +time=5 +tries=2 ${proto[@]+"${proto[@]}"} A "$1" "@$2"
}

# search_of <file>: the search domains, space separated.
function search_of() { awk '/^search[ \t]/{$1=""; print}' "$1"; }

read -r -d '' FACTS_SCRIPT << 'EOF' || true
domain="$1"
s() { printf '\n@@@ %s\n' "$1"; }
s primary-ip; cat /run/nodeip-configuration/primary-ip 2>&1
s boot-id; cat /proc/sys/kernel/random/boot_id 2>&1
s resolv.conf; cat /etc/resolv.conf 2>&1
s nm-resolv.conf; cat /run/NetworkManager/resolv.conf 2>&1
s corefile; cat /etc/sno-coredns/Corefile 2>&1
s ss53; ss -Hlntup 'sport = :53' 2>&1
s resolv-label; stat -c %C /etc/resolv.conf 2>&1
s nm-config; NetworkManager --print-config 2>&1
s dnsmasq-active; systemctl is-active dnsmasq.service 2>&1
s dnsmasq-procs; pgrep -a -x dnsmasq 2>&1 || true
s prepender-path-active; systemctl is-active sno-resolv-prepender.path 2>&1
s prepender-service; systemctl show sno-resolv-prepender.service -p Result -p ActiveState -p TriggeredBy -p ExecMainExitTimestampMonotonic -p ExecMainStartTimestampMonotonic -p NRestarts 2>&1
s prepender-journal; journalctl -b -u sno-resolv-prepender.service --no-pager -o short-monotonic 2>&1
s getent-api-int; getent hosts "api-int.${domain}" 2>&1
s avc; journalctl -b --no-pager 2>/dev/null | grep -E 'avc: +denied'
true
EOF

# collect_facts <dir>: one oc debug session, split into one file per section.
function collect_facts() {
    local dir="$1" raw
    mkdir -p "${dir}"
    raw=$(node_shell "${FACTS_SCRIPT}" "${DOMAIN}") || return 1
    awk -v dir="${dir}" '/^@@@ /{f=dir"/"$2; printf "" > f; next} f{print > f}' <<< "${raw}"
}

# --- cluster-level setup ------------------------------------------------------
NODE_NAME=""
function get_node_name() { NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [[ -n "${NODE_NAME}" ]]; }
wait_until 180 get_node_name || setup_fail setup-node "could not read the node name with oc"
# dns.config spec.baseDomain is already <cluster-name>.<base-domain>
DOMAIN=""
function get_domain() { DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null) && [[ -n "${DOMAIN}" ]]; }
wait_until 180 get_domain || setup_fail setup-domain "could not read dns.config/cluster spec.baseDomain"
if ! command -v dig > /dev/null 2>&1; then
    dnf -y install bind-utils > "${OUT}/checks/setup-dig.log" 2>&1 || true
fi
command -v dig > /dev/null 2>&1 || setup_fail setup-dig "dig is not available on the hypervisor and could not be installed"
echo "node under test: ${NODE_NAME}, cluster domain: ${DOMAIN}"

F="${OUT}/facts"
function load_facts() {
    collect_facts "${F}" || return 1
    PRIMARY_IP=$(head -n1 "${F}/primary-ip" | tr -d '[:space:]')
    [[ "${PRIMARY_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ==============================================================================
# validation checks (also reused by D1/D2)
# ==============================================================================

function check_gate() {
    oc get featuregate cluster -o json > "${OUT}/featuregate.json" || { echo "cannot read featuregate/cluster"; return 1; }
    jq -e '[.status.featureGates[].enabled[].name] | index("UnifiedClusterManagedDNSAndLB") != null' "${OUT}/featuregate.json" > /dev/null \
        || { echo "UnifiedClusterManagedDNSAndLB is not enabled: the lane is misconfigured"; return 1; }
}

function check_coredns_pod() {
    local sel='[.items[] | select(.metadata.name | startswith("sno-coredns"))]' pods count ready r1 r2 now min_age wait_s
    pods=$(oc get pods -n openshift-kni-infra -o json) || { echo "cannot list pods in openshift-kni-infra"; return 1; }
    count=$(jq "${sel} | length" <<< "${pods}")
    [[ "${count}" -ge 1 ]] || { echo "no sno-coredns pod in openshift-kni-infra"; return 1; }
    ready=$(jq -r "${sel} | ([.[].status.containerStatuses[]?] | length > 0) and ([.[].status.containerStatuses[]?.ready] | all)" <<< "${pods}")
    [[ "${ready}" == true ]] || { echo "sno-coredns containers are not all ready"; jq "${sel} | .[].status.containerStatuses" <<< "${pods}"; return 1; }
    local snap='[.[] | {name: .metadata.name, uid: .metadata.uid, c: [.status.containerStatuses[]? | {n: .name, r: .restartCount}]}]'
    r1=$(jq -S "${sel} | ${snap}" <<< "${pods}")
    [[ -n "${r1}" && "${r1}" != '[]' ]] || { echo "no running sno-coredns pod to watch"; return 1; }
    now=$(date -u +%s)
    min_age=$(jq -r --argjson now "${now}" "${sel} | [.[].status.containerStatuses[]?.state.running.startedAt | select(. != null) | (\$now - fromdateiso8601)] | min // 0 | floor" <<< "${pods}")
    if [[ "${min_age}" =~ ^[0-9]+$ && "${min_age}" -ge 60 ]]; then
        echo "sno-coredns ready (min container age ${min_age}s); skipping stability sleep"
        return 0
    fi
    wait_s=$((60 - ${min_age:-0}))
    (( wait_s > 60 )) && wait_s=60
    (( wait_s < 1 )) && wait_s=1
    sleep "${wait_s}"
    pods=$(oc get pods -n openshift-kni-infra -o json) || { echo "cannot list pods in openshift-kni-infra"; return 1; }
    count=$(jq "${sel} | length" <<< "${pods}")
    ready=$(jq -r "${sel} | ([.[].status.containerStatuses[]?] | length > 0) and ([.[].status.containerStatuses[]?.ready] | all)" <<< "${pods}")
    [[ "${count}" -ge 1 && "${ready}" == true ]] || { echo "sno-coredns pod disappeared or became unready during the watch"; jq "${sel}" <<< "${pods}"; return 1; }
    r2=$(jq -S "${sel} | ${snap}" <<< "${pods}")
    [[ "${r1}" == "${r2}" ]] || { echo "sno-coredns was replaced or restarted while watching"; jq "${sel}" <<< "${pods}"; return 1; }
    echo "sno-coredns ready; pod identity and restart counts stable"
}

function check_no_vip() {
    local bad=0 infra kni
    infra=$(oc get infrastructure cluster -o json) || { echo "cannot read infrastructure/cluster"; return 1; }
    if jq -e '(.status.platformStatus | tostring) | test("apiServerInternalIP|ingressIP|[Vv][Ii][Pp]")' <<< "${infra}" > /dev/null; then
        echo "PlatformStatus carries VIP fields:"
        jq '.status.platformStatus' <<< "${infra}"
        bad=1
    fi
    kni=$(oc get pods -n openshift-kni-infra -o name) || { echo "cannot list pods in openshift-kni-infra"; return 1; }
    if grep -Eqi 'keepalived|haproxy' <<< "${kni}"; then
        echo "keepalived/haproxy pods present:"
        grep -Ei 'keepalived|haproxy' <<< "${kni}"
        bad=1
    fi
    return "${bad}"
}

function check_no_dnsmasq() {
    local bad=0 mcs
    mcs=$(oc get machineconfig -o name) || { echo "cannot list machineconfigs"; return 1; }
    if grep -qi dnsmasq <<< "${mcs}"; then
        echo "dnsmasq MachineConfig present:"
        grep -i dnsmasq <<< "${mcs}"
        bad=1
    fi
    if [[ "$(head -n1 "${F}/dnsmasq-active")" == active ]]; then
        echo "dnsmasq.service is active"
        bad=1
    fi
    if grep -q '[^[:space:]]' "${F}/dnsmasq-procs"; then
        echo "dnsmasq process running:"
        cat "${F}/dnsmasq-procs"
        bad=1
    fi
    return "${bad}"
}

function check_only_coredns_53() {
    local netid laddr procs names n_tcp=0 n_udp=0
    [[ -s "${F}/ss53" ]] || { echo "nothing is listening on :53"; return 1; }
    while read -r netid _ _ _ laddr _ procs; do
        [[ -n "${netid}" ]] || continue
        case "${netid}" in
            tcp) n_tcp=$((n_tcp + 1)) ;;
            udp) n_udp=$((n_udp + 1)) ;;
        esac
        [[ "${laddr}" == "${PRIMARY_IP}:53" ]] || { echo "listener not bound to the node IP: ${laddr} ${procs}"; return 1; }
        names=$(grep -o '"[^"]*"' <<< "${procs}" | sort -u | tr '\n' ' ')
        [[ "${names}" == '"coredns" ' ]] || { echo "non-coredns listener on :53: ${procs}"; return 1; }
    done < "${F}/ss53"
    (( n_tcp >= 1 && n_udp >= 1 )) || { echo "need TCP and UDP listeners, got tcp=${n_tcp} udp=${n_udp}"; cat "${F}/ss53"; return 1; }
    echo "only coredns on ${PRIMARY_IP}:53 (tcp=${n_tcp} udp=${n_udp})"
}

function check_dns_answers() {
    local name proto answer bad=0
    for name in "api.${DOMAIN}" "api-int.${DOMAIN}" "x${RANDOM}${RANDOM}.apps.${DOMAIN}"; do
        for proto in udp tcp; do
            answer=$(dq "${name}" "${PRIMARY_IP}" "${proto}")
            if [[ "${answer}" == "${PRIMARY_IP}" ]]; then
                echo "ok ${name} ${proto} -> ${answer}"
            else
                echo "FAIL ${name} over ${proto}: got '${answer}', want '${PRIMARY_IP}'"
                bad=1
            fi
        done
    done
    return "${bad}"
}

# Functional forwarding check: Corefile rendering (policy sequential, node-IP
# filtering) is unit-tested in MCO and baremetal-runtimecfg; here we verify
# that external resolution actually works through the node's CoreDNS.
function check_corefile_forward() {
    local external
    external=$(dq redhat.com "${PRIMARY_IP}" udp)
    grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' <<< "${external}" || { echo "external name did not resolve through CoreDNS: '${external}'"; return 1; }
    echo "redhat.com -> $(head -n1 <<< "${external}")"
}

# Proves upstream DNS does not resolve api-int, so the local CoreDNS must have
# provided the resolution (a broken local CoreDNS could not be hidden by forwarding).
function check_upstream_nxdomain() {
    local ns upstreams status bad=0
    upstreams=$(awk -v ip="${PRIMARY_IP}" '/^nameserver[ \t]/ && $2 != ip {print $2}' "${F}/nm-resolv.conf")
    [[ -n "${upstreams}" ]] || { echo "no upstream nameservers in /run/NetworkManager/resolv.conf"; return 1; }
    : > "${OUT}/upstream-answers.txt"
    for ns in ${upstreams}; do
        status=$(dig +time=5 +tries=1 "api-int.${DOMAIN}" "@${ns}" | grep -o 'status: [A-Z]*' | head -n1)
        echo "upstream ${ns}: api-int -> ${status:-no answer}"
        [[ "${status}" == 'status: NXDOMAIN' ]] || bad=1
        {
            echo "upstream ${ns}: api -> $(dq "api.${DOMAIN}" "${ns}" | tr '\n' ' ')"
            echo "upstream ${ns}: *.apps -> $(dq "x${RANDOM}.apps.${DOMAIN}" "${ns}" | tr '\n' ' ')"
        } >> "${OUT}/upstream-answers.txt"
    done
    return "${bad}"
}

function check_resolv_conf() {
    local ns=() first search resolved bad=0
    mapfile -t ns < <(awk '/^nameserver[ \t]/{print $2}' "${F}/resolv.conf")
    first="${ns[0]:-}"
    [[ "${first}" == "${PRIMARY_IP}" ]] || { echo "first nameserver is '${first}', want ${PRIMARY_IP}"; bad=1; }
    (( ${#ns[@]} <= 3 )) || { echo "${#ns[@]} nameservers, at most 3 allowed"; bad=1; }
    (( ${#ns[@]} >= 2 )) || { echo "no fallback upstream kept (nameservers: ${ns[*]:-none})"; bad=1; }
    local has_upstream=0 n
    for n in "${ns[@]:1}"; do [[ "${n}" != "${PRIMARY_IP}" ]] && has_upstream=1; done
    (( has_upstream )) || { echo "later nameservers only repeat the node IP (${ns[*]:-none})"; bad=1; }
    search=$(search_of "${F}/resolv.conf")
    [[ " ${search} " == *" ${DOMAIN} "* ]] || { echo "search '${search}' lacks ${DOMAIN}"; bad=1; }
    resolved=$(awk '{print $1; exit}' "${F}/getent-api-int")
    [[ "${resolved}" == "${PRIMARY_IP}" ]] || { echo "getent hosts api-int.${DOMAIN} -> '${resolved}', want ${PRIMARY_IP}"; bad=1; }
    echo "observed nameservers: ${ns[*]:-none}; search: ${search}"
    return "${bad}"
}

function check_prepender_units() {
    local bad=0 result state exit_ts nr1 nr2
    grep -q 'rc-manager=unmanaged' "${F}/nm-config" || { echo "NetworkManager rc-manager is not unmanaged"; bad=1; }
    [[ "$(head -n1 "${F}/prepender-path-active")" == active ]] || { echo "sno-resolv-prepender.path is not active"; bad=1; }
    result=$(sed -n 's/^Result=//p' "${F}/prepender-service")
    state=$(sed -n 's/^ActiveState=//p' "${F}/prepender-service")
    exit_ts=$(sed -n 's/^ExecMainExitTimestampMonotonic=//p' "${F}/prepender-service")
    nr1=$(sed -n 's/^NRestarts=//p' "${F}/prepender-service")
    # The unit retries every 5s until CoreDNS is ready, so Result is only
    # meaningful once the burst has ended and a run has actually completed.
    [[ "${state}" != activating ]] || { echo "sno-resolv-prepender.service is still activating (restart burst in progress)"; bad=1; }
    [[ "${exit_ts}" =~ ^[0-9]+$ && "${exit_ts}" -gt 0 ]] || { echo "the prepender has not completed a run since boot (ExecMainExitTimestampMonotonic=${exit_ts})"; bad=1; }
    [[ "${result}" == success ]] || { echo "sno-resolv-prepender.service last Result is '${result}', want success"; bad=1; }
    sleep 15
    nr2=$(node_shell 'systemctl show sno-resolv-prepender.service -p NRestarts --value' | tr -d '[:space:]') ||
        { echo "could not re-read the prepender restart count"; bad=1; }
    if [[ -n "${nr2}" && "${nr1}" != "${nr2}" ]]; then
        echo "sno-resolv-prepender.service is still restarting (NRestarts ${nr1} -> ${nr2})"
        bad=1
    fi
    return "${bad}"
}

function check_selinux() {
    local bad=0
    if grep -qi coredns "${F}/avc"; then
        echo "coredns AVC denials:"
        grep -i coredns "${F}/avc"
        bad=1
    fi
    grep -q net_conf_t "${F}/resolv-label" || { echo "/etc/resolv.conf label is '$(head -n1 "${F}/resolv-label")', want net_conf_t"; bad=1; }
    return "${bad}"
}

function check_no_loopback() {
    if grep -Eq '(^|[[:space:]])(127\.|\[::1\])' "${F}/ss53"; then
        echo "something on :53 is bound to loopback:"
        cat "${F}/ss53"
        return 1
    fi
}

function check_prepender_not_looping() {
    local j="${F}/prepender-journal" res starts finished failed last first_start first_finish
    first_start=$(sed -n 's/^\[[[:space:]]*\([0-9.]*\)\].*Starting sno-resolv-prepender.*/\1/p' "${j}" | head -n1)
    first_finish=$(sed -n 's/^\[[[:space:]]*\([0-9.]*\)\].*Finished sno-resolv-prepender.*/\1/p' "${j}" | head -n1)
    # The unit retries every 5s until CoreDNS is ready, so a burst of failed
    # runs is normal. It only loops if it starts again after its last success.
    res=$(awk '
        /Starting sno-resolv-prepender/ { starts++; last = "start" }
        /Finished sno-resolv-prepender/ { finished++; last = "finish" }
        /Failed to start sno-resolv-prepender/ { if (!finished) failed++ }
        END { printf "%d %d %d %s", starts, finished, failed, (starts ? last : "none") }
    ' "${j}")
    read -r starts finished failed last <<< "${res}"
    echo "starts=${starts}, successful runs=${finished}, failed runs before the first success=${failed}, first start=${first_start:-?}s, first success=${first_finish:-?}s"
    [[ "${last}" == finish ]] || { echo "the prepender started again after its last successful run (still looping)"; return 1; }
}

function run_validation_checks() {
    run_check hard gate-enabled check_gate
    run_check hard coredns-pod-ready-stable check_coredns_pod
    run_check hard no-vip-keepalived-haproxy check_no_vip
    run_check hard no-dnsmasq check_no_dnsmasq
    run_check hard only-coredns-on-53 check_only_coredns_53
    run_check hard dns-answers-node-ip check_dns_answers
    run_check hard corefile-forward check_corefile_forward
    run_check soft upstream-nxdomain-api-int check_upstream_nxdomain
    run_check hard resolv-conf check_resolv_conf
    run_check hard prepender-units check_prepender_units
    run_check hard selinux check_selinux
    run_check soft loopback-not-served check_no_loopback
    run_check soft prepender-not-looping check_prepender_not_looping
}

wait_until 180 load_facts || setup_fail node-facts "could not collect node facts with oc debug node"
run_validation_checks

echo "### results"
awk -F'\t' '{ printf "%-5s %-44s %s\n", $1, $2, toupper($3) }' "${OUT}/results.tsv"
exit 0
REMOTE


if [[ "${SSH_RC}" -eq 0 ]]; then
    ssh -n "${SSHOPTS[@]}" "root@${IP}" bash "'${REMOTE_SCRIPT}'" "'${STEP}'" "'${REMOTE_DIR}'" || SSH_RC=$?
fi
