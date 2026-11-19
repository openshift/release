#!/bin/bash

set -euo pipefail
# Cluster kubeconfigs, proxy settings, and route hosts must not enter CI logs.
set +x

if [[ ! -s "$SHARED_DIR/nested_kubeconfig" ||
      ! -s "$SHARED_DIR/kubeconfig" ||
      ! -s "$SHARED_DIR/nutanix_proxy_url" ||
      ! -s "$SHARED_DIR/nutanix_subnet_cidr" ||
      ! -s "$SHARED_DIR/nutanix_worker_names" ||
      ! -s "$SHARED_DIR/hosted_kube-apiserver_port" ]]; then
  echo "The guest kubeconfigs or Nutanix worker network inputs are missing."
  exit 1
fi

valid_ipv4() {
  awk -F. 'NF == 4 {
    for (i = 1; i <= 4; i++)
      if ($i !~ /^[0-9]+$/ || $i > 255) exit 1
    exit 0
  } { exit 1 }' <<< "$1"
}

valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ &&
     "$1" != *..* ]]
}

expected_proxy=$(<"$SHARED_DIR/nutanix_proxy_url")
if [[ "$expected_proxy" =~ ^http://([0-9.]+):([0-9]+)$ ]]; then
  proxy_ip=${BASH_REMATCH[1]}
  proxy_port=${BASH_REMATCH[2]}
else
  echo "The recorded Nutanix proxy URL is invalid."
  exit 1
fi
if ! valid_ipv4 "$proxy_ip" || (( proxy_port < 1 || proxy_port > 65535 )); then
  echo "The recorded Nutanix proxy endpoint is invalid."
  exit 1
fi

subnet_cidr=$(<"$SHARED_DIR/nutanix_subnet_cidr")
subnet_ip=${subnet_cidr%/*}
if [[ ! "$subnet_cidr" =~ ^([0-9]+\.){3}[0-9]+/([1-9]|[12][0-9]|3[0-2])$ ]] ||
   ! valid_ipv4 "$subnet_ip"; then
  echo "The Nutanix worker subnet CIDR is invalid."
  exit 1
fi

vip=$(jq -er '.vip' "$SHARED_DIR/nutanix_ingress_tunnel_state.json")
if ! valid_ipv4 "$vip"; then
  echo "The Nutanix ingress VIP is invalid."
  exit 1
fi

export KUBECONFIG="$SHARED_DIR/nested_kubeconfig"
proxy_json=$(oc get proxy cluster -o json)
if ! jq -e --arg proxy "$expected_proxy" '
  .spec.httpProxy == $proxy and .spec.httpsProxy == $proxy and
  .status.httpProxy == $proxy and .status.httpsProxy == $proxy and
  (.status.noProxy | type == "string" and length > 0)
' <<< "$proxy_json" >/dev/null; then
  echo "The guest Proxy configuration does not match the Nutanix Squid endpoint."
  exit 1
fi
expected_no_proxy=$(jq -r '.status.noProxy' <<< "$proxy_json")
if [[ ",$expected_no_proxy," != *",$subnet_cidr,"* ]]; then
  echo "The guest Proxy status omits the Nutanix worker subnet CIDR."
  exit 1
fi
proxy_hash=$(printf '%s' "$expected_proxy" | sha256sum | cut -d' ' -f1)
no_proxy_hash=$(printf '%s' "$expected_no_proxy" | sha256sum | cut -d' ' -f1)

canary_json=$(oc get route canary -n openshift-ingress-canary -o json)
canary_host=$(jq -r \
  '[.status.ingress[]? | select(.routerName == "default") | .host // empty] | first // empty' \
  <<< "$canary_json")
api_server=$(oc config view --kubeconfig="$SHARED_DIR/nested_kubeconfig" --raw -o json |
  jq -r '.clusters[0].cluster.server // empty')
if [[ "$api_server" =~ ^https://([A-Za-z0-9.-]+)(:[0-9]+)?$ ]]; then
  api_host=${BASH_REMATCH[1]}
else
  echo "The guest kubeconfig has no valid HTTPS API host."
  exit 1
fi
api_port=$(<"$SHARED_DIR/hosted_kube-apiserver_port")
if [[ ! "$api_port" =~ ^[0-9]+$ ]] || (( api_port < 1 || api_port > 65535 )); then
  echo "The hosted API NodePort is invalid."
  exit 1
fi

assisted_routes=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get routes -A -o json)
assisted_host=$(jq -r '
  [.items[] |
    select(.metadata.namespace == "multicluster-engine" or
           .metadata.namespace == "openshift-multicluster-engine") |
    select((((.metadata.name // "") + " " + (.spec.to.name // "")) |
      test("assisted[-.]service"; "i"))) |
    select(.spec.tls != null) |
    .spec.host // empty] |
  unique | if length == 1 then .[0] else empty end
' <<< "$assisted_routes")
if ! valid_host "$canary_host" || ! valid_host "$assisted_host" || ! valid_host "$api_host"; then
  echo "The canary, Assisted Service, or hosted API host is missing or invalid."
  exit 1
fi

worker_count=$(awk 'NF { count++ } END { print count + 0 }' \
  "$SHARED_DIR/nutanix_worker_names")
if (( worker_count < 1 )); then
  echo "The Nutanix worker count is invalid."
  exit 1
fi
nodes_json=$(oc get nodes -o json)
if ! jq -e --argjson count "$worker_count" '
  (.items | length) == $count and
  all(.items[];
    (.metadata.name | test("^[a-z0-9][a-z0-9.-]*$")) and
    any(.status.conditions[]?; .type == "Ready" and .status == "True"))
' <<< "$nodes_json" >/dev/null; then
  echo "The guest does not have exactly the expected number of Ready Nutanix workers."
  exit 1
fi
mapfile -t nodes < <(jq -r '.items[].metadata.name' <<< "$nodes_json")

# The script is passed as an argument to oc debug. It runs inside each RHCOS
# host network and uses only the host's proxy file and installed CA material.
worker_probe=$(cat <<'WORKER'
set -uo pipefail
set +x
umask 077

proxy_hash=$1
no_proxy_hash=$2
proxy_ip=$3
vip=$4
subnet_cidr=$5
canary_host=$6
assisted_host=$7
api_host=$8
api_port=$9
failed=0
temp_ca=
trap 'if [[ -n "$temp_ca" ]]; then rm -f "$temp_ca"; fi' EXIT

report_failure() {
  printf 'FAIL %s %s\n' "$1" "$2"
  failed=1
}

if [[ ! -r /etc/mco/proxy.env ]]; then
  report_failure policy missing-env
  exit 1
fi
unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy ALL_PROXY all_proxy
set -a
if ! source /etc/mco/proxy.env; then
  report_failure policy unreadable-env
  exit 1
fi
set +a
if [[ ! -v HTTP_PROXY || ! -v HTTPS_PROXY || ! -v NO_PROXY ]] ||
   [[ $(printf '%s' "$HTTP_PROXY" | sha256sum | cut -d' ' -f1) != "$proxy_hash" ]] ||
   [[ $(printf '%s' "$HTTPS_PROXY" | sha256sum | cut -d' ' -f1) != "$proxy_hash" ]] ||
   [[ $(printf '%s' "$NO_PROXY" | sha256sum | cut -d' ' -f1) != "$no_proxy_hash" ]] ||
   [[ ",$NO_PROXY," != *",$subnet_cidr,"* ]]; then
  report_failure policy cluster-mismatch
  exit 1
fi
export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" no_proxy="$NO_PROXY"
printf 'PASS policy matched-cluster\n'

resolved_vip=$(getent ahostsv4 "$canary_host" 2>/dev/null | awk 'NR == 1 {print $1}')
if [[ "$resolved_vip" == "$vip" ]]; then
  printf 'PASS dns vip-resolved\n'
else
  report_failure dns not-vip
fi

os_ca=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
probe_tls() {
  local check=$1 url=$2 ca=$3 response rc code peer tls
  response=$(curl -q --silent --show-error --output /dev/null \
    --connect-timeout 4 --max-time 12 --cacert "$ca" \
    --write-out '%{http_code} %{remote_ip} %{ssl_verify_result}' \
    "$url" 2>/dev/null)
  rc=$?
  if (( rc != 0 )); then
    if (( rc == 60 )); then
      report_failure "$check" certificate-untrusted
    else
      report_failure "$check" request-failed
    fi
    return
  fi
  read -r code peer tls <<< "$response"
  if [[ "$tls" != 0 ]]; then
    report_failure "$check" certificate-untrusted
  elif [[ "$peer" != "$proxy_ip" ]]; then
    report_failure "$check" wrong-peer
  elif [[ "$check" == canary-https && "$code" =~ ^[23][0-9][0-9]$ ]] ||
       [[ "$check" == assisted-ready && "$code" == 200 ]] ||
       [[ "$check" == api-ready &&
          ( "$code" == 200 || "$code" == 401 || "$code" == 403 ) ]]; then
    printf 'PASS %s HTTP-%s-via-squid\n' "$check" "$code"
  else
    report_failure "$check" bad-response
  fi
}

probe_tls canary-https "https://$canary_host/" "$os_ca"
probe_tls assisted-ready "https://$assisted_host/ready" "$os_ca"

api_ca=
kubeconfig=/var/lib/kubelet/kubeconfig
if [[ -r "$kubeconfig" ]]; then
  ca_data=$(awk '$1 == "certificate-authority-data:" {print $2; exit}' "$kubeconfig")
  ca_path=$(awk '$1 == "certificate-authority:" {print $2; exit}' "$kubeconfig")
  if [[ -n "$ca_data" ]]; then
    temp_ca=$(mktemp /tmp/nutanix-api-ca.XXXXXX 2>/dev/null)
    if [[ -n "$temp_ca" ]] && printf '%s' "$ca_data" | base64 -d > "$temp_ca" 2>/dev/null &&
       [[ -s "$temp_ca" ]]; then
      api_ca=$temp_ca
    fi
  elif [[ "$ca_path" == /* && -r "$ca_path" ]]; then
    api_ca=$ca_path
  fi
fi
if [[ -n "$api_ca" ]]; then
  probe_tls api-ready "https://$api_host:$api_port/readyz" "$api_ca"
else
  report_failure api-ready missing-worker-ca
fi
response=$(curl -q --silent --show-error --output /dev/null \
  --connect-timeout 4 --max-time 12 --header "Host: $canary_host" \
  --write-out '%{http_code} %{remote_ip}' \
  "http://$vip/" 2>/dev/null)
rc=$?
if (( rc != 0 )); then
  report_failure canary-direct request-failed
else
  read -r code peer <<< "$response"
  if [[ "$peer" != "$vip" ]]; then
    report_failure canary-direct wrong-peer
  elif [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    printf 'PASS canary-direct HTTP-%s-via-vip\n' "$code"
  else
    report_failure canary-direct bad-response
  fi
fi
exit "$failed"
WORKER
)

mkdir -p "$ARTIFACT_DIR"
summary_file="$ARTIFACT_DIR/nutanix-worker-network-checks.txt"
declare -A passed last_result
for node in "${nodes[@]}"; do
  passed["$node"]=false
  last_result["$node"]="FAIL probe not-run"
done

deadline=$((SECONDS + 300))
while :; do
  for node in "${nodes[@]}"; do
    if [[ "${passed[$node]}" == true ]]; then continue; fi
    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then break; fi
    attempt_limit=$remaining
    if (( attempt_limit > 90 )); then attempt_limit=90; fi
    if output=$(timeout --kill-after=5s "$attempt_limit" \
      oc debug "node/$node" --quiet -- chroot /host /usr/bin/bash -c "$worker_probe" \
        worker-probe "$proxy_hash" "$no_proxy_hash" "$proxy_ip" "$vip" "$subnet_cidr" \
        "$canary_host" "$assisted_host" "$api_host" "$api_port" 2>/dev/null); then
      command_ok=true
    else
      command_status=$?
      command_ok=false
    fi
    safe_output=$(printf '%s\n' "$output" |
      grep -E '^(PASS|FAIL) (policy|dns|canary-https|assisted-ready|api-ready|canary-direct) [A-Za-z0-9-]+$' || true)
    if [[ -z "$safe_output" ]]; then
      safe_output="FAIL probe no-results"
    fi
    complete=true
    for check in policy dns canary-https assisted-ready api-ready canary-direct; do
      if [[ "$safe_output" != *"PASS $check "* ]]; then complete=false; fi
    done
    if [[ "$command_ok" != true && "$safe_output" != *"FAIL "* ]]; then
      if (( command_status == 124 )); then
        safe_output+=$'\nFAIL probe timed-out'
      else
        safe_output+=$'\nFAIL probe command-failed'
      fi
    elif [[ "$complete" != true && "$safe_output" != *"FAIL "* ]]; then
      safe_output+=$'\nFAIL probe incomplete-results'
    fi
    if [[ "$command_ok" == true && "$complete" == true &&
          "$safe_output" != *"FAIL "* ]]; then
      passed["$node"]=true
    fi
    last_result["$node"]=$safe_output
  done

  all_passed=true
  for node in "${nodes[@]}"; do
    if [[ "${passed[$node]}" != true ]]; then all_passed=false; fi
  done
  if [[ "$all_passed" == true ]]; then break; fi
  remaining=$((deadline - SECONDS))
  if (( remaining <= 0 )); then break; fi
  if (( remaining > 15 )); then remaining=15; fi
  sleep "$remaining"
done

: > "$summary_file"
failed_count=0
for node in "${nodes[@]}"; do
  printf 'worker=%s result=%s\n' "$node" "${passed[$node]}" >> "$summary_file"
  while IFS= read -r line; do
    printf '  %s\n' "$line" >> "$summary_file"
  done <<< "${last_result[$node]}"
  if [[ "${passed[$node]}" != true ]]; then (( failed_count += 1 )); fi
done
cat "$summary_file"
if (( failed_count > 0 )); then
  printf '%s of %s Nutanix workers failed the network smoke gate.\n' \
    "$failed_count" "$worker_count" >&2
  exit 1
fi
printf 'All %s Nutanix workers passed the network smoke gate.\n' "$worker_count"
