#!/bin/bash

set -o nounset
set -o pipefail

readonly GATE="UnifiedClusterManagedDNSAndLB"
readonly FORWARD_NAME="${DNS_FORWARD_TEST_NAME:-example.com}"
readonly JUNIT_FILE="${ARTIFACT_DIR}/junit_baremetalds_sno_dns.xml"
readonly TEST_LOG="${ARTIFACT_DIR}/baremetalds-sno-dns.log"
CASES_FILE=$(mktemp) || exit 1
PROBE_FILE=$(mktemp) || exit 1
TEST_KUBECONFIG_FILE=$(mktemp) || exit 1
readonly CASES_FILE PROBE_FILE TEST_KUBECONFIG_FILE

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

tests=0
failures=0
finished=false
RELEASE_PULLSPEC=""
MCO_IMAGE=""
RUNTIMECFG_IMAGE=""

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

record_pass() {
  local class=$1 name=$2
  tests=$((tests + 1))
  printf '  <testcase classname="%s" name="%s"/>\n' \
    "$(printf '%s' "${class}" | xml_escape)" \
    "$(printf '%s' "${name}" | xml_escape)" >> "${CASES_FILE}"
  echo "PASS [${class}] ${name}"
}

record_failure() {
  local class=$1 name=$2 message=$3 details=${4:-}
  tests=$((tests + 1))
  failures=$((failures + 1))
  {
    printf '  <testcase classname="%s" name="%s">\n' \
      "$(printf '%s' "${class}" | xml_escape)" \
      "$(printf '%s' "${name}" | xml_escape)"
    printf '    <failure type="%s" message="%s">%s</failure>\n' \
      "$(printf '%s' "${class}" | xml_escape)" \
      "$(printf '%s' "${message}" | xml_escape)" \
      "$(printf '%s' "${details}" | xml_escape)"
    printf '  </testcase>\n'
  } >> "${CASES_FILE}"
  echo "FAIL [${class}] ${name}: ${message}"
  [[ -z "${details}" ]] || echo "${details}"
}

write_junit() {
  [[ "${finished}" == true ]] && return
  finished=true
  if (( tests == 0 )); then
    record_failure setup unexpected-exit "test exited before setup completed" "See ${TEST_LOG}."
  fi
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="baremetalds-sno-dns" tests="%d" failures="%d">\n' "${tests}" "${failures}"
    cat "${CASES_FILE}"
    printf '</testsuite>\n'
  } > "${JUNIT_FILE}"
}

