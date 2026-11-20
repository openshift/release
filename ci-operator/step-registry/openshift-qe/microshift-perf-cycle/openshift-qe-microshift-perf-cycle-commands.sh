#!/bin/bash
set -euo pipefail
set +x
umask 077
# shellcheck source=/dev/null
source "${SHARED_DIR}/microshift-perf-library.sh"
prepare_tools
perf_dir="${PERF_TOOLS_DIR:?}"
cycle_id=$(cat "${SHARED_DIR}/microshift-perf-cycle-id")
job_start=$(cat "${SHARED_DIR}/microshift-perf-job-start")
PROM_URL=${MICROSHIFT_PROMETHEUS_URL:-$(cat "${SHARED_DIR}/prometheus_url")}
bastion=$(cat "${CLUSTER_PROFILE_DIR}/address")
node=$(cat "${SHARED_DIR}/microshift_node")
ssh_args=(-i "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key" -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oConnectTimeout=10)
repo=$(jq -r '.automation_repo' "${SHARED_DIR}/microshift-perf-deploy.json")
remote_root="/tmp/microshift-perf-${cycle_id}"
private_dir=$(mktemp -d /tmp/microshift-perf-private.XXXXXX)
cycle_artifact_dir=$ARTIFACT_DIR
iteration=0
cycle_finalized=false
stage=initializing
child=""
iteration_dir=""
# Timeout/signal cleanup keeps partial artifacts and does not turn a failed iteration into success.
# shellcheck disable=SC2329 # Invoked by trap.
cleanup() {
  local rc=$?
  ARTIFACT_DIR=$cycle_artifact_dir
  trap - EXIT
  trap '' INT TERM
  if [[ -n $child ]]; then
    kill -TERM -- "-$child" 2>/dev/null || true
    # Netperf needs time to stop its own child group and archive partial results before collection.
    # timeout's leader can exit before the netperf script finishes its EXIT trap.
    timeout -k 2 25 python3 - "$child" <<'WAIT_GROUP' || true
import pathlib,sys,time
pgid=int(sys.argv[1])
while True:
    active=False
    for path in pathlib.Path('/proc').glob('[0-9]*/stat'):
        try:
            fields=path.read_text().rsplit(')',1)[1].split()
            if int(fields[2])==pgid and fields[0]!='Z':active=True;break
        except (OSError,ValueError,IndexError):continue
    if not active:break
    time.sleep(0.1)
WAIT_GROUP
    kill -KILL -- "-$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  if [[ -n $iteration_dir && ! -f "$iteration_dir/status.json" ]]; then
    record_status interrupted "$rc" || true
    collect_iteration || true
  fi
  finalize_cycle "$rc" || true
  rm -rf "$private_dir" "${PERF_TOOLS_DIR:-}"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_bounded() {
  local seconds=$1; shift
  local remaining=$((job_start+CYCLE_BUDGET_SECONDS-$(date +%s))) rc=0
  ((remaining>0)) || return 124
  ((seconds<=remaining)) || seconds=$remaining
  setsid timeout -k 15 "$seconds" "$@" &
  child=$!
  wait "$child" || rc=$?
  child=""
  return "$rc"
}
record_status() {
  jq -n --arg cycle "$cycle_id" --argjson iteration "$iteration" --arg stage "$stage" --arg status "$1" --argjson rc "$2" \
    '{cycle_id:$cycle,iteration:$iteration,stage:$stage,status:$status,exit_code:$rc}' > "$iteration_dir/status.json"
}
copy_sweep_artifacts() {
  # Even a failed QPS step leaves summaries and partial local metrics behind.
  for work in "$private_dir/node-density" "$private_dir/node-density-cni"; do
    [[ -d $work/workloads/kube-burner-ocp-wrapper ]] || continue
    find "$work/workloads/kube-burner-ocp-wrapper" -maxdepth 1 \( -name 'sweep-*.json' -o -name 'collected-metrics-*' \) -exec cp -r '{}' "$iteration_dir/" \;
    # shellcheck disable=SC2094 # Source is private work tree; destination is artifact tree.
    for log in "$work/workloads/kube-burner-ocp-wrapper"/sweep-*.log; do
      [[ -f $log ]] || continue
      redact < "$log" > "$iteration_dir/$(basename "$log")"
    done
    rm -rf "$work"
  done
}
collect_iteration() {
  copy_sweep_artifacts
  # The cycle owns this work tree: recover partial files even if the runner's EXIT trap was interrupted.
  if [[ -d $private_dir/netperf-work ]]; then
    if [[ -f $private_dir/netperf-work/.native-pgid ]]; then
      local native_pgid
      native_pgid=$(cat "$private_dir/netperf-work/.native-pgid")
      if [[ $native_pgid =~ ^[0-9]+$ && $native_pgid != "$BASHPID" && $native_pgid != "$$" ]]; then
        kill -TERM -- "-$native_pgid" 2>/dev/null || true
        sleep 2
        kill -KILL -- "-$native_pgid" 2>/dev/null || true
      fi
    fi
    mkdir -p "$iteration_dir/netperf"
    collect_netperf_results "$private_dir/netperf-work/workloads/network-perf-v2" "$iteration_dir/netperf" || true
    rm -rf "$private_dir/netperf-work"
  fi
  # Each invocation has a deadline, including a hung SSH. Never traverse secrets, kubeconfig or symlinks.
  timeout -k 5 60 scp "${ssh_args[@]}" -r "root@$bastion:$remote_root/iteration-$iteration/ansible" "$iteration_dir/" 2>/dev/null || true
  timeout -k 5 30 ssh "${ssh_args[@]}" "root@$bastion" "ssh -oConnectTimeout=10 root@'$node' 'journalctl -u microshift -u crio --no-pager -n 3000'" > "$iteration_dir/service-journal.txt" 2>/dev/null || true
  timeout -k 5 10 oc --request-timeout=10s get events -A -o json > "$iteration_dir/events.json" 2>/dev/null || true
  timeout -k 5 10 oc --request-timeout=10s get pods -A -o wide > "$iteration_dir/pods.txt" 2>/dev/null || true
  timeout -k 5 10 ssh "${ssh_args[@]}" "root@$bastion" "ssh -oConnectTimeout=10 root@'$node' 'df -h; rpm -qa | sort; sha256sum /usr/bin/microshift; systemctl show microshift -p ActiveState -p NRestarts'" > "$iteration_dir/host-state.txt" 2>/dev/null || true
  timeout -k 5 20 bash -c '
    oc --request-timeout=5s get pods -A -o json | jq -r "[.items[]] | sort_by(.metadata.namespace | if startswith(\"openshift-\") or startswith(\"kube-\") then 0 else 1 end) | .[] | [.metadata.namespace,.metadata.name] | @tsv" |
      while read -r namespace pod; do
        printf "### %s/%s\n" "$namespace" "$pod"
        oc --request-timeout=5s logs -n "$namespace" "$pod" --all-containers --tail=100 --limit-bytes=32768 || true
      done
  ' > "$iteration_dir/pod-logs.txt" 2>/dev/null || true
  timeout -k 5 30 tar -czf "${ARTIFACT_DIR}/iteration-${iteration}.tar.gz" -C "$ARTIFACT_DIR" "iteration-$iteration"
  (cd "$ARTIFACT_DIR"; sha256sum "iteration-${iteration}.tar.gz" > "iteration-${iteration}.tar.gz.sha256")
}
# Check every expected target, not just a nonempty subset of up metrics.
preflight() {
  local output="$iteration_dir/targets-${stage}.json"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "$PROM_URL/api/v1/targets" > "$output" || return
  local up_output="$iteration_dir/up-${stage}.json"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 10 --get \
    --data-urlencode 'query=up{job=~"node|process|crio|kubelet-microshift|kubelet-microshift-cadvisor"}' \
    "$PROM_URL/api/v1/query" > "$up_output" || return
  python3 - "$output" "$node" "$up_output" <<'TARGETS'
import json,sys,urllib.parse
j=json.load(open(sys.argv[1])); assert j['status']=='success'; targets=j['data']['activeTargets']; node=sys.argv[2]
for job in ('node','process','crio','kubelet-microshift','kubelet-microshift-cadvisor'):
 matches=[t for t in targets if t.get('labels',{}).get('job')==job]
 if any(urllib.parse.urlsplit(t.get('scrapeUrl','')).hostname!=node for t in matches):
  print('ERROR: scrape target belongs to another host: '+job);sys.exit(1)
 if not matches or any(t.get('health')!='up' for t in matches):
  print('ERROR: required Prometheus target unavailable: '+job); sys.exit(1)
u=json.load(open(sys.argv[3])); assert u['status']=='success'
for job in ('node','process','crio','kubelet-microshift','kubelet-microshift-cadvisor'):
 values=[t for t in u['data']['result'] if t.get('metric',{}).get('job')==job]
 if len(values)!=len([t for t in targets if t.get('labels',{}).get('job')==job]) or any(float(t['value'][1])!=1 for t in values):
  print('ERROR: required Prometheus up metric missing or not 1: '+job);sys.exit(1)
TARGETS
}
ready() {
  run_bounded 330 oc --request-timeout=15s wait node --all --for=condition=Ready --timeout=300s || return
  [[ $(oc --request-timeout=15s get pods -A -o json | jq '.items|length') -gt 0 ]] || return 1
  # Completed pods are not readiness targets; wait for workload cleanup to remove terminating ones.
  for _ in $(seq 1 60); do
    if oc --request-timeout=15s get pods -A -o json | jq -e 'all(.items[]; .metadata.deletionTimestamp == null)' >/dev/null; then break; fi
    run_bounded 10 sleep 5 || return
  done
  oc --request-timeout=15s get pods -A -o json | jq -e 'all(.items[]; .metadata.deletionTimestamp == null)' >/dev/null || return
  run_bounded 330 oc --request-timeout=15s wait pods --all -A --field-selector=status.phase!=Succeeded --for=condition=Ready --timeout=300s || return
  run_bounded 20 ssh "${ssh_args[@]}" "root@$bastion" "ssh -oConnectTimeout=10 root@'$node' 'systemctl is-active --quiet microshift'"
}
install_iteration() {
  local vars="$private_dir/install-vars.json" creds="$private_dir/es-credentials.json"
  jq --arg iteration "$iteration" --arg result "$remote_root/iteration-$iteration/ansible" --arg run "$cycle_id-i$iteration" \
     '. + {results_dir:$result,perf_run_id:$run,manage_repos:false,setup_microshift_host:false} |
      .perf_extra_metadata.iteration=$iteration | .perf_extra_metadata.kube_burner_uuid=$run | .perf_extra_metadata.netperf_uuid=($run+"-net")' \
     "${SHARED_DIR}/microshift-perf-install-vars.json" > "$vars"
  jq -s '.[0] + .[1].install_vars | .perf_extra_metadata.version=.microshift_version' "$vars" "${SHARED_DIR}/microshift-perf-deploy.json" > "$vars.tmp"
  mv "$vars.tmp" "$vars"
  local inventory playbook
  inventory=$(jq -r .ansible_inventory "${SHARED_DIR}/microshift-perf-deploy.json")
  playbook=$(jq -r .ansible_playbook "${SHARED_DIR}/microshift-perf-deploy.json")
  local remote_vars="$remote_root/iteration-$iteration/vars.json"
  run_bounded 30 ssh "${ssh_args[@]}" "root@$bastion" "mkdir -p '$remote_root/iteration-$iteration'; chmod 700 '$remote_root/iteration-$iteration'" || return
  if jq -e '.enabled' "${SHARED_DIR}/microshift-perf-es-status.json" >/dev/null; then
    cp "${SHARED_DIR}/microshift-perf-es-credentials.json" "$creds"
    jq --arg path "$remote_root/iteration-$iteration/credentials.json" --arg url "$(jq -r .endpoint "$creds")" \
      '. + {perf_es_credentials_file:$path,perf_es_url:$url}' "$vars" > "$vars.tmp"
    mv "$vars.tmp" "$vars"
    run_bounded 30 scp "${ssh_args[@]}" "$creds" "root@$bastion:$remote_root/iteration-$iteration/credentials.json" || return
  fi
  run_bounded 30 scp "${ssh_args[@]}" "$vars" "root@$bastion:$remote_vars" || return
  # Start at the first static task of install-microshift. Controller/repository/host setup is skipped;
  # later plays still recreate logging and its service-account token after the fresh install.
  run_bounded 7200 ssh "${ssh_args[@]}" "root@$bastion" "bash -c 'set -e; trap \"rm -f $remote_root/iteration-$iteration/credentials.json $remote_vars\" EXIT HUP INT TERM; cd $repo/ansible; ansible-playbook -i $inventory $playbook --start-at-task \"Gather installed package facts\" -e @$remote_vars; scp root@$node:/var/lib/microshift/resources/kubeadmin/$node/kubeconfig $remote_root/iteration-$iteration/kubeconfig'" || return
  run_bounded 30 scp "${ssh_args[@]}" "root@$bastion:$remote_root/iteration-$iteration/kubeconfig" "$KUBECONFIG" || return
  # Confirm immutable PR provenance after every reinstall.
  if jq -e '.install_vars.build_microshift' "${SHARED_DIR}/microshift-perf-deploy.json" >/dev/null; then
    run_bounded 20 ssh "${ssh_args[@]}" "root@$bastion" "ssh root@'$node' 'microshift version -o yaml'" > "$iteration_dir/microshift-version.yaml" || return
    local sha
    sha=$(awk '$1=="gitCommit:" {gsub(/[\047\042]/,"",$2);print $2}' "$iteration_dir/microshift-version.yaml")
    [[ $sha == "$(jq -r .install_vars.microshift_git_revision "${SHARED_DIR}/microshift-perf-deploy.json")" ]] || { echo 'ERROR: installed binary does not match PR head'; return 1; }
  fi
}
window() {
  local kind=$1 seconds=$2 start_epoch end_epoch record_tmp record_rc uuid="$cycle_id-i$iteration-$1"
  stage="$kind-ready"; ready || return
  stage="$kind-preflight"; preflight || return
  stage="$kind-window"; start_epoch=$(date +%s) || return
  run_bounded "$((seconds+30))" sleep "$seconds" || return
  end_epoch=$(date +%s) || return
  stage="$kind-window-record"
  record_tmp=$(mktemp "$iteration_dir/.window-$kind.XXXXXX") || return
  jq -n --arg kind "$kind" --arg uuid "$uuid" --argjson start_epoch "$start_epoch" --argjson end_epoch "$end_epoch" \
    '{phase:$kind,uuid:$uuid,start_epoch:$start_epoch,end_epoch:$end_epoch,step_seconds:5,all_pods_ready:true}' > "$record_tmp" || {
      record_rc=$?; rm -f "$record_tmp"; return "$record_rc";
    }
  mv "$record_tmp" "$iteration_dir/window-$kind.json" || {
    record_rc=$?; rm -f "$record_tmp"; return "$record_rc";
  }
  stage="$kind-preflight-end"; preflight || return
  stage="$kind-index"
  run_bounded 600 "$perf_dir/kube-burner-ocp" index --start="$start_epoch" --end="$end_epoch" --step=5s \
    --metrics-profile="$perf_dir/microshift-metrics.yml" --prometheus-url="$PROM_URL" --uuid="$uuid" \
    --job-name="$kind-steady-state" --metrics-directory="$iteration_dir/collected-metrics-$uuid" --alerting=false || return
  if jq -e '.enabled' "${SHARED_DIR}/microshift-perf-es-status.json" >/dev/null; then
    local endpoint="$private_dir/$kind-endpoint.json"
    metrics_endpoint "$endpoint" "$private_dir/es-window-metrics"
    python3 - "$endpoint" <<'ES_ONLY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(json.dumps([e for e in json.loads(p.read_text()) if e['indexer']['type']!='local']))
ES_ONLY
    # Native index selects a single summary indexer. The first call guarantees its offline summary.
    # An ES outage after the initial probe must not discard a successfully captured idle window.
    if ! run_bounded 60 "$perf_dir/kube-burner-ocp" index --start="$start_epoch" --end="$end_epoch" --step=5s \
      --metrics-profile="$perf_dir/microshift-metrics.yml" --metrics-endpoint="$endpoint" --uuid="$uuid" \
      --job-name="$kind-steady-state" --metrics-directory="$iteration_dir/collected-metrics-$uuid" --alerting=false; then
      echo 'WARNING: optional ES window indexing failed; disabling subsequent uploads'
      printf '%s\n' '{"enabled":false,"reason":"runtime indexing failure; local artifacts retained"}' > "${SHARED_DIR}/microshift-perf-es-status.json"
      export ES_SERVER=""
    fi
  fi
}
sweep() {
  local workload=$1 uuid="$cycle_id-i$iteration"
  [[ $workload == node-density-cni ]] && uuid+="-cni"
  stage="$workload-preflight"; preflight || return
  stage="$workload"
  local work="$private_dir/$workload" endpoint="$private_dir/$workload-endpoint.json"
  mkdir -p "$work/kube-bin" || return
  cp -a "$perf_dir/e2e/." "$work/"
  # Each sweep step needs its own local metrics directory. Native --local-indexing sets it from UUID;
  # an endpoint-local indexer also receives the metrics and is overwritten below per sweep runner.
  metrics_endpoint "$endpoint" 'collected-metrics-{{.UUID}}'
  local flags="--metrics-profile=$perf_dir/microshift-metrics.yml --metrics-endpoint=$endpoint --local-indexing --alerting=false --pods-per-node=245"
  [[ $workload == node-density ]] && flags+=" --pod-ready-threshold=180000ms"
  pushd "$work/workloads/kube-burner-ocp-wrapper" >/dev/null
  local rc=0
    # Endpoint YAML carries optional ES indexing. Keep wrapper metadata indexing offline.
  run_bounded 7200 env ES_SERVER= UUID="$uuid" WORKLOAD="$workload" QPS_LIST='2 4 6 8 10 12 14 16 18 20' \
    KUBE_BURNER_VERSION="$KUBE_BURNER_VERSION" KUBE_BURNER_URL="file://$perf_dir/kube-burner.tar.gz" KUBE_DIR="$work/kube-bin" EXTRA_FLAGS="$flags" \
    SWEEP_SLEEP="$SWEEP_SLEEP" SWEEP_CLEANUP_TIMEOUT="$SWEEP_CLEANUP_TIMEOUT" bash ./run.sh || rc=$?
  popd >/dev/null
  return "$rc"
}
iteration_run() {
  if ((iteration>1)); then stage=install; install_iteration || return; fi
  stage=ready; ready || return
  window cold "$COLD_WINDOW" || return
  sweep node-density || return
  sweep node-density-cni || return
  stage=settle; run_bounded "$((SETTLE_SECONDS+30))" sleep "$SETTLE_SECONDS" || return
  stage=netperf-preflight; preflight || return
  stage=netperf
  NETPERF_WORK_DIR="$private_dir/netperf-work" NETPERF_STAGE_ONLY=false NETPERF_UUID="$cycle_id-i$iteration-net" ARTIFACT_DIR="$iteration_dir/netperf" \
    run_bounded "$((NETPERF_TIMEOUT_SECONDS+30))" bash "${SHARED_DIR}/microshift-perf-netperf.sh" || return
  ready || return
  window warm "$WARM_WINDOW" || return
}

finalize_cycle() {
  [[ $cycle_finalized == false ]] || return 0
  cycle_finalized=true
  local capture_rc=$1
  python3 - "$ARTIFACT_DIR" "$SHARED_DIR" "$ITERATIONS" "$capture_rc" "$node" "${BASH_SOURCE[0]}" <<'MANIFEST' || return
import datetime,hashlib,json,pathlib,sys,tempfile
root,shared,requested,rc,node,script=sys.argv[1:];root=pathlib.Path(root);shared=pathlib.Path(shared);requested=int(requested)
artifact_errors=[]
def problem(p,reason):
    artifact_errors.append({'path':str(p.relative_to(root)) if p.is_relative_to(root) else p.name,'reason':reason})
def read(p,default=None):
    if not p.exists(): return default
    try:
        value=json.loads(p.read_text())
        if default is not None and not isinstance(value,type(default)):
            raise ValueError('unexpected JSON type')
        return value
    except (OSError,UnicodeError,ValueError):
        problem(p,'unreadable or malformed JSON');return default
pins=read(shared/'microshift-perf-tools.json',{});deployment=read(shared/'microshift-perf-deploy.json',{})
install=read(shared/'microshift-perf-install-vars.json',{})
# Declared once by init (MODEL lowercased, platform BareMetal); unknown stays null, never inferred.
dimensions={k:(install.get('perf_'+k) if isinstance(install.get('perf_'+k),str) and install.get('perf_'+k) else None) for k in ('hardware','platform')}
iterations=[];environment={**dimensions,'host':node};net_hashes=set()
for n in range(1,requested+1):
    directory=root/f'iteration-{n}';error_start=len(artifact_errors)
    status=read(directory/'status.json',{'status':'not-run'})
    if status.get('status') not in ('complete','invalid','interrupted','not-run'):
        problem(directory/'status.json','malformed iteration status')
    workloads=[];sweeps=[];windows=[]
    for p in sorted(directory.glob('sweep-*.json')):
        for step in read(p,[]):
            if (not isinstance(step,dict) or not all(isinstance(step.get(k),str) for k in ('uuid','workload'))
                or not all(type(step.get(k)) is int for k in ('qps','burst'))):
                problem(p,'malformed sweep step');continue
            sweeps.append(step)
            workloads.append({k:step[k] for k in ('uuid','workload','qps','burst')})
            workloads[-1]['step_seconds']=5
    for phase in ('cold','warm'):
        p=directory/f'window-{phase}.json'
        if p.exists():
            window=read(p,{})
            if (window.get('phase')!=phase or not isinstance(window.get('uuid'),str)
                or not all(type(window.get(k)) is int for k in ('start_epoch','end_epoch','step_seconds'))
                or window.get('step_seconds')!=5 or window.get('all_pods_ready') is not True
                or window.get('end_epoch',0)<window.get('start_epoch',0)):
                problem(p,'malformed window record')
            else:windows.append(window)
    for p in directory.rglob('measurements.ndjson'):
        try: lines=p.read_text().splitlines()
        except (OSError,UnicodeError): problem(p,'unreadable measurements');continue
        for line in lines:
            if not line.strip():continue
            try:
                doc=json.loads(line)
                if not isinstance(doc,dict):raise ValueError('unexpected JSON type')
            except ValueError:problem(p,'malformed measurement line');continue
            for src,dst in [('kernel','kernel'),('rhel_release','rhel'),('cpu_model','cpu')]:
                if doc.get(src):environment[dst]=doc[src]
    for p in directory.rglob('netperf-sha256.txt'):
        try:
            value=p.read_text().split()[0]
            if len(value)!=64 or any(c not in '0123456789abcdef' for c in value):raise ValueError('invalid hash')
            net_hashes.add(value)
        except (OSError,UnicodeError,ValueError,IndexError):problem(p,'malformed binary checksum')
    iterations.append({'id':str(n),'path':directory.name,'status':'invalid' if len(artifact_errors)>error_start else status.get('status','invalid'),'workloads':workloads,'windows':windows,
                       'netperf_uuids':[pins.get('cycle_id','unknown')+f'-i{n}-net'] if (directory/'netperf/netperf.log').exists() else [],'sweeps':sweeps})
source=pathlib.Path(script).read_bytes()
for name in ('microshift-perf-library.sh','microshift-perf-netperf.sh'):
    try:source+=(shared/name).read_bytes()
    except OSError:problem(shared/name,'missing pipeline source')
source+=pins.get('init_script_sha256','').encode()+deployment.get('deployment_script_sha256','').encode()
manifest={'schema_version':1,'measurement_type':'report_cycle','status':'complete' if rc=='0' and not artifact_errors and all(i['status']=='complete' for i in iterations) else 'incomplete',
          'hardware':dimensions['hardware'],'platform':dimensions['platform'],
          'cycle_id':pins.get('cycle_id'),'release':deployment.get('install_vars',{}).get('microshift_version','unknown'),
          'rc':install.get('perf_extra_metadata',{}).get('rc',''),'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'environment':environment,'tool_pins':{
              'kube-burner-ocp':{'version':pins.get('kube_burner_version'),'release_tag':pins.get('kube_burner_release_tag'),'sha256':pins.get('kube_burner_sha256'),'archive_sha256':pins.get('kube_burner_archive_sha256')},
              'k8s-netperf':{'version':pins.get('netperf_version'),'release_tag':pins.get('netperf_version'),'sha256':next(iter(net_hashes)) if len(net_hashes)==1 else None,'observed_sha256':sorted(net_hashes)},
              'e2e-benchmarking':{'version':pins.get('e2e_sha'),'requested_ref':pins.get('e2e_ref')},
              'metrics-profile':{'version':pins.get('metrics_profile_sha'),'requested_ref':pins.get('metrics_profile_ref'),'sha256':pins.get('metrics_profile_file_sha256')},
              'pipeline':{'version':'openshift-qe-microshift-perf','sha256':hashlib.sha256(source).hexdigest()}},
          'expected':{'min_iterations':3,'workloads':['node-density','node-density-cni'],'qps':list(range(2,21,2)),'pods_per_node':245,'netperf_tests':29},
          'iterations':iterations,'artifact_errors':artifact_errors}
with tempfile.NamedTemporaryFile(mode='w',dir=root,prefix='.cycle.json.',delete=False) as output:
    temporary=pathlib.Path(output.name)
    try:
        output.write(json.dumps(manifest,indent=2)+'\n');output.flush()
        temporary.replace(root/'cycle.json')
    finally:temporary.unlink(missing_ok=True)
if artifact_errors:print('WARNING: partial artifacts were malformed; cycle manifest is incomplete')
MANIFEST
  # Malformed artifacts discovered only during finalization must also fail an otherwise successful job.
  if ((capture_rc==0)) && ! jq -e '.status=="complete"' "$ARTIFACT_DIR/cycle.json" >/dev/null; then return 1; fi
  # The completion marker belongs only to our measurements index, after local capture/bundles finish.
  # It attests capture completion; the report consumer still validates actual metric coverage.
  if jq -e '.status=="complete"' "$ARTIFACT_DIR/cycle.json" >/dev/null && jq -e '.enabled' "${SHARED_DIR}/microshift-perf-es-status.json" >/dev/null; then
    if ! timeout -k 2 20 python3 - "$ARTIFACT_DIR/cycle.json" "$SHARED_DIR" "$PERF_ES_INDEX" <<'PUBLISH'
import base64,json,pathlib,sys,urllib.request
manifest=pathlib.Path(sys.argv[1]);shared=pathlib.Path(sys.argv[2]);doc=json.loads(manifest.read_text())
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None
try:
    c=json.loads((shared/'microshift-perf-es-credentials.json').read_text())
    body=json.dumps({'index':{'_index':sys.argv[3],'_id':doc['cycle_id']}})+'\n'+json.dumps(doc)+'\n'
    req=urllib.request.Request(c['endpoint'].rstrip('/')+'/_bulk',data=body.encode(),method='POST',headers={'Content-Type':'application/x-ndjson','Authorization':'Basic '+base64.b64encode((c['username']+':'+c['password']).encode()).decode()})
    with urllib.request.build_opener(NoRedirect()).open(req,timeout=5) as response:result=json.load(response)
    assert not result.get('errors') and len(result.get('items',[]))==1 and 200<=result['items'][0]['index']['status']<300
except Exception:
    print('WARNING: report_cycle completion upload failed; cycle.json is the local record')
    sys.exit(1)
PUBLISH
    then echo 'WARNING: optional completion marker unavailable; use the local cycle manifest'; fi
  fi
}

