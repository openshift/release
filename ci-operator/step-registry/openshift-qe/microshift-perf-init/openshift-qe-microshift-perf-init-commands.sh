#!/bin/bash
set -euo pipefail
# Credentials and derived URLs must never be traced.
set +x
umask 077
[[ ${ITERATIONS} =~ ^[1-5]$ ]] || { echo 'ITERATIONS must be 1..5'; exit 1; }
for var in COLD_WINDOW WARM_WINDOW SETTLE_SECONDS SWEEP_SLEEP SWEEP_CLEANUP_TIMEOUT CYCLE_BUDGET_SECONDS MIN_ITERATION_BUDGET_SECONDS; do
  value=${!var}
  [[ $value =~ ^[1-9][0-9]*$ ]] || { echo "$var must be positive integer seconds"; exit 1; }
done
[[ $PERF_ES_INDEX =~ ^[a-z0-9][a-z0-9_.-]*$ && $KUBE_BURNER_ES_INDEX =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || exit 1
# Machine class for comparisons: the self-sched QUADS model, lowercased (R640 -> r640). Self-sched
# hosts are bare metal; platform uses the go-commons spelling every perf-scale index shares.
[[ ${MODEL} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'MODEL must be a QUADS model name'; exit 1; }
perf_hardware=${MODEL,,}
perf_platform=BareMetal
for tool in git curl jq python3 tar timeout uuidgen; do
  command -v "$tool" >/dev/null || { echo "ERROR: missing required tool $tool"; exit 1; }
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || {
  echo 'ERROR: Python >= 3.9 is required before reserving hardware' >&2; exit 1;
}
perf_dir=$(mktemp -d /tmp/microshift-perf-init.XXXXXX)
trap 'rm -rf "$perf_dir"' EXIT
mkdir -p "$perf_dir" "$ARTIFACT_DIR"
cycle_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
printf '%s\n' "$cycle_id" > "${SHARED_DIR}/microshift-perf-cycle-id"
date +%s > "${SHARED_DIR}/microshift-perf-job-start"
# Resolve public release pointers once. Consumers must use the resulting concrete tags.
resolve_release_tag() {
  local project=$1 requested=$2 response tag
  if [[ $requested == latest ]]; then
    response=$(timeout -k 2 25 curl --head --fail --silent --show-error --connect-timeout 5 --max-time 20 \
      "https://github.com/$project/releases/latest") || {
      echo "ERROR: Could not resolve latest release for $project (GitHub HEAD request failed)" >&2; return 1;
    }
    # Parse the final HTTP header block (proxies may prepend a CONNECT response).
    # Never follow the redirect or accept another repository, scheme or authority.
    tag=$(printf '%s\n' "$response" | python3 -c '
import email.parser, re, sys, urllib.parse
try:
    blocks=re.split(r"\r?\n\r?\n", sys.stdin.read().strip())
    lines=blocks[-1].splitlines()
    status=re.fullmatch(r"HTTP/[0-9]+(?:\.[0-9]+)? ([0-9]{3})(?: [^\r\n]*)?", lines[0])
    if not status or int(status[1]) not in (301,302,303,307,308): raise ValueError()
    headers=email.parser.HeaderParser().parsestr("\n".join(lines[1:])+"\n\n")
    locations=headers.get_all("Location", [])
    if headers.defects or len(locations)!=1: raise ValueError()
    location=locations[0]
    if any(c.isspace() or ord(c)<32 or ord(c)==127 for c in location): raise ValueError()
    url=urllib.parse.urlsplit(location)
    if url.scheme!="https" or url.netloc!="github.com" or url.query or url.fragment: raise ValueError()
    prefix="/"+sys.argv[1]+"/releases/tag/"
    if not url.path.startswith(prefix): raise ValueError()
    tag=url.path[len(prefix):]
    if not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:[.-][a-zA-Z0-9._-]+)?",tag): raise ValueError()
    print(tag)
except (ValueError, IndexError):
    sys.exit(1)
' "$project") || {
      echo "ERROR: Could not resolve latest release for $project (missing or invalid GitHub release redirect)" >&2; return 1;
    }
  else
    tag=$requested
  fi
  [[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9._-]+)?$ ]] || {
    echo "ERROR: Invalid release tag for $project: $tag" >&2; return 1;
  }
  printf 'v%s\n' "${tag#v}"
}
# Resolve each revision once. Fetch accepts tags, branch names and reachable SHAs.
git init -q "$perf_dir/e2e"
git -C "$perf_dir/e2e" remote add origin "$E2E_REPO"
timeout -k 5 120 git -C "$perf_dir/e2e" fetch --depth=1 origin "$E2E_VERSION"
git -C "$perf_dir/e2e" checkout -q --detach FETCH_HEAD
[[ -f "$perf_dir/e2e/workloads/kube-burner-ocp-wrapper/sweep.sh" ]] || {
  echo 'Pinned e2e revision lacks QPS sweep support; merge the upstream dependency or select its review revision.'; exit 1;
}
[[ -f "$perf_dir/e2e/workloads/network-perf-v2/full-run.yaml" ]] || exit 1
git init -q "$perf_dir/profile"
git -C "$perf_dir/profile" remote add origin "$METRICS_PROFILE_REPO"
timeout -k 5 120 git -C "$perf_dir/profile" fetch --depth=1 origin "$METRICS_PROFILE_REVISION"
git -C "$perf_dir/profile" checkout -q --detach FETCH_HEAD
cp "$perf_dir/profile/cmd/config/metrics-profiles/microshift-metrics.yml" "$perf_dir/microshift-metrics.yml"
# The sweep capability check above precedes release requests and every reservation.
kube_burner_requested=$KUBE_BURNER_VERSION
netperf_requested=$NETPERF_VERSION
kube_burner_release_tag=$(resolve_release_tag kube-burner/kube-burner-ocp "$KUBE_BURNER_VERSION")
KUBE_BURNER_VERSION=${kube_burner_release_tag#v}
NETPERF_VERSION=$(resolve_release_tag cloud-bulldozer/k8s-netperf "$NETPERF_VERSION")
export KUBE_BURNER_VERSION NETPERF_VERSION
# --metrics-profile must be a file for index. Preserve the exact consumed profile.
cp "$perf_dir/microshift-metrics.yml" "$ARTIFACT_DIR/"
curl --fail --location --connect-timeout 10 --max-time 120 \
  "https://github.com/kube-burner/kube-burner-ocp/releases/download/v${KUBE_BURNER_VERSION}/kube-burner-ocp-V${KUBE_BURNER_VERSION}-Linux-x86_64.tar.gz" \
  -o "$perf_dir/kube-burner.tar.gz"
tar -xzf "$perf_dir/kube-burner.tar.gz" -C "$perf_dir" kube-burner-ocp
chmod +x "$perf_dir/kube-burner-ocp"
# One bounded write probe, no retries. Only CI executes this; local validation uses fakes.
# A receipt in our dedicated index proves its write capability without adding foreign native-tool documents.
export PERF_DIR="${SHARED_DIR}" CYCLE_ID="$cycle_id" PERF_HARDWARE="$perf_hardware" PERF_PLATFORM="$perf_platform"
if ! timeout -k 2 20 python3 - <<'PROBE'
import base64, datetime, json, os, pathlib, urllib.parse, urllib.request
p=pathlib.Path(os.environ['PERF_DIR']); s=pathlib.Path(os.environ['ES_SECRETS_PATH'])
status={'enabled':False,'reason':'credentials unavailable'}
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None
try:
    username=(s/'username').read_text().strip(); password=(s/'password').read_text().strip()
    host=(s/'host').read_text().strip() if (s/'host').exists() else 'search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com'
    endpoint=os.environ['PERF_ES_URL'] or ('https://'+host if '://' not in host else host)
    u=urllib.parse.urlsplit(endpoint)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment: raise ValueError()
    endpoint=endpoint.rstrip('/')
    credentials={'username':username,'password':password,'endpoint':endpoint}
    (p/'microshift-perf-es-credentials.json').write_text(json.dumps(credentials))
    native_url=urllib.parse.urlunsplit((u.scheme, urllib.parse.quote(username,safe='')+':'+urllib.parse.quote(password,safe='')+'@'+u.netloc,u.path.rstrip('/'),'',''))
    (p/'microshift-perf-es-url').write_text(native_url)
    body=''
    indexes=[os.environ['PERF_ES_INDEX']]
    for index in dict.fromkeys(indexes):
        body+=json.dumps({'create':{'_index':index,'_id':'microshift-ci-probe-'+os.environ['CYCLE_ID']}})+'\n'
        body+=json.dumps({'metricName':'microshiftPerfCIProbe','uuid':os.environ['CYCLE_ID'],'hardware':os.environ['PERF_HARDWARE'],'platform':os.environ['PERF_PLATFORM'],'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat()})+'\n'
    req=urllib.request.Request(endpoint+'/_bulk',data=body.encode(),headers={'Content-Type':'application/x-ndjson','Authorization':'Basic '+base64.b64encode((username+':'+password).encode()).decode()},method='POST')
    with urllib.request.build_opener(NoRedirect()).open(req,timeout=5) as response: result=json.load(response)
    items=result.get('items',[])
    if len(items)!=len(set(indexes)) or result.get('errors') or any(not 200<=v['create']['status']<300 for v in items): raise ValueError()
    status={'enabled':True,'reason':'write receipts accepted','indexes':indexes}
except Exception:
    status={'enabled':False,'reason':'write probe unavailable or refused; local artifacts only'}
(p/'microshift-perf-es-status.json').write_text(json.dumps(status)+'\n')
PROBE
then
  printf '%s\n' '{"enabled":false,"reason":"write probe exceeded 20s; local artifacts only"}' > "${SHARED_DIR}/microshift-perf-es-status.json"
fi
cp "${SHARED_DIR}/microshift-perf-es-status.json" "$ARTIFACT_DIR/"
jq -r '"ES enabled=\(.enabled): \(.reason)"' "${SHARED_DIR}/microshift-perf-es-status.json"
# The library is staged because a step-registry ref transports its commands, not sibling files.
cat > "${SHARED_DIR}/microshift-perf-library.sh" <<'LIBRARY'
set +x
perf_dir=${PERF_TOOLS_DIR:-}
export PLATFORM=microshift
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export ES_SERVER=""
# Wrappers default to offline; netperf opts into the existing QE-native upload after a successful probe.
# Scrub native-tool output before it reaches either Prow or artifacts. No raw log is archived.
redact() {
  python3 -u -c '
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]); secrets=[]
if p.exists():
 c=json.loads(p.read_text())
 for k in ("username","password"):
  if c.get(k): secrets.extend([c[k],urllib.parse.quote(c[k],safe="")])
for line in sys.stdin:
 for s in sorted(set(secrets),key=len,reverse=True): line=line.replace(s,"<redacted>")
 print(line,end="",flush=True)
' "${SHARED_DIR}/microshift-perf-es-credentials.json"
}
logged() {
  local log=$1; shift
  "$@" 2>&1 | redact | tee "$log"
}
# JSON is also valid YAML, and safely represents punctuation in credentials/profile paths.
metrics_endpoint() {
  local dest=$1 metrics_dir=$2
  python3 - "$dest" "$metrics_dir" "$perf_dir" "$SHARED_DIR" "$PROM_URL" "$KUBE_BURNER_ES_INDEX" <<'ENDPOINT'
import json,pathlib,sys
out,directory,root,shared,prom,index=sys.argv[1:]; p=pathlib.Path(root); handoff=pathlib.Path(shared)
entry={'endpoint':prom,'step':'5s','metrics':[str(p/'microshift-metrics.yml')]}
entries=[dict(entry,indexer={'type':'local','metricsDirectory':directory})]
if json.loads((handoff/'microshift-perf-es-status.json').read_text())['enabled']:
 entries.append(dict(entry,indexer={'type':'elastic','esServers':[(handoff/'microshift-perf-es-url').read_text()],'defaultIndex':index,'insecureSkipVerify':False}))
pathlib.Path(out).write_text(json.dumps(entries))
ENDPOINT
}
# Shared bounded recovery for standalone netperf and the cycle collector's interruption fallback.
collect_netperf_results() {
  export -f redact
  timeout -k 2 20 bash -c '
    set -euo pipefail
    trap '"'"'rm -f "${temporary:-}"'"'"' EXIT
    source_dir=$1; artifact_dir=$2
    [[ -d $source_dir ]] || exit 0
    while IFS= read -r -d "" file; do
      relative=${file#"$source_dir/"}
      destination="$artifact_dir/$relative"
      mkdir -p "$(dirname "$destination")"
      temporary=$(mktemp "$destination.XXXXXX")
      if redact < "$file" > "$temporary"; then mv "$temporary" "$destination"; else rm -f "$temporary"; exit 1; fi
    done < <(find "$source_dir" -maxdepth 2 -type f \( -name "*.csv" -o -name "*.json" -o -name "*.log" \) -print0)
    if [[ -f $source_dir/k8s-netperf && ! -L $source_dir/k8s-netperf ]]; then
      sha256sum "$source_dir/k8s-netperf" | sed "s|  .*|  k8s-netperf|" > "$artifact_dir/netperf-sha256.txt"
    fi
  ' -- "$1" "$2"
}
prepare_tools() {
  local manifest="${SHARED_DIR}/microshift-perf-tools.json" repo revision
  KUBE_BURNER_VERSION=$(jq -r .kube_burner_version "$manifest") || return
  NETPERF_VERSION=$(jq -r .netperf_version "$manifest") || return
  [[ $KUBE_BURNER_VERSION != latest && $NETPERF_VERSION != latest && $KUBE_BURNER_VERSION != null && $NETPERF_VERSION != null ]] || {
    echo 'ERROR: tool handoff contains an unresolved release version'; return 1;
  }
  export KUBE_BURNER_VERSION NETPERF_VERSION
  [[ -n ${perf_dir:-} && -f $perf_dir/microshift-metrics.yml ]] && return 0
  perf_dir=$(mktemp -d /tmp/microshift-perf-tools.XXXXXX)
  export PERF_TOOLS_DIR="$perf_dir"
  repo=$(jq -r .e2e_repo "$manifest"); revision=$(jq -r .e2e_sha "$manifest")
  git init -q "$perf_dir/e2e"
  git -C "$perf_dir/e2e" remote add origin "$repo"
  timeout -k 5 120 git -C "$perf_dir/e2e" fetch --depth=1 origin "$revision"
  git -C "$perf_dir/e2e" checkout -q --detach FETCH_HEAD
  [[ $(git -C "$perf_dir/e2e" rev-parse HEAD) == "$revision" ]] || { echo "ERROR: e2e revision mismatch"; return 1; }
  repo=$(jq -r .metrics_profile_repo "$manifest"); revision=$(jq -r .metrics_profile_sha "$manifest")
  git init -q "$perf_dir/profile"
  git -C "$perf_dir/profile" remote add origin "$repo"
  timeout -k 5 120 git -C "$perf_dir/profile" fetch --depth=1 origin "$revision"
  git -C "$perf_dir/profile" checkout -q --detach FETCH_HEAD
  [[ $(git -C "$perf_dir/profile" rev-parse HEAD) == "$revision" ]] || { echo "ERROR: profile revision mismatch"; return 1; }
  cp "$perf_dir/profile/cmd/config/metrics-profiles/microshift-metrics.yml" "$perf_dir/microshift-metrics.yml"
  local version
  version=$(jq -r .kube_burner_version "$manifest")
  curl --fail --location --connect-timeout 10 --max-time 120 \
    "https://github.com/kube-burner/kube-burner-ocp/releases/download/v${version}/kube-burner-ocp-V${version}-Linux-x86_64.tar.gz" -o "$perf_dir/kube-burner.tar.gz"
  [[ $(sha256sum "$perf_dir/kube-burner.tar.gz" | cut -d' ' -f1) == "$(jq -r .kube_burner_archive_sha256 "$manifest")" ]] || { echo "ERROR: kube-burner archive checksum mismatch"; return 1; }
  tar -xzf "$perf_dir/kube-burner.tar.gz" -C "$perf_dir" kube-burner-ocp
  [[ $(sha256sum "$perf_dir/kube-burner-ocp" | cut -d' ' -f1) == "$(jq -r .kube_burner_sha256 "$manifest")" ]] || { echo "ERROR: kube-burner binary checksum mismatch"; return 1; }
  chmod +x "$perf_dir/kube-burner-ocp"
  cp "$manifest" "$ARTIFACT_DIR/tools.json"
  cp "$perf_dir/microshift-metrics.yml" "$ARTIFACT_DIR/"
}

LIBRARY
# Allocate identities and the result directory before the full deployment, so iteration 1 is captured once.
jq -n --arg cycle "$cycle_id" --arg rc "${PERF_RC:-${PULL_PULL_SHA:-${MICROSHIFT_VERSION:-}}}" \
  --arg index "$PERF_ES_INDEX" --arg hardware "$perf_hardware" --arg platform "$perf_platform" --argjson es "$(cat "${SHARED_DIR}/microshift-perf-es-status.json")" \
  '{results_dir:("/tmp/microshift-perf-"+$cycle+"/iteration-1/ansible"),perf_run_id:($cycle+"-i1"),
    perf_extra_metadata:{cycle_id:$cycle,iteration:"1",rc:$rc,kube_burner_uuid:($cycle+"-i1"),netperf_uuid:($cycle+"-i1-net")},
    perf_es_index:$index,perf_hardware:$hardware,perf_platform:$platform}' > "${SHARED_DIR}/microshift-perf-install-vars.json"
# Credentials are transferred separately and never appear in this archived provenance.
jq -n --arg cycle "$cycle_id" --arg e2e_repo "$E2E_REPO" --arg profile_repo "$METRICS_PROFILE_REPO" --arg e2e "$(git -C "$perf_dir/e2e" rev-parse HEAD)" \
  --arg profile "$(git -C "$perf_dir/profile" rev-parse HEAD)" --arg kb "$KUBE_BURNER_VERSION" --arg net "$NETPERF_VERSION" --arg kb_tag "$kube_burner_release_tag" \
  --arg kb_requested "$kube_burner_requested" --arg net_requested "$netperf_requested" --arg e2e_ref "$E2E_VERSION" --arg profile_ref "$METRICS_PROFILE_REVISION" \
  --arg init_sha "$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)" --arg profile_sha "$(sha256sum "$perf_dir/microshift-metrics.yml" | cut -d' ' -f1)" --arg sha "$(sha256sum "$perf_dir/kube-burner-ocp" | cut -d' ' -f1)" --arg archive_sha "$(sha256sum "$perf_dir/kube-burner.tar.gz" | cut -d' ' -f1)" \
  '{cycle_id:$cycle,e2e_repo:$e2e_repo,e2e_sha:$e2e,e2e_ref:$e2e_ref,metrics_profile_repo:$profile_repo,metrics_profile_sha:$profile,metrics_profile_ref:$profile_ref,kube_burner_version:$kb,kube_burner_release_tag:$kb_tag,kube_burner_requested:$kb_requested,kube_burner_sha256:$sha,kube_burner_archive_sha256:$archive_sha,netperf_version:$net,netperf_requested:$net_requested,init_script_sha256:$init_sha,metrics_profile_file_sha256:$profile_sha}' > "$ARTIFACT_DIR/tools.json"

cp "$ARTIFACT_DIR/tools.json" "${SHARED_DIR}/microshift-perf-tools.json"
