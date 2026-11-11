#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Temporary diagnostic step for OSASINFRA-4617: collect node clock/NTP state on
# the proxy-externallb topology. Read-only apart from oc debug pods.

OUT="${ARTIFACT_DIR}/node-clock.txt"
: > "${OUT}"

log() { echo "$*" | tee -a "${OUT}"; }

log "===== date UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Direct view of the alert the job is expected to hit.
alert_hits=$(oc get --raw "/api/v1/namespaces/openshift-monitoring/services/https:thanos-querier:9091/proxy/api/v1/alerts" 2>/dev/null \
	| grep -o 'NodeClockNotSynchronising' | wc -l || true)
log "===== NodeClockNotSynchronising occurrences in /api/v1/alerts: ${alert_hits:-0}"

for node in $(oc get nodes -o name); do
	log ""
	log "===== ${node}"

	# node_exporter timex metrics feed the NodeClockNotSynchronising alert.
	oc get --raw "/api/v1/${node}/proxy/metrics" 2>/dev/null | grep -E '^node_timex_' >> "${OUT}" \
		|| log "  (node_timex metrics unavailable)"

	oc debug "${node}" -- chroot /host bash -c '
		echo "-- date: $(date -u +%s.%N)"
		echo "-- chronyc tracking:"; chronyc tracking 2>&1 || true
		echo "-- chronyc sources -v:"; chronyc sources -v 2>&1 || true
		echo "-- ip -4 route:"; ip -4 route 2>&1 || true
		echo "-- resolv.conf:"; cat /etc/resolv.conf 2>&1 || true
		echo "-- chrony.conf (uncommented):"; grep -hvE "^[[:space:]]*(#|$)" /etc/chrony.conf 2>&1 || true
	' >> "${OUT}" 2>&1 || log "  (oc debug failed for ${node})"
done

# The node-side view cannot show the proxy host, which is the default gateway
# for the machines subnet. The job owns the cluster profile SSH key.
if [[ -f "${SHARED_DIR}/BASTION_FIP" ]]; then
	BASTION_FIP=$(<"${SHARED_DIR}/BASTION_FIP")
	BASTION_USER=$(<"${SHARED_DIR}/BASTION_USER")
	log ""
	log "===== bastion ${BASTION_USER}@${BASTION_FIP}"
	ssh -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 "${BASTION_USER}@${BASTION_FIP}" '
		echo "-- date: $(date -u +%s.%N)"
		echo "-- chronyd unit: $(systemctl is-active chronyd 2>&1)"
		echo "-- chronyc tracking:"; chronyc tracking 2>&1 || true
		echo "-- ip_forward: $(sysctl -n net.ipv4.ip_forward 2>&1)"
		echo "-- nat rules:"; sudo iptables -t nat -S 2>&1 | head -30 || true
		echo "-- listening 53/80/123/443/3128/3130:"
		sudo ss -lntup 2>/dev/null | grep -E ":(53|80|123|443|3128|3130)\b" || true
		echo "-- one-shot NTP query from bastion:"
		sudo chronyd -Q "server 2.rhel.pool.ntp.org iburst" 2>&1 || true
	' >> "${OUT}" 2>&1 || log "  (bastion ssh failed)"
else
	log ""
	log "===== bastion: ${SHARED_DIR}/BASTION_FIP missing, skipped"
fi

log ""
log "===== done"