failed=0
for ((iteration=1; iteration<=ITERATIONS; iteration++)); do
  remaining=$((job_start+CYCLE_BUDGET_SECONDS-$(date +%s)))
  if ((remaining<MIN_ITERATION_BUDGET_SECONDS)); then
    echo "Insufficient cycle budget for iteration $iteration: ${remaining}s remaining"; failed=1; break
  fi
  iteration_dir="$ARTIFACT_DIR/iteration-$iteration"
  mkdir -p "$iteration_dir"
  stage=initializing
  rc=0
  # Do not depend on errexit inside conditional function calls; every stage propagates failures explicitly.
  exec {saved_stdout}>&1 {saved_stderr}>&2
  exec > >(redact | tee "$iteration_dir/iteration.log") 2>&1
  log_pid=$!
  iteration_run || rc=$?
  exec 1>&"$saved_stdout" 2>&"$saved_stderr"
  exec {saved_stdout}>&- {saved_stderr}>&-
  wait "$log_pid" || true
  if ((rc)); then failed=1; record_status invalid "$rc"; else record_status complete 0; fi
  collect_iteration
  if [[ ! -s "$iteration_dir/ansible/measurements.ndjson" ]]; then
    failed=1
    # Preserve the primary stage/exit code when installation or a workload already failed.
    if ((rc==0)); then
      stage=artifact-collection
      record_status invalid 1
      echo "ERROR: iteration $iteration has no structured Ansible measurements; upstream indexing dependency required"
    else
      echo "WARNING: iteration $iteration has no structured Ansible measurements after $stage failed (exit $rc); primary failure retained"
    fi
    timeout -k 5 30 tar -czf "${ARTIFACT_DIR}/iteration-${iteration}.tar.gz" -C "$ARTIFACT_DIR" "iteration-$iteration"
    (cd "$ARTIFACT_DIR"; sha256sum "iteration-${iteration}.tar.gz" > "iteration-${iteration}.tar.gz.sha256")
  fi
  iteration_dir=""
done
finalize_cycle "$failed"
exit "$failed"
