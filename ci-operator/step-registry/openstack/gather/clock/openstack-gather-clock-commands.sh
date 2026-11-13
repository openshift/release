#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Temporary diagnostic step for OSASINFRA-4617: collect node clock/NTP state on
# the proxy-externallb topology. Read-only apart from oc debug pods.

OUT="${ARTIFACT_DIR}/node-clock.txt"
: > "${OUT}"

log() { echo "$*" | tee -a "${OUT}"; }

# The test pod's kubeconfig carries the CI namespace, which does not exist on
# the cluster under test. oc debug creates its pod in the namespace it is given.
DEBUG_NAMESPACE="${DEBUG_NAMESPACE:-default}"

# ssh aborts with "No user exists for uid ..." when running as an arbitrary UID
# without a passwd entry; the bastion proxy step does the same workaround.
BASTION_USER="${BASTION_USER:-cloud-user}"
if ! whoami >/dev/null 2>&1 && [[ -w /etc/passwd ]]; then
	echo "${BASTION_USER}:x:$(id -u):0:bastion:/sbin/nologin" >> /etc/passwd
fi

log "===== date UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "===== alert query:"
oc -n openshift-monitoring get --raw "/api/v1/namespaces/openshift-monitoring/services/https:thanos-querier:9091/proxy/api/v1/alerts" \
	> "${ARTIFACT_DIR}/alerts.json" 2> "${ARTIFACT_DIR}/alerts.err" || true
if [[ -s "${ARTIFACT_DIR}/alerts.json" ]]; then
	log "  NodeClockNotSynchronising occurrences: $(grep -o 'NodeClockNotSynchronising' "${ARTIFACT_DIR}/alerts.json" | wc -l)"
else
	log "  alert query failed: $(head -2 "${ARTIFACT_DIR}/alerts.err")"
fi

for node in $(oc get nodes -o name); do
	log ""
	log "===== ${node}"

	log "-- node_timex metrics:"
	if ! oc get --raw "/api/v1/${node}/proxy/metrics" 2>&1 | grep -E '^node_timex_' >> "${OUT}"; then
		log "  (metrics query failed)"
	fi

	log "-- chronyd journal (tail):"
	oc adm node-logs "${node}" --unit=chronyd --tail=40 >> "${OUT}" 2>&1 || log "  (node-logs failed)"

	log "-- node state:"
	oc debug "${node}" --to-namespace="${DEBUG_NAMESPACE}" -- chroot /host bash -c '
		echo "date: $(date -u +%s.%N)"
		echo "chronyc tracking:"; chronyc tracking 2>&1 || true
		echo "chronyc sources -v:"; chronyc sources -v 2>&1 || true
		echo "ip -4 route:"; ip -4 route 2>&1 || true
		echo "resolv.conf:"; cat /etc/resolv.conf 2>&1 || true
		echo "chrony.conf:"; grep -hvE "^[[:space:]]*(#|$)" /etc/chrony.conf 2>&1 || true
	' >> "${OUT}" 2>&1 || log "  (oc debug failed)"
done

# The node-side view cannot show the proxy host, which is the default gateway
# for the machines subnet. The job owns the cluster profile SSH key.
if [[ -f "${SHARED_DIR}/BASTION_FIP" ]]; then
	BASTION_FIP=$(<"${SHARED_DIR}/BASTION_FIP")
	BASTION_USER_FROM_JOB=$(<"${SHARED_DIR}/BASTION_USER")
	log ""
	log "===== bastion ${BASTION_USER_FROM_JOB}@${BASTION_FIP}"
	ssh -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 -o BatchMode=yes \
		"${BASTION_USER_FROM_JOB}@${BASTION_FIP}" '
		echo "date: $(date -u +%s.%N)"
		echo "chronyd unit: $(systemctl is-active chronyd 2>&1)"
		echo "chronyc tracking:"; chronyc tracking 2>&1 || true
		echo "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>&1)"
		echo "nat rules:"; sudo iptables -t nat -S 2>&1 | head -30 || true
		echo "listening 53/80/123/443/3128/3130:"
		sudo ss -lntup 2>/dev/null | grep -E ":(53|80|123|443|3128|3130)\b" || true
		echo "one-shot NTP query from bastion:"
		sudo chronyd -Q "server 2.rhel.pool.ntp.org iburst" 2>&1 || true
	' >> "${OUT}" 2>&1 || log "  (bastion ssh failed)"
else
	log ""
	log "===== bastion: ${SHARED_DIR}/BASTION_FIP missing, skipped"
fi

# Do not pass silently with nothing collected.
if ! grep -q "chronyc tracking:" "${OUT}"; then
	log "ERROR: no node-level chrony data collected"
	exit 1
fi

log ""
log "===== done"
