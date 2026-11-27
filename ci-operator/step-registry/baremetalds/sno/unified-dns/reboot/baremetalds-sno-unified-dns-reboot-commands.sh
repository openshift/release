#!/bin/bash

# SNO unified-DNS D1: MCO-driven reboot (OCPEDGE-3224, OCPSTRAT-3609 test plan §5.3).
#
# Reboots the node with `oc adm reboot-machine-config-pool mcp/master` and
# `oc adm wait-for-node-reboot nodes --all`, then verifies that the resolv.conf takeover
# happened with no manual step and that api-int is answered by the node's CoreDNS. The
# boot-to-takeover time is saved; its bound stays soft until a value is agreed.
#
# Runs over SSH on the dev-scripts hypervisor (${SHARED_DIR}/packet-conf.sh), where `oc`
# and the kubeconfig live; the node is inspected with `oc debug node`. Each check writes
# a log and a result row; the step container turns the rows into JUnit in ${ARTIFACT_DIR}
# and copies the evidence. Hard checks fail the step; soft checks only warn until the
# first runs confirm the values.

set -o nounset
set -o pipefail

STEP=reboot

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

# first_ns <file>: first nameserver of a resolv.conf-style file.
function first_ns() { awk '/^nameserver[ \t]/{print $2; exit}' "$1"; }

read -r -d '' FACTS_SCRIPT << 'EOF' || true
s() { printf '\n@@@ %s\n' "$1"; }
s primary-ip; cat /run/nodeip-configuration/primary-ip 2>&1
s boot-id; cat /proc/sys/kernel/random/boot_id 2>&1
s resolv.conf; cat /etc/resolv.conf 2>&1
s prepender-path-active; systemctl is-active sno-resolv-prepender.path 2>&1
s prepender-service; systemctl show sno-resolv-prepender.service -p Result -p ActiveState -p TriggeredBy -p ExecMainExitTimestampMonotonic -p ExecMainStartTimestampMonotonic -p NRestarts 2>&1
s prepender-path-service; systemctl show sno-resolv-prepender.path -p ActiveEnterTimestampMonotonic -p Result 2>&1
s prepender-journal; journalctl -b -u sno-resolv-prepender.service --no-pager -o short-monotonic 2>&1
true
EOF

