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
  stock|wrapper) critical=0; total=0 ;;
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
live_command() {
  oc get pod -n openshift-vsphere-infra "keepalived-$1" -o json |
    jq -je '.spec.containers[]|select(.name=="keepalived")|.command[-1]'
}
if [[ $VRRP_PHASE == pilot && ( $VRRP_ARM == stock || $VRRP_ARM == wrapper ) ]]; then
  # Keep each cluster's rendered addresses and image references. Transplant only
  # the two verified shell edits, not a foreign manifest or an MCO payload.
  src=https://raw.githubusercontent.com/openshift/machine-config-operator
  template=templates/common/on-prem/files/keepalived.yaml
  head=8b31803e2bf42548e25e7a26fcdd4d9fe83c2d94
  for rev in 4cda875afc1492b907149e53905a39dee717cad4 "$head"; do
    curl -fsSL --retry 3 "$src/$rev/$template" > "$tmp/$rev"
  done
  (cd "$tmp"; sha256sum -c - <<'HASHES'
eaa462a3472decb26f433c139ccc10e7d86eada163954ce855666f687bbd247e  4cda875afc1492b907149e53905a39dee717cad4
3d3da3d062829b79d30967c3dea1cba4bb4fa787291c046b01c723dcfc277567  8b31803e2bf42548e25e7a26fcdd4d9fe83c2d94
HASHES
  )
  path=/etc/kubernetes/manifests/keepalived.yaml
  host "${nodes[0]}" "sudo cat $path" > "$tmp/stock.yaml"
  live_command "${nodes[0]}" > "$tmp/stock-command"
  python3 - "$tmp" "$VRRP_ARM" "$path" "$head" <<'PY'
import base64, hashlib, json, pathlib, re, sys, textwrap
tmp, arm, path, head = sys.argv[1:]
tmp = pathlib.Path(tmp)
versions = [(tmp/r).read_text() for r in ("4cda875afc1492b907149e53905a39dee717cad4", head)]
def apply(s, indent):
    for expression in [r"^          sigterm_handler\(\)\n.*?^          \}$", r"^(?:          trap [^\n]+\n)+"]:
        a,b=[textwrap.indent(textwrap.dedent(re.search(expression,v,re.S|re.M)[0])," "*indent) for v in versions]
        assert s.count(a)==1, "deployed wrapper does not match the tested baseline"
        if arm=="wrapper": s=s.replace(a,b)
    return s.encode()
manifest=apply((tmp/"stock.yaml").read_text(),6)
command=apply((tmp/"stock-command").read_text(),0)
for name,data in [("manifest",manifest),("command",command)]:
    (tmp/(name+".sha")).write_text(hashlib.sha256(data).hexdigest())
file={"path":path,"mode":420,"overwrite":True,"contents":{"source":"data:text/plain;base64,"+base64.b64encode(manifest).decode()}}
mc={"apiVersion":"machineconfiguration.openshift.io/v1","kind":"MachineConfig","metadata":{"name":"99-vrrp-wrapper-confirm","labels":{"machineconfiguration.openshift.io/role":"master"}},"spec":{"config":{"ignition":{"version":"3.4.0"},"storage":{"files":[file]}}}}
(tmp/"wrapper-mc.json").write_text(json.dumps(mc))
PY
  if [[ $VRRP_ARM == wrapper ]]; then
    oc create -f "$tmp/wrapper-mc.json"
    deadline=$((SECONDS+3600))
    until oc get mcp master -o json | jq -e 'any(.status.configuration.source[];.name=="99-vrrp-wrapper-confirm") and .status.configuration.name==.spec.configuration.name' >/dev/null; do
      ((SECONDS < deadline)) || die "Wrapper MachineConfig did not render"; sleep 10
    done
    wait_healthy
  fi