collect_artifacts() {
  set +o errexit
  echo "Collecting SNO DNS diagnostics"
  oc get infrastructure cluster -o yaml > "${ARTIFACT_DIR}/infrastructure.yaml" 2>&1
  oc get featuregate cluster -o yaml > "${ARTIFACT_DIR}/featuregate.yaml" 2>&1
  oc get dns cluster -o yaml > "${ARTIFACT_DIR}/dns.yaml" 2>&1
  oc get nodes -o yaml > "${ARTIFACT_DIR}/nodes.yaml" 2>&1
  oc get pods -n openshift-kni-infra -o yaml > "${ARTIFACT_DIR}/openshift-kni-infra-pods.yaml" 2>&1
  oc get machineconfigpools,machineconfigs -o wide > "${ARTIFACT_DIR}/machine-config-state.txt" 2>&1

  local pod
  while read -r pod; do
    [[ -n "${pod}" ]] || continue
    oc logs -n openshift-kni-infra "${pod}" --all-containers=true > "${ARTIFACT_DIR}/${pod}.log" 2>&1
    oc describe pod -n openshift-kni-infra "${pod}" > "${ARTIFACT_DIR}/${pod}-describe.txt" 2>&1
  done < <(oc get pods -n openshift-kni-infra -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | startswith("sno-coredns-")) | .metadata.name')

  if [[ -n "${NODE_NAME:-}" ]]; then
    oc debug "node/${NODE_NAME}" --quiet -- chroot /host bash -c '
      echo "### static pod manifest"; cat /etc/kubernetes/manifests/sno-coredns.yaml 2>&1 || true
      echo "### rendered Corefile"; cat /etc/sno-coredns/Corefile 2>&1 || true
      echo "### /etc/resolv.conf"; ls -l /etc/resolv.conf; cat /etc/resolv.conf 2>&1 || true
      echo "### NetworkManager resolver inputs"; ls -l /run/NetworkManager/*resolv.conf 2>&1 || true; cat /run/NetworkManager/no-stub-resolv.conf 2>/dev/null || cat /run/NetworkManager/resolv.conf 2>&1 || true
      echo "### resolver units"; systemctl status sno-resolv-prepender.service sno-resolv-prepender.path --no-pager 2>&1 || true
      echo "### resolver journal"; journalctl -u sno-resolv-prepender.service -u sno-resolv-prepender.path --no-pager 2>&1 || true
      echo "### node IP inputs"; find /run/nodeip-configuration -maxdepth 1 -type f -print -exec cat {} \; 2>&1 || true
      echo "### DNS listeners"; ss -H -lntup 2>&1 | grep -E "(^|[[:space:]])[^[:space:]]+:53([[:space:]]|$)" || true
      echo "### dnsmasq on the SNO node"; systemctl status dnsmasq.service --no-pager 2>&1 || true
    ' > "${ARTIFACT_DIR}/node-dns-state.txt" 2>&1
  fi
}

cleanup() {
  write_junit
  collect_artifacts
  rm -f "${CASES_FILE}" "${PROBE_FILE}" "${TEST_KUBECONFIG_FILE}"
}
trap cleanup EXIT
trap 'exit 130' TERM

exec > >(tee -a "${TEST_LOG}") 2>&1

setup_abort() {
  record_failure setup "$1" "$2" "${3:-}"
  exit 1
}

collect_payload_identity() {
  local component image release_info tag

  RELEASE_PULLSPEC=$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>> "${ARTIFACT_DIR}/payload-images-errors.txt") || return 1
  [[ -n "${RELEASE_PULLSPEC}" ]] || return 1
  release_info=$(oc adm release info "${RELEASE_PULLSPEC}" -o json 2>> "${ARTIFACT_DIR}/payload-images-errors.txt") || return 1
  printf '%s\n' "${release_info}" > "${ARTIFACT_DIR}/release-info.json"

  : > "${ARTIFACT_DIR}/payload-images.txt"
  : > "${ARTIFACT_DIR}/payload-component-tags.jsonl"
  printf 'release_pullspec=%s\n' "${RELEASE_PULLSPEC}" >> "${ARTIFACT_DIR}/payload-images.txt"
  for component in machine-config-operator baremetal-runtimecfg; do
    image=$(oc adm release info "${RELEASE_PULLSPEC}" --image-for="${component}" 2>> "${ARTIFACT_DIR}/payload-images-errors.txt") || return 1
    [[ "${image}" =~ @sha256:[0-9a-f]{64}$ ]] || return 1
    tag=$(jq -c --arg component "${component}" '.references.spec.tags[] | select(.name == $component)' <<< "${release_info}")
    [[ -n "${tag}" ]] || return 1
    printf '%s\n' "${tag}" >> "${ARTIFACT_DIR}/payload-component-tags.jsonl"
    printf '%s_image=%s\n%s_digest=%s\n' \
      "${component}" "${image}" "${component}" "${image##*@}" >> "${ARTIFACT_DIR}/payload-images.txt"
    case "${component}" in
      machine-config-operator) MCO_IMAGE=${image} ;;
      baremetal-runtimecfg) RUNTIMECFG_IMAGE=${image} ;;
    esac
  done
}

[[ -s "${KUBECONFIG}" ]] || setup_abort kubeconfig "installation did not produce a kubeconfig" "Expected ${KUBECONFIG}."
command -v oc >/dev/null || setup_abort oc-client "oc is unavailable in the test image"
command -v jq >/dev/null || setup_abort jq "jq is unavailable in the test image"

# Prevent client-go from borrowing the CI pod's namespace for SNO commands.
# Keep the shared kubeconfig unchanged and preserve oc debug's automatic
# temporary privileged-namespace handling (do not force -n/--to-namespace).
cp "${KUBECONFIG}" "${TEST_KUBECONFIG_FILE}" || setup_abort kubeconfig "could not copy the installed-cluster kubeconfig"
export KUBECONFIG="${TEST_KUBECONFIG_FILE}"
oc config set-context --current --namespace=default >/dev/null ||
  setup_abort debug-namespace "could not set the installed-cluster context namespace"

# Installation can finish while the SNO API static pod is still rolling.
# Use the existing kubeconfig/proxy; retry setup only, never DNS assertions.
api_access_log="${ARTIFACT_DIR}/api-access.log"
api_deadline=$((SECONDS + 300))
api_access_ready=false
: > "${api_access_log}"
while (( SECONDS < api_deadline )); do
  printf '\n%s API readiness attempt\n' "$(date -u +%FT%TZ)" >> "${api_access_log}"
  if oc --request-timeout=10s get --raw=/readyz >> "${api_access_log}" 2>&1 &&
     { oc --request-timeout=10s get kubeapiserver cluster -o json 2>> "${api_access_log}" |
       jq -e '
         .status as $s |
         ($s.latestAvailableRevision > 0) and
         (($s.nodeStatuses | length) > 0) and
         all($s.nodeStatuses[];
           .currentRevision == $s.latestAvailableRevision and
           ((.targetRevision // 0) == 0)) and
         any($s.conditions[];
           .type == "NodeInstallerProgressing" and .status == "False")
       ' >> "${api_access_log}" 2>&1; } &&
     oc --request-timeout=10s whoami >> "${api_access_log}" 2>&1; then
    api_access_ready=true
    break
  fi
  sleep 5
done
[[ "${api_access_ready}" == true ]] || setup_abort cluster-access \
  "API access/readiness or kube-apiserver rollout did not settle within the startup wait" \
  "$(tail -n 40 "${api_access_log}")"
record_pass setup cluster-access
oc get namespace default -o name >/dev/null ||
  setup_abort debug-namespace "the installed cluster has no accessible default namespace"
record_pass setup debug-namespace

collect_payload_identity || setup_abort payload-image-identity \
  "could not establish digest-pinned identities for the installed payload and both tested components" \
  "$(cat "${ARTIFACT_DIR}/payload-images-errors.txt" 2>/dev/null || true)"
[[ -n "${MCO_IMAGE}" && -n "${RUNTIMECFG_IMAGE}" ]] || setup_abort payload-image-identity \
  "component image identity evidence is incomplete"
record_pass setup payload-image-identity

node_count=$(oc get nodes -o json | jq '.items | length')
[[ "${node_count}" == 1 ]] || setup_abort node-count "expected exactly one node" "Observed ${node_count} nodes."
NODE_NAME=$(oc get nodes -o json | jq -r '.items[0].metadata.name')
export NODE_NAME
record_pass setup one-node

infra_json=$(oc get infrastructure cluster -o json) || setup_abort infrastructure "cannot read Infrastructure/cluster"
platform=$(jq -r '.status.platformStatus.type // ""' <<< "${infra_json}")
topology=$(jq -r '.status.controlPlaneTopology // ""' <<< "${infra_json}")
[[ "${platform}" == None ]] || setup_abort platform "expected platform None" "Observed ${platform}."
[[ "${topology}" == SingleReplica ]] || setup_abort topology "expected SingleReplica control-plane topology" "Observed ${topology}."
record_pass setup platform-none-single-replica

feature_enabled=false
desired_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
[[ -n "${desired_version}" ]] || setup_abort cluster-version "ClusterVersion/version has no desired version"
for _ in $(seq 1 60); do
  feature_json=$(oc get featuregate cluster -o json 2>/dev/null || true)
  if jq -e --arg gate "${GATE}" --arg version "${desired_version}" '
      .spec.featureSet == "CustomNoUpgrade" and
      ((.spec.customNoUpgrade.enabled // []) | index($gate) != null) and
      ((.spec.customNoUpgrade.disabled // []) | index($gate) == null) and
      any(.status.featureGates[]?; .version == $version and any(.enabled[]?; .name == $gate))
    ' <<< "${feature_json}" >/dev/null 2>&1; then
    feature_enabled=true
    break
  fi
  sleep 10
done
[[ "${feature_enabled}" == true ]] || setup_abort feature-gate \
  "${GATE} was not enabled by the installation-time CustomNoUpgrade configuration" \
  "$(oc get featuregate cluster -o yaml 2>&1 || true)"
record_pass setup feature-gate-enabled

BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null)
[[ -n "${BASE_DOMAIN}" ]] || setup_abort base-domain "DNS/cluster has no baseDomain"
record_pass setup dns-base-domain

manifest_output_file="${ARTIFACT_DIR}/node-manifest-check.txt"
if manifest_output=$(oc debug "node/${NODE_NAME}" --quiet -- chroot /host bash -c '
    if test -s /etc/kubernetes/manifests/sno-coredns.yaml; then
      echo DNS_MANIFEST_CHECK=present
    else
      echo DNS_MANIFEST_CHECK=absent
    fi
  ' 2>&1); then
  printf '%s\n' "${manifest_output}" | tee "${manifest_output_file}"
else
  manifest_status=$?
  printf '%s\n' "${manifest_output}" | tee "${manifest_output_file}"
  setup_abort node-manifest-debug \
    "could not execute the SNO node manifest inspection" \
    "oc debug exit=${manifest_status}; output=${manifest_output}"
fi
manifest_marker=$(sed -n 's/^DNS_MANIFEST_CHECK=//p' <<< "${manifest_output}" | tail -n1)
case "${manifest_marker}" in
present)
  record_pass dns-assertion mco-static-pod-manifest
  ;;
absent)
  record_failure dns-assertion mco-static-pod-manifest \
    "MCO-managed SNO CoreDNS manifest is absent" \
    "Expected /etc/kubernetes/manifests/sno-coredns.yaml. This is the intentional baseline failure before the feature implementation lands."
  write_junit
  exit 1
  ;;
*)
  setup_abort node-manifest-marker \
    "SNO node manifest inspection completed without a valid result marker" \
    "${manifest_output}"
  ;;
esac

pod_ready=false
pod_query_succeeded=false
pod_query_error=""
for _ in $(seq 1 60); do
  if ! pod_json=$(oc get pods -n openshift-kni-infra -o json 2>&1); then
    pod_query_error=${pod_json}
    sleep 10
    continue
  fi
  pod_query_succeeded=true
  matching=$(jq '[.items[] | select(.metadata.name | startswith("sno-coredns-"))] | length' <<< "${pod_json}" 2>/dev/null || echo 0)
  ready=$(jq '[.items[] | select(.metadata.name | startswith("sno-coredns-")) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<< "${pod_json}" 2>/dev/null || echo 0)
  if [[ "${matching}" == 1 && "${ready}" == 1 ]]; then
    pod_ready=true
    break
  fi
  sleep 10
done
[[ "${pod_query_succeeded}" == true ]] || setup_abort sno-coredns-pod-access \
  "could not query openshift-kni-infra pods while waiting for SNO CoreDNS" "${pod_query_error}"
if [[ "${pod_ready}" == true ]]; then
  record_pass dns-assertion sno-coredns-pod-ready
else
  record_failure dns-assertion sno-coredns-pod-ready \
    "expected exactly one ready sno-coredns static pod in openshift-kni-infra" \
    "$(oc get pods -n openshift-kni-infra -o wide 2>&1 || true)"
  write_junit
  exit 1
fi

cat > "${PROBE_FILE}" <<'PROBE'
#!/bin/bash
set -o nounset
set -o pipefail

base_domain=$1
forward_name=$2
target_node=$3

emit() { printf 'DNS_TEST %s=%s\n' "$1" "$2"; }
answers() {
  dig +time=5 +tries=1 +short "@$1" "$2" A 2>/dev/null | awk '/^[0-9]+([.][0-9]+){3}$/ {print}' | sort -u | paste -sd, -
}

emit probe_started true
for command in dig awk getent chroot curl ss; do
  if ! command -v "${command}" >/dev/null; then
    emit probe_error "missing-${command}"
    emit probe_complete true
    exit 0
  fi
done

node_ip=$(tr -d '[:space:]' < /host/run/nodeip-configuration/primary-ip 2>/dev/null || true)
emit node_ip "${node_ip}"
emit ipv4 "$([[ "${node_ip}" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] && echo true || echo false)"
emit corefile "$([[ -s /host/etc/sno-coredns/Corefile ]] && echo true || echo false)"
emit resolver_assets "$([[ -x /host/usr/local/bin/sno-resolv-prepender.sh && -f /host/etc/systemd/system/sno-resolv-prepender.service && -f /host/etc/systemd/system/sno-resolv-prepender.path ]] && echo true || echo false)"
emit ready "$([[ -n "${node_ip}" ]] && curl --fail --silent --max-time 3 http://127.0.0.1:18081/ready >/dev/null && echo true || echo false)"

api_answer=""
api_int_answer=""
ingress_answer=""
forward_answer=""
if [[ -n "${node_ip}" ]]; then
  api_answer=$(answers "${node_ip}" "api.${base_domain}")
  api_int_answer=$(answers "${node_ip}" "api-int.${base_domain}")
  ingress_answer=$(answers "${node_ip}" "dns-test.apps.${base_domain}")
  forward_answer=$(answers "${node_ip}" "${forward_name}")
fi
emit api "${api_answer}"
emit api_int "${api_int_answer}"
emit ingress "${ingress_answer}"
emit forward "${forward_answer}"

resolv_target=$(chroot /host readlink -f /etc/resolv.conf 2>/dev/null || true)
resolver_mode=plain
resolver_ok=false
config_key_has_token() {
  local file=$1 key=$2 expected=$3
  awk -F= -v key="${key}" -v expected="${expected}" '
    $1 == key {
      count = split($2, tokens, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (tokens[i] == expected) found = 1
      }
    }
    END { exit !found }
  ' "${file}"
}
if [[ "${resolv_target}" == /run/systemd/resolve/* ]]; then
  resolver_mode=systemd-resolved
  if config_key_has_token /host/etc/systemd/resolved.conf.d/60-sno-internal-dns.conf DNS "${node_ip}" 2>/dev/null &&
     config_key_has_token /host/etc/systemd/resolved.conf.d/60-sno-internal-dns.conf Domains "${base_domain}" 2>/dev/null; then
    resolver_ok=true
  fi
else
  first_nameserver=$(chroot /host awk '$1 == "nameserver" {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
  if [[ "${first_nameserver}" == "${node_ip}" ]] &&
     grep -q '^rc-manager=unmanaged$' /host/run/NetworkManager/conf.d/99-sno-internal-dns.conf 2>/dev/null; then
    resolver_ok=true
  fi
fi
emit resolver_mode "${resolver_mode}"
emit resolver_ok "${resolver_ok}"

listener_endpoint="${node_ip}:53"
listener_output=$(ss -H -lntup 2>/dev/null || true)
printf '%s\n' "${listener_output}" | awk -v endpoint="${listener_endpoint}" '$5 == endpoint {print "DNS_LISTENER " $0}'
udp_listener=$(awk -v endpoint="${listener_endpoint}" '$1 == "udp" && $5 == endpoint' <<< "${listener_output}")
tcp_listener=$(awk -v endpoint="${listener_endpoint}" '$1 == "tcp" && $5 == endpoint' <<< "${listener_output}")
listener_owner_ok=false
if [[ -n "${udp_listener}" && -n "${tcp_listener}" ]] &&
   grep -q '"coredns"' <<< "${udp_listener}" &&
   grep -q '"coredns"' <<< "${tcp_listener}" &&
   ! grep -q '"dnsmasq"' <<< "${udp_listener}${tcp_listener}"; then
  listener_owner_ok=true
fi
emit listener_node "${target_node}"
printf 'DNS_INSPECTED_HOSTNAME %s\n' "$(chroot /host cat /etc/hostname 2>/dev/null || true)"
emit dns_listener_owner "${listener_owner_ok}"

host_answers() {
  chroot /host getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | awk '/^[0-9]+([.][0-9]+){3}$/' | sort -u | paste -sd, -
}
emit host_api "$(host_answers "api.${base_domain}")"
emit host_ingress "$(host_answers "dns-test.apps.${base_domain}")"
emit host_forward "$(host_answers "${forward_name}")"
emit probe_complete true
PROBE

if probe_output=$(oc debug "node/${NODE_NAME}" --quiet --no-stdin=false --no-tty \
  -- bash -s -- "${BASE_DOMAIN}" "${FORWARD_NAME}" "${NODE_NAME}" \
  < "${PROBE_FILE}" 2>&1); then
  printf '%s\n' "${probe_output}" | tee "${ARTIFACT_DIR}/node-dns-probe.txt"
else
  probe_status=$?
  printf '%s\n' "${probe_output}" | tee "${ARTIFACT_DIR}/node-dns-probe.txt"
  setup_abort node-probe-execution \
    "could not execute the DNS probe on the SNO node" \
    "oc debug exit=${probe_status}; output=${probe_output}"
fi

probe_value() {
  sed -n "s/^DNS_TEST $1=//p" <<< "${probe_output}" | tail -n1
}

for marker in probe_started probe_complete; do
  [[ "$(probe_value "${marker}")" == true ]] || setup_abort node-probe-marker \
    "DNS probe completed without the required ${marker} marker" "${probe_output}"
done

probe_error=$(probe_value probe_error)
[[ -z "${probe_error}" ]] || setup_abort node-probe "node debug image lacks required DNS tooling" "${probe_error}"

for marker in node_ip ipv4 corefile resolver_assets ready api api_int ingress forward resolver_mode resolver_ok listener_node dns_listener_owner host_api host_ingress host_forward; do
  grep -q "^DNS_TEST ${marker}=" <<< "${probe_output}" || setup_abort node-probe-marker \
    "DNS probe omitted required marker ${marker}" "${probe_output}"
done

NODE_IP=$(probe_value node_ip)
if [[ -z "${NODE_IP}" ]]; then
  record_failure dns-assertion node-ip-discovery "node IP discovery did not publish primary-ip" \
    "Expected /run/nodeip-configuration/primary-ip."
  write_junit
  exit 1
fi
[[ "$(probe_value ipv4)" == true ]] || setup_abort ipv4 "expected an IPv4 primary node address" "Observed ${NODE_IP}."
node_internal_ips=$(oc get node "${NODE_NAME}" -o json | jq -r '.status.addresses[] | select(.type == "InternalIP") | .address')
grep -Fxq "${NODE_IP}" <<< "${node_internal_ips}" || setup_abort node-ip \
  "primary-ip is not reported as a node InternalIP" "primary-ip=${NODE_IP}; InternalIP=${node_internal_ips}"
record_pass setup ipv4-node-address

listener_node=$(probe_value listener_node)
if [[ "${listener_node}" == "${NODE_NAME}" && "$(probe_value dns_listener_owner)" == true ]]; then
  record_pass dns-assertion sno-node-dns-listener-owner
else
  record_failure dns-assertion sno-node-dns-listener-owner \
    "the SNO node's IPv4 DNS listeners are not owned exclusively by CoreDNS" \
    "node=${NODE_NAME}; inspected-host=${listener_node}; expected-endpoint=${NODE_IP}:53; see node-dns-probe.txt"
fi

if [[ "$(probe_value corefile)" == true ]]; then
  record_pass dns-assertion rendered-corefile
else
  record_failure dns-assertion rendered-corefile "rendered SNO CoreDNS Corefile is absent"
fi
if [[ "$(probe_value resolver_assets)" == true ]]; then
  record_pass dns-assertion resolver-assets
else
  record_failure dns-assertion resolver-assets "MCO-managed resolver script or units are absent"
fi
if [[ "$(probe_value ready)" == true ]]; then
  record_pass dns-assertion coredns-ready-endpoint
else
  record_failure dns-assertion coredns-ready-endpoint "node-local CoreDNS readiness endpoint failed"
fi

for record in api api_int ingress; do
  observed=$(probe_value "${record}")
  if [[ "${observed}" == "${NODE_IP}" ]]; then
    record_pass dns-assertion "direct-${record}-answer"
  else
    record_failure dns-assertion "direct-${record}-answer" \
      "direct node CoreDNS answer did not equal the node address" \
      "query=${record}; expected=${NODE_IP}; observed=${observed:-<empty>}"
  fi
done

forward_answer=$(probe_value forward)
if [[ -n "${forward_answer}" ]]; then
  record_pass dns-assertion upstream-forwarding
else
  record_failure dns-assertion upstream-forwarding \
    "node-local CoreDNS did not forward the controlled name" "name=${FORWARD_NAME}"
fi

if [[ "$(probe_value resolver_ok)" == true ]]; then
  record_pass dns-assertion host-resolver-configuration
else
  record_failure dns-assertion host-resolver-configuration \
    "host resolver does not target SNO CoreDNS through the supported resolver configuration" \
    "mode=$(probe_value resolver_mode); node-ip=${NODE_IP}"
fi

for record in host_api host_ingress; do
  observed=$(probe_value "${record}")
  if [[ "${observed}" == "${NODE_IP}" ]]; then
    record_pass dns-assertion "${record}-answer"
  else
    record_failure dns-assertion "${record}-answer" \
      "host resolver answer did not equal the node address" \
      "expected=${NODE_IP}; observed=${observed:-<empty>}"
  fi
done

host_forward=$(probe_value host_forward)
if [[ -n "${host_forward}" ]]; then
  record_pass dns-assertion host-resolver-upstream
else
  record_failure dns-assertion host-resolver-upstream \
    "host resolver could not resolve the controlled forwarded name" "name=${FORWARD_NAME}"
fi

write_junit
if (( failures > 0 )); then
  exit 1
fi