# collect_facts <dir>: one oc debug session, split into one file per section.
function collect_facts() {
    local dir="$1" raw
    mkdir -p "${dir}"
    raw=$(node_shell "${FACTS_SCRIPT}") || return 1
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
# D1: MCO-driven reboot
# ==============================================================================

function node_ready() { oc wait node/"${NODE_NAME}" --for=condition=Ready=True --timeout=20s > /dev/null 2>&1; }

function takeover_done() {
    local ts
    load_facts || return 1
    ts=$(sed -n 's/^ExecMainExitTimestampMonotonic=//p' "${F}/prepender-service")
    [[ "$(first_ns "${F}/resolv.conf")" == "${PRIMARY_IP}" ]] \
        && [[ "$(sed -n 's/^Result=//p' "${F}/prepender-service")" == success ]] \
        && [[ "${ts}" =~ ^[0-9]+$ && "${ts}" -gt 0 ]]
}

function check_rebooted() {
    local before after
    before=$(head -n1 "${OUT}/facts-before/boot-id")
    after=$(head -n1 "${F}/boot-id")
    [[ -n "${after}" && "${before}" != "${after}" ]] || { echo "boot id did not change (${before} -> ${after})"; return 1; }
    echo "boot id ${before} -> ${after}"
}

# boot_id_changed: the node really rebooted since the pre-reboot sample.
function boot_id_changed() {
    load_facts || return 1
    local after
    after=$(head -n1 "${F}/boot-id")
    [[ -n "${after}" && "${after}" != "${BEFORE_BOOT_ID}" ]]
}

function check_d1_takeover() {
    local bad=0 result ts
    [[ "$(first_ns "${F}/resolv.conf")" == "${PRIMARY_IP}" ]] || { echo "first nameserver is '$(first_ns "${F}/resolv.conf")', want ${PRIMARY_IP}"; bad=1; }
    result=$(sed -n 's/^Result=//p' "${F}/prepender-service")
    [[ "${result}" == success ]] || { echo "prepender last Result is '${result}', want success"; bad=1; }
    ts=$(sed -n 's/^ExecMainExitTimestampMonotonic=//p' "${F}/prepender-service")
    [[ "${ts}" =~ ^[0-9]+$ && "${ts}" -gt 0 ]] || { echo "the prepender has not completed a run since boot (ExecMainExitTimestampMonotonic=${ts})"; bad=1; }
    [[ "$(head -n1 "${F}/prepender-path-active")" == active ]] || { echo "sno-resolv-prepender.path is not active"; bad=1; }
    [[ "${bad}" -eq 0 ]] && echo "takeover reached with no manual step after the reboot"
    return "${bad}"
}

function check_d1_answers() {
    local answer
    answer=$(dq "api-int.${DOMAIN}" "${PRIMARY_IP}" udp)
    [[ "${answer}" == "${PRIMARY_IP}" ]] || { echo "api-int.${DOMAIN} -> '${answer}', want ${PRIMARY_IP}"; return 1; }
    echo "api-int.${DOMAIN} -> ${answer}"
}

# The functional proof that the .path unit triggers the service is D2's
# merge/unmerge; here we only record that the service ran in this boot and that
# nothing else is configured to start it.
function check_d1_prepender_ran() {
    local bad=0 deps dispatcher path_enter first_start_us
    deps=$(node_shell 'systemctl list-dependencies --reverse sno-resolv-prepender.service' 2>/dev/null) ||
        { echo "could not list reverse dependencies"; return 1; }
    echo "reverse dependencies:"
    echo "${deps}"
    if grep -oE '[A-Za-z0-9@._-]+\.(service|path|timer|socket)' <<< "${deps}" |
        sort -u | grep -vx -e 'sno-resolv-prepender.service' -e 'sno-resolv-prepender.path'; then
        echo "an unexpected unit can trigger sno-resolv-prepender.service"
        bad=1
    fi
    dispatcher=$(node_shell 'grep -rls sno-resolv-prepender /etc/NetworkManager/dispatcher.d 2>/dev/null || true' 2>/dev/null) || true
    [[ -z "${dispatcher}" ]] || { echo "NetworkManager dispatcher scripts reference the service: ${dispatcher}"; bad=1; }
    first_start_us=$(sed -n 's/^\[[[:space:]]*\([0-9.]*\)\].*Starting sno-resolv-prepender.*/\1/p' "${F}/prepender-journal" |
        head -n1 | awk '{printf "%.0f", $1 * 1000000}')
    [[ -n "${first_start_us}" ]] || { echo "the prepender did not start in this boot (empty journal)"; bad=1; }
    path_enter=$(sed -n 's/^ActiveEnterTimestampMonotonic=//p' "${F}/prepender-path-service")
    echo "sno-resolv-prepender.path ActiveEnter=${path_enter:-?}us, first service start=${first_start_us:-?}us"
    if [[ -n "${path_enter}" && -n "${first_start_us}" && "${path_enter}" -gt "${first_start_us}" ]]; then
        echo "the .path unit became active after the service first started"
        bad=1
    fi
    return "${bad}"
}

function check_d1_takeover_time() {
    local first_finish us secs
    first_finish=$(sed -n 's/^\[[[:space:]]*\([0-9.]*\)\].*Finished sno-resolv-prepender.*/\1/p' "${F}/prepender-journal" | head -n1)
    us=$(sed -n 's/^ExecMainExitTimestampMonotonic=//p' "${F}/prepender-service")
    if [[ -n "${first_finish}" ]]; then
        secs=${first_finish%.*}
        echo "boot -> first successful prepender run: ${secs}s (journal, first Finished)"
        echo "last run exit, upper bound: $(( ${us:-0} / 1000000 ))s"
        echo "${secs}" > "${OUT}/takeover-seconds.txt"
        echo "journal-first-finished" > "${OUT}/takeover-seconds-source.txt"
    elif [[ "${us}" =~ ^[0-9]+$ && "${us}" -gt 0 ]]; then
        secs=$((us / 1000000))
        echo "boot -> takeover (upper bound, last prepender run finished): ${secs}s"
        echo "${secs}" > "${OUT}/takeover-seconds-upper-bound.txt"
        echo "upper-bound-last-run" > "${OUT}/takeover-seconds-source.txt"
    else
        echo "no prepender finish in the journal and no monotonic exit timestamp (got '${us}')"
        return 1
    fi
    echo "the bound stays soft until agreed"
}

function run_reboot() {
    local wait_rc=0
    wait_until 180 load_facts || setup_fail node-facts "could not collect node facts before the reboot"
    cp -r "${F}" "${OUT}/facts-before"
    BEFORE_BOOT_ID=$(head -n1 "${OUT}/facts-before/boot-id")
    echo "### D1: MCO-driven reboot"
    oc adm reboot-machine-config-pool mcp/master || setup_fail reboot-request "oc adm reboot-machine-config-pool mcp/master failed"
    # wait-for-node-reboot can exit early when the SNO API drops as the node
    # goes down, so it is informational; the boot id is the gate.
    timeout 20m oc adm wait-for-node-reboot nodes --all || wait_rc=$?
    [[ "${wait_rc}" -eq 0 ]] || echo "WARN: oc adm wait-for-node-reboot exited ${wait_rc}; waiting on the boot id instead" >&2
    wait_until 600 boot_id_changed || echo "WARN: the boot id did not change within 10m" >&2
    wait_until 600 node_ready || echo "WARN: node did not report Ready within 10m" >&2
    wait_until 900 takeover_done || echo "WARN: takeover not observed within 15m; checking the final state" >&2
    load_facts || setup_fail node-facts "could not collect node facts after the reboot"
    run_check hard d1-node-rebooted check_rebooted
    run_check hard d1-resolv-takeover check_d1_takeover
    run_check hard d1-api-int-answers check_d1_answers
    run_check soft d1-prepender-ran-this-boot check_d1_prepender_ran
    run_check soft d1-boot-to-takeover-time check_d1_takeover_time
}

run_reboot

echo "### results"
awk -F'\t' '{ printf "%-5s %-44s %s\n", $1, $2, toupper($3) }' "${OUT}/results.tsv"
exit 0
REMOTE


if [[ "${SSH_RC}" -eq 0 ]]; then
    ssh -n "${SSHOPTS[@]}" "root@${IP}" bash "'${REMOTE_SCRIPT}'" "'${STEP}'" "'${REMOTE_DIR}'" || SSH_RC=$?
fi
