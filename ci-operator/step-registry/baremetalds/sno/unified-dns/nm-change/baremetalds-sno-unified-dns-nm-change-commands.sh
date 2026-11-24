#!/bin/bash

# SNO unified-DNS D2: dummy NetworkManager connection (OCPEDGE-3224, OCPSTRAT-3609 test plan §5.3).
#
# Adds, then deletes, a dummy NetworkManager connection carrying a DNS server and a search
# domain (a dummy interface, never `nmcli con up` on br-ex, which could cut the debug
# session). Verifies the prepender merges and then removes the search domain with the node
# IP still first and rc-manager unmanaged, and that it is inactive again within ~1 minute.
# The connection is removed on exit even if a check fails.
#
# Runs over SSH on the dev-scripts hypervisor (${SHARED_DIR}/packet-conf.sh), where `oc`
# and the kubeconfig live; the node is inspected with `oc debug node`. Each check writes
# a log and a result row; the step container turns the rows into JUnit in ${ARTIFACT_DIR}
# and copies the evidence. Hard checks fail the step; soft checks only warn until the
# first runs confirm the values.

set -o nounset
set -o pipefail

STEP=nm-change

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

# --- cluster-level setup ------------------------------------------------------
NODE_NAME=""
function get_node_name() { NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [[ -n "${NODE_NAME}" ]]; }
wait_until 180 get_node_name || setup_fail setup-node "could not read the node name with oc"
# dns.config spec.baseDomain is already <cluster-name>.<base-domain>
DOMAIN=""
function get_domain() { DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null) && [[ -n "${DOMAIN}" ]]; }
wait_until 180 get_domain || setup_fail setup-domain "could not read dns.config/cluster spec.baseDomain"
PRIMARY_IP=""
function get_primary_ip() { PRIMARY_IP=$(node_shell 'cat /run/nodeip-configuration/primary-ip' 2>/dev/null | tr -d '[:space:]') && [[ "${PRIMARY_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
wait_until 180 get_primary_ip || setup_fail setup-primary-ip "could not read the node IP from /run/nodeip-configuration/primary-ip (got '${PRIMARY_IP}')"
echo "node under test: ${NODE_NAME}, node IP: ${PRIMARY_IP}, cluster domain: ${DOMAIN}"

# ==============================================================================
# D2: dummy NetworkManager connection
# ==============================================================================

CON_NAME="sno-unified-dns-d2"
D2_DOMAIN="d2-dns-change.test"

function cleanup_d2() { node_shell "nmcli con delete ${CON_NAME}" > /dev/null 2>&1 || true; }

function nm_search() { node_shell 'cat /run/NetworkManager/resolv.conf' | awk '/^search[ \t]/{$1=""; print}'; }
function resolv_search() { node_shell 'cat /etc/resolv.conf' | awk '/^search[ \t]/{$1=""; print}'; }
function nm_has_domain() { local s; s=$(nm_search) || return 1; [[ " ${s} " == *" ${D2_DOMAIN} "* ]]; }
function resolv_has_domain() { local s; s=$(resolv_search) || return 1; [[ " ${s} " == *" ${D2_DOMAIN} "* ]]; }
function resolv_lacks_domain() { local s; s=$(resolv_search) || return 1; [[ " ${s} " != *" ${D2_DOMAIN} "* ]]; }

function check_d2_nm_resolv() {
    wait_until 60 nm_has_domain || { echo "NetworkManager's resolv.conf never showed ${D2_DOMAIN}: D2 would pass as a no-op"; node_shell 'cat /run/NetworkManager/resolv.conf'; return 1; }
    echo "NetworkManager resolv.conf carries ${D2_DOMAIN}"
}

function check_d2_merged() {
    wait_until 90 resolv_has_domain || { echo "${D2_DOMAIN} never appeared in /etc/resolv.conf"; node_shell 'cat /etc/resolv.conf'; return 1; }
    echo "${D2_DOMAIN} merged into /etc/resolv.conf"
}

function check_d2_after_base() {
    local search i base_idx=-1 d2_idx=-1 tokens=()
    search=$(node_shell 'cat /etc/resolv.conf' | awk '/^search[ \t]/{$1=""; print}')
    read -r -a tokens <<< "${search}"
    for i in "${!tokens[@]}"; do
        [[ "${tokens[i]}" == "${DOMAIN}" ]] && base_idx=$i
        [[ "${tokens[i]}" == "${D2_DOMAIN}" ]] && d2_idx=$i
    done
    (( base_idx >= 0 && d2_idx > base_idx )) || { echo "search order is '${search}': ${D2_DOMAIN} must come after ${DOMAIN}"; return 1; }
    echo "search: ${search}"
}

function check_d2_node_ip_first() {
    local first
    first=$(node_shell 'cat /etc/resolv.conf' | awk '/^nameserver[ \t]/{print $2; exit}')
    [[ "${first}" == "${PRIMARY_IP}" ]] || { echo "first nameserver is '${first}', want ${PRIMARY_IP}"; return 1; }
}

function check_d2_rc_manager() {
    local cfg
    # Capture first: a pipe into grep -q gets SIGPIPE once grep exits, which
    # pipefail turns into a false failure when oc debug is still writing.
    cfg=$(node_shell 'NetworkManager --print-config') || { echo "NetworkManager --print-config failed"; return 1; }
    grep -q 'rc-manager=unmanaged' <<< "${cfg}" || { echo "rc-manager is not unmanaged"; grep -n 'rc-manager' <<< "${cfg}" || true; return 1; }
}

function check_d2_connection_removed() {
    local names
    node_shell "nmcli con delete ${CON_NAME}" > "${OUT}/nmcli-delete.txt" 2>&1 || { echo "nmcli con delete failed:"; cat "${OUT}/nmcli-delete.txt"; return 1; }
    names=$(node_shell 'nmcli -g NAME con show')
    ! grep -qx "${CON_NAME}" <<< "${names}" || { echo "${CON_NAME} is still listed"; return 1; }
}

function check_d2_domain_removed() {
    wait_until 90 resolv_lacks_domain || { echo "${D2_DOMAIN} is still in /etc/resolv.conf"; node_shell 'cat /etc/resolv.conf'; return 1; }
}

function check_d2_resolv_limits() {
    local resolv ns_count first
    resolv=$(node_shell 'cat /etc/resolv.conf') || { echo "could not read /etc/resolv.conf"; return 1; }
    ns_count=$(awk '/^nameserver[ \t]/{n++} END{print n+0}' <<< "${resolv}")
    first=$(awk '/^nameserver[ \t]/{print $2; exit}' <<< "${resolv}")
    (( ns_count <= 3 )) || { echo "${ns_count} nameservers while the dummy connection is active, at most 3 allowed"; return 1; }
    [[ "${first}" == "${PRIMARY_IP}" ]] || { echo "first nameserver is '${first}', want ${PRIMARY_IP}"; return 1; }
    echo "nameservers: ${ns_count}, node IP first"
}

function check_d2_prepender_inactive() {
    local before ts_after ts_later
    before="${PREPENDER_START_TS_BEFORE_DELETE:-}"
    [[ -n "${before}" ]] || { echo "no pre-delete prepender timestamp was captured"; return 1; }
    # (a) the prepender actually ran after the connection was removed
    wait_until 90 prepender_ran_since_delete || { echo "the prepender did not run after the connection was removed (start ts still ${before})"; return 1; }
    ts_after=$(prepender_start_ts) || { echo "could not read the prepender start timestamp"; return 1; }
    # (b) it settled: no new run over a 60s window, inactive at the end
    sleep 60
    ts_later=$(prepender_start_ts) || { echo "could not re-read the prepender start timestamp"; return 1; }
    [[ "${ts_later}" == "${ts_after}" ]] || { echo "the prepender restarted during the settle window (${ts_after} -> ${ts_later})"; return 1; }
    [[ "$(node_shell 'systemctl is-active sno-resolv-prepender.service' | head -n1)" == inactive ]] || { echo "sno-resolv-prepender.service is not inactive after settling"; return 1; }
    echo "the prepender ran after the delete and settled (start ts ${ts_later})"
}

function prepender_start_ts() {
    node_shell 'systemctl show sno-resolv-prepender.service -p ExecMainStartTimestampMonotonic --value' | tr -d '[:space:]'
}

function prepender_ran_since_delete() {
    local ts
    ts=$(prepender_start_ts) || return 1
    [[ -n "${ts}" && "${ts}" != "0" && "${ts}" != "${PREPENDER_START_TS_BEFORE_DELETE}" ]]
}

function run_nm_change() {
    trap cleanup_d2 EXIT
    echo "### D2: adding a dummy NetworkManager connection with a DNS server and search domain"
    # A dummy interface never takes the default route, so br-ex and the debug session are untouched.
    node_shell "nmcli con add type dummy ifname d2dns con-name ${CON_NAME} ipv4.method manual ipv4.addresses 192.0.2.77/32 ipv4.dns 192.0.2.99 ipv4.dns-search ${D2_DOMAIN}" \
        > "${OUT}/nmcli-add.txt" 2>&1 || { cat "${OUT}/nmcli-add.txt"; setup_fail d2-add-connection "nmcli con add failed"; }
    run_check hard d2-nm-resolv-has-domain check_d2_nm_resolv
    run_check hard d2-domain-merged check_d2_merged
    run_check hard d2-domain-after-base check_d2_after_base
    run_check hard d2-node-ip-first check_d2_node_ip_first
    run_check hard d2-resolv-limits check_d2_resolv_limits
    run_check hard d2-rc-manager-unmanaged check_d2_rc_manager
    node_shell 'cat /etc/resolv.conf' > "${OUT}/resolv.conf-after-add" 2>&1 || true
    PREPENDER_START_TS_BEFORE_DELETE=$(prepender_start_ts) || PREPENDER_START_TS_BEFORE_DELETE=""
    [[ -n "${PREPENDER_START_TS_BEFORE_DELETE}" ]] || echo "WARN: could not read the prepender start timestamp before the delete" >&2
    echo "### D2: deleting the dummy connection"
    run_check hard d2-connection-removed check_d2_connection_removed
    run_check hard d2-domain-removed check_d2_domain_removed
    run_check hard d2-node-ip-first-after-delete check_d2_node_ip_first
    run_check hard d2-prepender-inactive check_d2_prepender_inactive
    node_shell 'cat /etc/resolv.conf' > "${OUT}/resolv.conf-after-delete" 2>&1 || true
}

run_nm_change

echo "### results"
awk -F'\t' '{ printf "%-5s %-44s %s\n", $1, $2, toupper($3) }' "${OUT}/results.tsv"
exit 0
REMOTE


if [[ "${SSH_RC}" -eq 0 ]]; then
    ssh -n "${SSHOPTS[@]}" "root@${IP}" bash "'${REMOTE_SCRIPT}'" "'${STEP}'" "'${REMOTE_DIR}'" || SSH_RC=$?
fi
