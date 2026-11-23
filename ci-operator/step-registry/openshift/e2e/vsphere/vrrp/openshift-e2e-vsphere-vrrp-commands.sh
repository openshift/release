#!/bin/bash
set -euo pipefail

die() { echo "$*" >&2; exit 1; }
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
[[ $CLUSTER_PROFILE_NAME == vsphere-elastic ]] || die "Wrong cluster profile"
infra=$(oc get infrastructure cluster -o json)
id=$(jq -er '.infraID | select(length>0)' "${SHARED_DIR}/metadata.json")
jq -e --arg id "$id" '.status.infrastructureName == $id and
  .status.platformStatus.type == "VSphere" and
  (.status.platformStatus.vsphere.vipManagement // "VRRP") != "BGP" and
  (.status.platformStatus.vsphere.loadBalancer.type // "OpenShiftManagedDefault") == "OpenShiftManagedDefault" and
  (.status.platformStatus.vsphere.apiServerInternalIPs | length) == 1' <<<"$infra" >/dev/null
vip=$(jq -r '.status.platformStatus.vsphere.apiServerInternalIPs[0]' <<<"$infra")
[[ $vip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "Pilot requires a single IPv4 API VIP"
[[ $(oc get network.config cluster -o jsonpath='{.status.networkType}') == OVNKubernetes ]] || die "Expected OVN"
masters=$(oc get nodes -l node-role.kubernetes.io/master -o json)
mapfile -t nodes < <(jq -r '.items[].metadata.name' <<<"$masters")
((${#nodes[@]} == 3)) || die "Expected three masters"
declare -A addr
tmp=$(mktemp -d)
install -m 600 "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "$tmp/key"
if ! whoami >/dev/null 2>&1 && [[ -w /etc/passwd ]]; then
  echo "vrrp:x:$(id -u):0:pilot:${HOME}:/bin/bash" >> /etc/passwd
fi
for n in "${nodes[@]}"; do
  addr[$n]=$(jq -er --arg n "$n" '.items[]|select(.metadata.name==$n)|.status.addresses[]|select(.type=="InternalIP")|.address' <<<"$masters")
done
host() {
  local node=$1; shift
  ssh -n -i "$tmp/key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$tmp/known_hosts" -o ConnectTimeout=4 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "core@${addr[$node]}" "$@"
}
healthy() {
  oc get clusterversion version -o json | jq -e '.status.history[0].state=="Completed" and any(.status.conditions[];.type=="Progressing" and .status=="False")' >/dev/null &&
    oc get mcp master -o json | jq -e '.status.machineCount==3 and .status.updatedMachineCount==3 and .status.readyMachineCount==3 and .status.degradedMachineCount==0 and .status.configuration.name==.spec.configuration.name' >/dev/null &&
    oc get nodes -l node-role.kubernetes.io/master -o json | jq -e '(.items|length)==3 and all(.items[]; any(.status.conditions[];.type=="Ready" and .status=="True") and (.metadata.annotations|.["machineconfiguration.openshift.io/state"]=="Done" and .["machineconfiguration.openshift.io/currentConfig"]==.["machineconfiguration.openshift.io/desiredConfig"]))' >/dev/null &&
    oc get co etcd kube-apiserver machine-config -o json | jq -e 'all(.items[]; all(.status.conditions[]; if .type=="Available" then .status=="True" elif .type=="Degraded" or .type=="Progressing" then .status=="False" else true end))' >/dev/null &&
    oc get pods -n openshift-etcd -l app=etcd -o json | jq -e '(.items|length)==3 and all(.items[]; any(.status.conditions[]; .type=="Ready" and .status=="True"))' >/dev/null &&
    oc exec -n openshift-etcd "etcd-${nodes[0]}" -c etcdctl -- etcdctl endpoint health --cluster -w json |
    jq -e 'length==3 and all(.[];.health==true)' >/dev/null
}
wait_healthy() {
  local until_time=$((SECONDS+1800))
  until healthy; do ((SECONDS < until_time)) || die "Control plane did not recover"; sleep 10; done
}
holder() {
  local n snapshot; local found=()
  for n in "${nodes[@]}"; do
    snapshot=$(host "$n" "ip -j addr show to $vip/32") || return 1
    if jq -e --arg v "$vip" 'any(.[]?.addr_info[]?; .local==$v)' <<<"$snapshot" >/dev/null; then found+=("$n"); fi
  done
  ((${#found[@]} == 1)) || return 1
  echo "${found[0]}"
}
config() {
  oc get --raw "/api/v1/nodes/$1/proxy/configz" | jq -e '.kubeletconfig|{shutdownGracePeriod,shutdownGracePeriodCriticalPods,shutdownGracePeriodByPodPriority}'
}
wait_healthy
oc get clusterversion version -o json | jq '{image:.status.desired.image,version:.status.desired.version}' > "$ARTIFACT_DIR/payload.json"
tool_image=$(oc get istag -n openshift tools:latest -o jsonpath='{.image.dockerImageReference}')
api_dns=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' | cut -d/ -f3 | cut -d: -f1)
pinned=(oc "--server=https://$vip:6443" "--tls-server-name=$api_dns")
"${pinned[@]}" get --raw /readyz >/dev/null
case "$VRRP_ARM" in
  stock) critical=0; total=0 ;;
  ben) critical=15; total=30 ;;
  long)
    critical=$(oc get pods -A -o json | jq -er '[.items[]|select((.spec.priority//0)>=2000000000 and (.spec.nodeName as $n | $nodes|index($n)!=null))|(.spec.terminationGracePeriodSeconds//30)] | max+30' --argjson nodes "$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s .)")
    total=$((critical+15)) ;;
  *) die "Unknown arm: $VRRP_ARM" ;;
esac
format_duration() { local s=$1; if ((s>=3600)); then printf '%dh%dm%ds' "$((s/3600))" "$((s%3600/60))" "$((s%60))"; elif ((s>=60)); then printf '%dm%ds' "$((s/60))" "$((s%60))"; else printf '%ds' "$s"; fi; }
if ((critical)); then
  oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: vrrp-pilot
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    shutdownGracePeriod: ${total}s
    shutdownGracePeriodCriticalPods: ${critical}s
EOF
fi
for n in "${nodes[@]}"; do
  deadline=$((SECONDS+3600))
  until config "$n" | jq -e --arg t "$(format_duration "$total")" --arg c "$(format_duration "$critical")" \
    '(.shutdownGracePeriod//"0s")==$t and (.shutdownGracePeriodCriticalPods//"0s")==$c and ((.shutdownGracePeriodByPodPriority//[])|length)==0' >/dev/null; do
    ((SECONDS < deadline)) || die "Budget not effective on $n"; sleep 15
  done
  config "$n" > "$ARTIFACT_DIR/$n-config.json"
  host "$n" 'systemd-inhibit --list --no-pager' > "$ARTIFACT_DIR/$n-inhibitors.txt"
  if ((critical)); then grep -i kubelet "$ARTIFACT_DIR/$n-inhibitors.txt" | grep -q shutdown || die "Missing shutdown inhibitor on $n"; fi
done
wait_healthy
declare -A boots
for node in "${nodes[@]}"; do boots[$node]=$(host "$node" 'cat /proc/sys/kernel/random/boot_id'); done
workers=()
collect() {
  local rc=$? peer pod
  trap - EXIT
  set +e
  for pid in "${workers[@]}"; do kill "$pid" 2>/dev/null; done
  for pid in "${workers[@]}"; do wait "$pid" 2>/dev/null; done
  workers=()
  # This also runs on timeouts, when evidence from a survivor matters most.
  while read -r peer pod; do
    [[ $peer != "$n" ]] || continue
    oc --request-timeout=20s logs -n openshift-vsphere-infra "$pod" -c keepalived --since-time="$start" --timestamps > "$dir/peer-$peer.log"
  done < "$dir/pods.tsv"
  for unit in addr nft; do
    host "$n" "sudo journalctl -b ${boot//-/} -o short-iso-precise -u vrrp-pilot-$unit-$i --no-pager" |
      grep -Ei "$vip|6443|9445|delete (table|chain)|Started|Stopped" > "$dir/old-$unit.txt"
  done
  host "$n" "sudo journalctl -b ${boot//-/} -o short-iso-precise -u kubelet -u crio -u systemd-logind --no-pager --since @$epoch" |
    grep -Ei 'shutdown|terminat|inhibit|keepalived' > "$dir/shutdown.txt"
  oc --request-timeout=20s adm node-logs "$n" --path=kube-apiserver/termination.log > "$dir/termination.log"
  oc --request-timeout=20s -n openshift-kube-apiserver get events --field-selector reason=NonGracefulTermination -o json |
    jq --arg t "$start" '[.items[]|select((.lastTimestamp//.eventTime//.metadata.creationTimestamp)>=$t)|{lastTimestamp,eventTime,message}]' > "$dir/termination-events.json"
  printf '<testsuite name="vrrp-evidence" tests="1" skipped="1"><testcase name="trial-%d"><skipped message="Manual correlation of peer VRID, address/redirect ordering and API termination required"/></testcase></testsuite>\n' "$i" > "$dir/junit_vrrp.xml"
  set -e
  return "$rc"
}
for i in 1 2 3; do
  healthy || die "Unhealthy before trial $i"
  for node in "${nodes[@]}"; do [[ $(host "$node" 'cat /proc/sys/kernel/random/boot_id') == "${boots[$node]}" ]] || die "Unexpected reboot on $node"; done
  n=$(holder) || die "API VIP ownership ambiguous"
  boot=${boots[$n]}
  dir="$ARTIFACT_DIR/trial-$i"; mkdir -p "$dir"
  epoch=$(date +%s)
  start=$(date -u +%FT%TZ)
  printf '%s\t%s\t%s\t%s\t%s\n' "$VRRP_ARM" "$start" "$n" "$vip" "$boot" > "$dir/trial.tsv"
  oc -n openshift-vsphere-infra get pods -l app=vsphere-infra-vrrp -o json |
    jq -r '.items[]|[.spec.nodeName,.metadata.name]|@tsv' > "$dir/pods.tsv"
  for node in "${nodes[@]}"; do grep -q "^${node}[[:space:]]" "$dir/pods.tsv" || die "No keepalived pod on $node"; done
  trap collect EXIT
  vrid=$(host "$n" 'sudo cat /etc/keepalived/keepalived.conf' |
    awk '$1=="vrrp_instance"{api=($2 ~ /_API_0$/)} api && $1=="virtual_router_id"{print $2}')
  [[ $vrid =~ ^[0-9]+$ ]] || die "Unknown API VRID"
  echo "$vrid" > "$dir/vrid"
  for peer in "${nodes[@]}"; do
    [[ $peer != "$n" ]] || continue
    # Capture headers only on survivors, matching the API instance, not ingress.
    oc debug "node/$peer" --image="$tool_image" -- timeout 1200 tcpdump -lntti any \
      "ip proto 112 and ip[((ip[0]&15)<<2)+1]=$vrid" > "$dir/advert-$peer.txt" 2>"$dir/tcpdump-$peer.err" &
    workers+=("$!")
    deadline=$((SECONDS+90))
    until grep -F "${addr[$n]} >" "$dir/advert-$peer.txt" | grep -Eq 'prio(rity)? [1-9]'; do
      ((SECONDS < deadline)) || die "No baseline advert from $n for VRID $vrid on $peer"; sleep 2
    done
  done
  host "$n" "sudo journalctl -b ${boot//-/} --since @$epoch -n1 --no-pager >/dev/null"
  # Capture locally on the departing host: losing the SSH connection is not
  # an address-deletion event. Keep nft output scoped to the API redirect.
  host "$n" "sudo nft -a list ruleset | grep -Ei '9445|6443' " > "$dir/redirect-before.txt"
  host "$n" "sudo systemd-run --unit=vrrp-pilot-addr-$i ip -ts monitor address"
  host "$n" "sudo systemd-run --unit=vrrp-pilot-nft-$i stdbuf -oL nft monitor rules"
  host "$n" "systemctl is-active --quiet vrrp-pilot-addr-$i && systemctl is-active --quiet vrrp-pilot-nft-$i"
  [[ $(holder) == "$n" ]] || die "VIP moved before reboot"
  (
    while :; do
      t=$(date -u +%FT%T.%3NZ)
      if "${pinned[@]}" --request-timeout=3s get --raw /readyz >/dev/null 2>&1; then echo "$t ready"; else echo "$t failed"; fi
      sleep 1
    done
  ) > "$dir/external-readyz.log" &
  workers+=("$!")
  "${pinned[@]}" get nodes --watch -o custom-columns=NAME:.metadata.name,RV:.metadata.resourceVersion > "$dir/external-watch.log" 2>&1 &
  workers+=("$!")
  "${pinned[@]}" -n openshift-dns get endpointslices --watch -o custom-columns='RV:.metadata.resourceVersion,NODE:.endpoints[*].nodeName,READY:.endpoints[*].conditions.ready' > "$dir/dns-endpoints.log" 2>&1 &
  workers+=("$!")
  # Submission exits before reboot; only a different boot ID counts.
  host "$n" "sudo systemd-run --on-active=3s --unit=vrrp-pilot-reboot-$i systemctl reboot"
  deadline=$((SECONDS+900))
  until after=$(host "$n" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && [[ -n $after && $after != "$boot" ]]; do
    ((SECONDS < deadline)) || die "No new boot on $n"; sleep 5
  done
  echo "$after" > "$dir/next-boot-id"
  boots[$n]=$after
  wait_healthy
  holder > "$dir/final-holder.txt" || die "Ambiguous ownership after reboot"
  collect
  if jq -e 'length>0' "$dir/termination-events.json" >/dev/null; then die "NonGracefulTermination during trial $i"; fi
  # A peer timeout is positive evidence; no log entry is never a pass.
  echo "Inspect trial evidence; API server and VIP outcomes must be scored separately."
done