fi
verify_wrapper() {
  local node=$1 manifest command
  [[ -s $tmp/command.sha ]] || return 0
  manifest=$(host "$node" "sha256sum /etc/kubernetes/manifests/keepalived.yaml" | awk '{print $1}')
  command=$(live_command "$node" | sha256sum | awk '{print $1}')
  [[ $manifest == "$(<"$tmp/manifest.sha")" && $command == "$(<"$tmp/command.sha")" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "$VRRP_ARM" "$node" "$manifest" "$command" >> "$ARTIFACT_DIR/verified-wrappers.tsv"
}
# Persist state transitions in the original boot's journal: a stream through
# the API VIP may disconnect during handoff.
read -r -d '' observe <<'OBSERVE' || :
set -eu
vip=$1
read -r family table < <(nft -j list ruleset | jq -r '[.nftables[].rule? | select(.comment=="OCP_API_LB_REDIRECT") | [.family,.table]] | unique[] | @tsv' | head -1)
[[ -n $family && -n $table ]]
old=
while :; do
  addresses=$(ip -4 -o address show to "$vip/32") || exit 1
  owner=absent; [[ -z $addresses ]] || owner=present
  rules=$(nft list table "$family" "$table" 2>/dev/null) && {
    redirect=absent
    if grep -F "ip daddr $vip " <<<"$rules" | grep -F OCP_API_LB_REDIRECT >/dev/null; then redirect=present; fi
  } || {
    # A deleted table is evidence of absence only if enumeration succeeded.
    redirect=unknown
    if tables=$(nft list tables) && ! grep -Fxq "table $family $table" <<<"$tables"; then redirect=absent; fi
  }
  state="vip=$owner redirect=$redirect"
  if [[ $old != "$state" ]]; then echo "$state"; old=$state; fi
  sleep 0.5
done
OBSERVE
if [[ $VRRP_PHASE == prepare-upgrade ]]; then
  start=$(date +%s)
  holder > "$ARTIFACT_DIR/initial-holder.txt"
  for n in "${nodes[@]}"; do
    host "$n" "sudo systemd-run --unit=vrrp-upgrade-observe -p DefaultDependencies=no -p RuntimeMaxSec=4h /bin/bash -c $(printf '%q' "$observe") -- $vip"
    host "$n" "for i in {1..10}; do sudo journalctl -u vrrp-upgrade-observe --since @$start --no-pager -o cat | grep '^vip=.* redirect=present$' && exit 0; sleep 1; done; exit 1" > "$ARTIFACT_DIR/$n-observer-start.txt"
    # Preserve VRRP events in the node journal even if kubelet removes old pod logs.
    # shellcheck disable=SC2016 # Expand the container log glob and array on the node.
    host "$n" 'sudo bash -c '\''logs=(/var/log/containers/keepalived-*_openshift-vsphere-infra_keepalived-*.log); test -e "${logs[0]}" && systemd-run --unit=vrrp-upgrade-peer -p RuntimeMaxSec=4h tail -n0 -F "${logs[@]}"'\'''
    host "$n" 'cat /proc/sys/kernel/random/boot_id' > "$ARTIFACT_DIR/$n-initial-boot.txt"
  done
  printf '%s\n' "$start" > "$SHARED_DIR/vrrp-upgrade-start"
  exit 0
fi
[[ $VRRP_PHASE == pilot ]] || die "Unknown phase: $VRRP_PHASE"
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
  host "$n" "sudo journalctl -b ${boot//-/} -o short-iso-precise -u vrrp-pilot-state-$i --no-pager" |
    grep -E ']: vip=(present|absent) redirect=' > "$dir/old-state.txt"
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
  wait_healthy
  for node in "${nodes[@]}"; do verify_wrapper "$node" || die "Wrapper identity mismatch on $node"; done
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
    # The enclosing ci-operator namespace does not exist on the installed cluster.
    oc debug -n default "node/$peer" --image="$tool_image" -- timeout 1200 tcpdump -lntti any \
      "ip proto 112 and ip[((ip[0]&15)<<2)+1]=$vrid" > "$dir/advert-$peer.txt" 2>"$dir/tcpdump-$peer.err" &
    observer=$!
    workers+=("$observer")
    deadline=$((SECONDS+90))
    until grep -F "${addr[$n]} >" "$dir/advert-$peer.txt" | grep -Eq 'prio(rity)? [1-9]'; do
      kill -0 "$observer" 2>/dev/null || die "Observer exited before baseline; see tcpdump-$peer.err"
      ((SECONDS < deadline)) || die "No baseline advert from $n for VRID $vrid on $peer"; sleep 2
    done
  done
  host "$n" "sudo journalctl -b ${boot//-/} --since @$epoch -n1 --no-pager >/dev/null"
  # Capture locally on the departing host: losing the SSH connection is not
  # an address-deletion event. Keep nft output scoped to the API redirect.
  host "$n" "sudo nft -a list ruleset | grep -Ei '9445|6443' " > "$dir/redirect-before.txt"
  host "$n" "sudo systemd-run --unit=vrrp-pilot-state-$i -p DefaultDependencies=no -p RuntimeMaxSec=20m /bin/bash -c $(printf '%q' "$observe") -- $vip"
  host "$n" "for j in {1..10}; do sudo journalctl -u vrrp-pilot-state-$i -o cat --no-pager | grep -Fx 'vip=present redirect=present' && exit 0; sleep 1; done; exit 1"
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
  verify_wrapper "$n" || die "Unexpected wrapper on restarted $n"
  python3 - "$dir" "$n" "$start" "$vip" <<'PY'
import datetime as dt, pathlib, re, sys, xml.etree.ElementTree as ET
d=pathlib.Path(sys.argv[1]); node,start,vip=sys.argv[2:]
t=dt.datetime.fromisoformat(start.replace("Z","+00:00"))
suite=ET.Element("testsuite",name="vrrp-pilot")
def check(name,ok,message):
    c=ET.SubElement(suite,"testcase",name=name)
    if not ok: ET.SubElement(c,"skipped" if ok is None else "failure",message=message)
logs="\n".join(p.read_text() for p in d.glob("peer-*.log"))
kas=(d/"termination.log").read_text()
check("peer received priority zero", True if re.search(r"_API_0\) Backup received priority 0",logs) else False if re.search(r"_API_0\) Receive advertisement timeout",logs) else None,"peer timeout or missing receipt")
check("old holder removed API VIP",True if re.search(r"Deleted [^\n]* inet "+re.escape(vip)+r"/32\b",(d/"old-addr.txt").read_text()) else None,"no address deletion visible before recorder stopped")
states=re.findall(r"]: vip=(present|absent) redirect=(present|absent|unknown)",(d/"old-state.txt").read_text())
good=("absent","present"); off=("absent","absent")
ordering=False if ("present","absent") in states else True if good in states and off in states and states.index(good)<states.index(off) else None
check("VIP disappeared before API redirect", ordering, "observed stale VIP" if ordering is False else "ordering not resolved by samples")
successes=re.findall(r"I(\d{4} \d\d:\d\d:\d\d\.\d+)\s+\d+ main.go.*Termination finished with exit code 0",kas)
graceful=any(dt.datetime.strptime(str(t.year)+s,"%Y%m%d %H:%M:%S.%f").replace(tzinfo=dt.timezone.utc)>=t for s in successes)
last=kas.rstrip("-\n ").split("\n")[-1:] or [""]
check("departing API server exited gracefully", True if graceful else False if "did not terminate gracefully" in last[0] else None,"non-graceful exit or no trial-specific exit record")
probe=(d/"external-readyz.log").read_text().splitlines()
check("external client observed readiness", True if any(l.endswith(" ready") for l in probe) else None,"no successful external probe")
suite.set("tests",str(len(suite)));suite.set("failures",str(len(suite.findall(".//failure"))));suite.set("skipped",str(len(suite.findall(".//skipped"))))
ET.ElementTree(suite).write(d/"junit_vrrp.xml",encoding="utf-8",xml_declaration=True)
if suite.findall(".//failure"): sys.exit("Observed VRRP or API-server regression")
PY
  if jq -e 'length>0' "$dir/termination-events.json" >/dev/null; then die "NonGracefulTermination during trial $i"; fi
  # A peer timeout is positive evidence; no log entry is never a pass.
  echo "Inspect trial evidence; API server and VIP outcomes must be scored separately."
done
