#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  echo "Usage: $0 <namespace> <run-id> <new-output-directory>" >&2
  exit 2
fi
namespace=$1
run_id=$2
output_dir=$3
label_key=verification.hypershift.openshift.io/ocpstrat-2100-run
selector="app.kubernetes.io/name=ocpstrat-2100-http-workload"
if [[ ! "$run_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ||
      "$namespace" != "ocpstrat-2100-tc-012-$run_id" &&
      "$namespace" != "ocpstrat-2100-tc-014-$run_id" ]]; then
  echo "The namespace and run ID do not match a rendered workload." >&2
  exit 2
fi
if [[ -e "$output_dir" && ( ! -d "$output_dir" || -n "$(ls -A "$output_dir")" ) ]]; then
  echo "The evidence output directory must be new or empty." >&2
  exit 2
fi
mkdir -p "$output_dir/logs" "$output_dir/responses"

script_dir=$(cd "$(dirname "$0")" && pwd)
source_commit=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null || true)
deployment_json=$(oc -n "$namespace" get deployment http-workload -o json)
image=$(jq -er '.spec.template.spec.containers[] | select(.name == "workload") | .image' \
  <<< "$deployment_json")
jq -n --arg namespace "$namespace" --arg runID "$run_id" \
  --arg image "$image" --arg sourceCommit "$source_commit" \
  --arg capturedAtUTC "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{namespace:$namespace,runID:$runID,image:$image,sourceCommit:$sourceCommit,capturedAtUTC:$capturedAtUTC}' \
  > "$output_dir/metadata.json"

for resource in deployments pods services poddisruptionbudgets endpointslices events; do
  oc -n "$namespace" get "$resource" -o yaml > "$output_dir/$resource.yaml"
done
oc get nodes -l "$label_key=$run_id" -o yaml > "$output_dir/labeled-nodes.yaml"
oc -n "$namespace" get pods -o wide > "$output_dir/pod-placement.txt"

all_pods=$(oc -n "$namespace" get pods -l "$selector" -o json)
while IFS= read -r pod; do
  [[ -n "$pod" ]] || continue
  oc -n "$namespace" logs "$pod" --all-containers=true \
    > "$output_dir/logs/$pod.log" 2> "$output_dir/logs/$pod.stderr" || true
  restarts=$(jq -r --arg pod "$pod" \
    '[.items[] | select(.metadata.name == $pod) | .status.containerStatuses[]?.restartCount] | add // 0' \
    <<< "$all_pods")
  if (( restarts > 0 )); then
    oc -n "$namespace" logs "$pod" --all-containers=true --previous \
      > "$output_dir/logs/$pod.previous.log" \
      2> "$output_dir/logs/$pod.previous.stderr" || true
  fi
done < <(jq -r '.items[].metadata.name' <<< "$all_pods")

probe_number=0
probe_once() {
  local target=$1 output=$2
  probe_number=$((probe_number + 1))
  local probe_name="evidence-${run_id}-${probe_number}-$$"
  oc -n "$namespace" run "$probe_name" --rm -i --quiet --restart=Never \
    --pod-running-timeout=2m \
    --image="$image" --env="RUN_ID=$run_id" --command -- \
    /workload probe --once --timeout=5s "--url=$target" \
    > "$output" 2> "$output.stderr"
}

printf 'target\tresult\n' > "$output_dir/request-results.tsv"
if probe_once 'http://http-workload:8080/identity' \
  "$output_dir/responses/service.jsonl" &&
  jq -e --arg run "$run_id" --arg namespace "$namespace" \
    '.httpStatus == 200 and .runID == $run and .namespace == $namespace and
     (.pod | length > 0) and (.podUID | length > 0) and (.node | length > 0)' \
    "$output_dir/responses/service.jsonl" >/dev/null; then
  printf 'service\tpass\n' >> "$output_dir/request-results.tsv"
else
  printf 'service\tfail\n' >> "$output_dir/request-results.tsv"
fi

while IFS='|' read -r pod uid node ip; do
  [[ -n "$pod" ]] || continue
  output="$output_dir/responses/$pod.jsonl"
  if [[ -n "$ip" ]] && probe_once "http://$ip:8080/identity" "$output" &&
    jq -e --arg pod "$pod" --arg uid "$uid" --arg node "$node" --arg run "$run_id" \
      --arg namespace "$namespace" \
      '.httpStatus == 200 and .pod == $pod and .podUID == $uid and .node == $node and
       .runID == $run and .namespace == $namespace' "$output" >/dev/null; then
    printf '%s\tpass\n' "$pod" >> "$output_dir/request-results.tsv"
  else
    printf '%s\tfail\n' "$pod" >> "$output_dir/request-results.tsv"
  fi
done < <(jq -r '.items[] | select(.metadata.labels["app.kubernetes.io/component"] == "server") |
  [.metadata.name, .metadata.uid, .spec.nodeName // "", .status.podIP // ""] | join("|")' <<< "$all_pods")

printf 'Evidence saved in %s\n' "$output_dir"
cat "$output_dir/request-results.tsv"
