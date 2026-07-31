#!/bin/bash
#
# Step 1 of 3: Submariner Cloud Prepare
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Run 'subctl cloud prepare aws' on each spoke (always) and on the hub
#     (only when SUBMARINER_VERIFY_HUB_SPOKE=true) to open firewall ports and
#     deploy a gateway node (--gateways 1)
#   - Wait for the gateway node to be Ready and labeled on each prepared cluster
#     before the broker-join step (avoids interactive gateway selection in CI)
#
# SPOKE CLUSTERS (spoke-to-spoke and hub-spoke jobs):
#   PrepareAwsCluster + WaitForGatewayNode — identical to upstream main branch.
#   Spokes use MachineSet-managed dedicated gateway nodes (standard behaviour).
#
# HUB CLUSTER (hub-spoke jobs only, SUBMARINER_VERIFY_HUB_SPOKE=true):
#   PrepareHubAwsCluster + WaitForHubGatewayNode — hub-specific functions.
#   The hub uses c5n.metal bare-metal workers (no MachineSets).  Standard
#   subctl cloud prepare --gateways 1 creates the '<infraID>-submariner-gw-sg' SG
#   with the required IPsec ports and handles security group setup.  On bare-metal
#   clusters with no MachineSets, subctl labels an existing worker node as the
#   gateway.  SG management is handled entirely by subctl.
#
# WHY the hub is optionally prepared (SUBMARINER_VERIFY_HUB_SPOKE=true only):
#   KubeVirt CCLM sync uses raw pod-IP routing (port 8443) between the
#   virt-synchronization-controller on source and destination clusters.
#   For hub↔spoke CCLM the hub must participate in the Submariner mesh so its
#   pods can route to spoke pod IPs and vice versa.
#   Hub metadata is read from ${SHARED_DIR}/metadata.json (standard IPI artifact).
#   For spoke↔spoke CCLM the hub does NOT need to be a Submariner participant,
#   so hub cloud-prepare is skipped to avoid unnecessary ~10-15 min overhead.
#
# WHY binaries are NOT stored in SHARED_DIR:
#   After each step the CI operator serialises SHARED_DIR into a Kubernetes
#   Secret so the next step can access its files.  Kubernetes Secrets have a
#   hard 3 MB request-body limit.  subctl (~50 MB) far exceeds that limit,
#   causing "Request entity too large: limit is 3145728" even when the step
#   script itself succeeds.  Each step therefore installs its own copy of
#   subctl from the internet at step start.
#
# AWS credentials are loaded into ~/.aws/ and removed on EXIT via trap.
# They are never written to SHARED_DIR.
#

set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -r subctlBin="/tmp/bin/subctl"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"

typeset awsTmpCreds=""

typeset -a spokeKubeconfigsArr=()
typeset -a spokeMetadataFilesArr=()
typeset -a spokeNamesArr=()

# ── Cleanup — remove AWS credentials on EXIT ──────────────────────────────────
Cleanup() {
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    if [[ -n "${awsTmpCreds}" && -f "${awsTmpCreds}" ]]; then
        rm -f "${awsTmpCreds}"
    fi
    rm -f "${HOME}/.aws/credentials" "${HOME}/.aws/config"
    [[ "${_wasTracing}" == "true" ]] && set -x
}
trap Cleanup EXIT

# ── InstallSubctl — install subctl to /tmp/bin/ ───────────────────────────────
InstallSubctl() {
    mkdir -p /tmp/bin
    if [[ -x "${subctlBin}" ]]; then
        return 0
    fi
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
    true
}

# ── SetAwsCredentials — write ~/.aws/credentials from cluster profile ────────
#
# Sensitive: set +x wraps credential file writes to prevent xtrace leakage.
SetAwsCredentials() {
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x

    typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"
    if [[ ! -f "${awsCredFile}" ]]; then
        [[ "${_wasTracing}" == "true" ]] && set -x
        : "AWS credentials file not found: ${awsCredFile}"
        return 1
    fi

    mkdir -p "${HOME}/.aws"
    awsTmpCreds="$(mktemp /tmp/aws-creds-XXXXXX)"

    cat > "${HOME}/.aws/credentials" <<EOF
[default]
aws_access_key_id=$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")
aws_secret_access_key=$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")
EOF

    cat > "${HOME}/.aws/config" <<'EOF'
[default]
region=us-east-1
output=json
EOF
    cp "${HOME}/.aws/credentials" "${awsTmpCreds}"

    [[ "${_wasTracing}" == "true" ]] && set -x
}

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ───────────────────
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset metaFile="${SHARED_DIR}/managed-cluster-metadata-${i}.json"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        [ -f "${kcFile}" ]
        [ -f "${metaFile}" ]
        [ -f "${nameFile}" ]

        spokeKubeconfigsArr+=("${kcFile}")
        spokeMetadataFilesArr+=("${metaFile}")
        spokeNamesArr+=("$(<"${nameFile}")")
    done
    true
}

# ── PrepareAwsCluster — run subctl cloud prepare aws ─────────────────────────
# Creates '<infraID>-submariner-gw-sg' SG and provisions a gateway node.
# On MachineSet-based clusters (including c5n.metal that has MachineSets) subctl
# creates a dedicated gateway MachineSet whose new instance gets the gw-sg attached
# at provisioning time.  On clusters where no MachineSet is created, subctl labels
# an existing worker directly.
# SG patching (EnsureWorkerSgHasIpsecPorts) is done AFTER WaitForGatewayNode in
# the main flow — not here — so it always runs on the confirmed-ready gateway node.
PrepareAwsCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset clusterRegion
    clusterRegion="$(jq -r '.aws.region // empty' "${metadataFile}" || true)"
    if [[ -n "${clusterRegion}" ]]; then
        export AWS_DEFAULT_REGION="${clusterRegion}"
    else
        : "WARNING: aws.region not found in ${metadataFile}; using current AWS_DEFAULT_REGION for '${clusterName}'"
    fi

    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kubeconfig}" \
        --ocp-metadata "${metadataFile}" \
        --gateways 1
}

# ── PrepareHubAwsCluster — prepare AWS cloud for Submariner on the hub cluster ─
# HUB ONLY (SUBMARINER_VERIFY_HUB_SPOKE=true).  Identical to PrepareAwsCluster —
# both hub and spokes use c5n.metal bare-metal, so the same logic applies.
PrepareHubAwsCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    : "Preparing hub '${clusterName}' for Submariner (same path as spoke)"
    PrepareAwsCluster "${kubeconfig}" "${metadataFile}" "${clusterName}"
}

# ── EnsureWorkerSgHasIpsecPorts — add Submariner IPsec rules to gateway node SGs
#
# PROBLEM: subctl cloud prepare creates '<infraID>-submariner-gw-sg' with the
# required Submariner IPsec ports (UDP 4500/500/ESP/4490), but:
#   - On MachineSet-provisioned clusters: subctl attaches this new SG to the new
#     gateway Machine — so the gateway's SGs are correct.
#   - On bare-metal clusters (c5n.metal, no MachineSets): subctl labels an existing
#     running worker as the gateway but EC2 cannot retroactively attach a new SG to
#     an already-running bare-metal instance.  The node keeps its original SGs (e.g.
#     '<infraID>-worker') which have no inbound UDP 4500 (IPsec NAT-T) — so ESP
#     data packets are silently dropped by AWS even though IKE says 'connected'.
#
# FIX: Find the gateway-labeled node's EC2 instance via oc, then call
# DescribeInstances to get its ACTUAL attached SGs (by-name lookup is fragile and
# broke when SG names differed from the expected pattern), then add the four
# required Submariner ingress rules to every SG attached to that instance.
#
# CREDENTIALS: Uses AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
# environment variables first (matching how subctl/AWS SDK resolves credentials),
# then falls back to ~/.aws/credentials.  Session token support is critical for CI
# environments that use STS temporary credentials — without it, the SigV4 signature
# is invalid and DescribeSecurityGroups returns empty results without error.
#
# SAFETY: Safe to call on standard IPI clusters too (redundant rules are harmless
# when the gateway is MachineSet-provisioned with the submariner-gw-sg already).
EnsureWorkerSgHasIpsecPorts() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset clusterRegion
    clusterRegion="$(jq -r '.aws.region // empty' "${metadataFile}" || true)"
    [[ -n "${clusterRegion}" ]] || {
        : "WARNING: aws.region missing in ${metadataFile} — skipping IPsec SG rules for '${clusterName}'"
        return 0
    }

    # Find the gateway node's EC2 instance ID from its providerID annotation.
    # subctl labels the gateway immediately after 'subctl cloud prepare aws', so
    # this lookup should succeed right away for bare-metal and within a few minutes
    # for MachineSet-provisioned clusters (once the new node joins).
    typeset providerID instanceId
    providerID="$(KUBECONFIG="${kubeconfig}" oc get node \
        -l submariner.io/gateway=true \
        -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)"

    if [[ -z "${providerID}" ]]; then
        # For MachineSet-based spokes: subctl cloud prepare creates a new MachineSet whose
        # node is still provisioning at this point — the new dedicated gateway node will get
        # the submariner-gw-sg (with correct IPsec ports) attached automatically at provisioning
        # time.  No need to patch an existing SG; safe to skip.
        # For bare-metal clusters: subctl labels an existing worker immediately, so this
        # branch should not be reached on bare-metal.
        : "No gateway-labeled node on '${clusterName}' (MachineSet still provisioning — dedicated gateway will get submariner-gw-sg automatically)"
        return 0
    fi

    # providerID format: aws:///us-east-2a/i-0123456789abcdef  or  aws:///<zone>/<id>
    instanceId="${providerID##*/}"
    : "Gateway node provider ID '${providerID}' → instance '${instanceId}' on '${clusterName}' (${clusterRegion})"

    python3 - "${instanceId}" "${clusterRegion}" <<'PYEOF'
"""Add Submariner IPsec ingress rules to ALL SGs of a gateway EC2 instance.
Uses EC2 Query API with SigV4 signing; no boto3 required.
Credentials resolved from env vars first (matching AWS SDK chain), then
~/.aws/credentials, with full STS session-token support."""
import sys, os, re, hmac, hashlib, urllib.request, urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

def _read_creds():
    """Return (access_key, secret_key, session_token); session_token may be ''."""
    ak = os.environ.get("AWS_ACCESS_KEY_ID", "")
    sk = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    token = os.environ.get("AWS_SESSION_TOKEN", "")
    if ak and sk:
        return ak, sk, token

    # Fallback: credentials file
    cred_file = os.path.expanduser("~/.aws/credentials")
    ak = sk = token = ""
    try:
        with open(cred_file) as f:
            for line in f:
                m = re.match(r'\s*(\w+)\s*=\s*(.*)', line)
                if not m:
                    continue
                key, val = m.group(1), m.group(2).strip()
                if key == "aws_access_key_id":
                    ak = val
                elif key == "aws_secret_access_key":
                    sk = val
                elif key == "aws_session_token":
                    token = val
    except FileNotFoundError:
        pass

    if not ak or not sk:
        raise RuntimeError("AWS credentials not found in env vars or ~/.aws/credentials")
    return ak, sk, token

def _sign(key, msg):
    k = key if isinstance(key, bytes) else key.encode()
    return hmac.new(k, msg.encode(), hashlib.sha256).digest()

def _derive_key(secret, date, region, service):
    return _sign(_sign(_sign(_sign("AWS4" + secret, date), region), service), "aws4_request")

def _ec2(action, params, region, ak, sk, token=""):
    """Call EC2 Query API with SigV4 (includes session token if provided)."""
    host = f"ec2.{region}.amazonaws.com"
    t = datetime.now(timezone.utc)
    amz_date = t.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = t.strftime("%Y%m%d")

    all_p = dict(params, Action=action, Version="2016-11-15")
    body = urllib.parse.urlencode(sorted(all_p.items()))
    ph = hashlib.sha256(body.encode()).hexdigest()

    # Canonical headers — must be sorted alphabetically; include security token when present.
    if token:
        ch = (f"content-type:application/x-www-form-urlencoded\n"
              f"host:{host}\n"
              f"x-amz-date:{amz_date}\n"
              f"x-amz-security-token:{token}\n")
        sh = "content-type;host;x-amz-date;x-amz-security-token"
    else:
        ch = f"content-type:application/x-www-form-urlencoded\nhost:{host}\nx-amz-date:{amz_date}\n"
        sh = "content-type;host;x-amz-date"

    cr = f"POST\n/\n\n{ch}\n{sh}\n{ph}"
    cs = f"{date_stamp}/{region}/ec2/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amz_date}\n{cs}\n{hashlib.sha256(cr.encode()).hexdigest()}"
    sig = hmac.new(_derive_key(sk, date_stamp, region, "ec2"), sts.encode(), hashlib.sha256).hexdigest()
    auth = f"AWS4-HMAC-SHA256 Credential={ak}/{cs}, SignedHeaders={sh}, Signature={sig}"

    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-Amz-Date": amz_date,
        "Authorization": auth,
    }
    if token:
        headers["X-Amz-Security-Token"] = token

    req = urllib.request.Request(
        f"https://{host}/",
        data=body.encode(),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as r:
            return ET.fromstring(r.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        if "InvalidPermission.Duplicate" in err_body:
            return None  # rule already exists — OK
        print(f"EC2 API error {e.code}: {err_body}", file=sys.stderr)
        raise

def main():
    instance_id, region = sys.argv[1], sys.argv[2]
    ak, sk, token = _read_creds()
    ns = "{http://ec2.amazonaws.com/doc/2016-11-15/}"

    # Get SGs attached to the gateway EC2 instance (avoids fragile name-based lookup).
    resp = _ec2("DescribeInstances", {"InstanceId.1": instance_id}, region, ak, sk, token)
    if resp is None:
        print(f"ERROR: DescribeInstances returned no response for '{instance_id}'", file=sys.stderr)
        sys.exit(1)

    # Collect all groupId elements from all reservations/instances in the response.
    all_sg_ids = list(dict.fromkeys(el.text for el in resp.iter(f"{ns}groupId")))
    if not all_sg_ids:
        print(f"ERROR: no security groups found for instance '{instance_id}'", file=sys.stderr)
        sys.exit(1)

    print(f"Gateway instance '{instance_id}' has SG(s): {', '.join(all_sg_ids)}")

    rules = [
        ("UDP 4500 (IPsec NAT-T)",       {"IpPermissions.1.IpProtocol": "udp",
            "IpPermissions.1.FromPort": "4500", "IpPermissions.1.ToPort": "4500",
            "IpPermissions.1.IpRanges.1.CidrIp": "0.0.0.0/0"}),
        ("UDP 500  (IKE)",               {"IpPermissions.1.IpProtocol": "udp",
            "IpPermissions.1.FromPort": "500",  "IpPermissions.1.ToPort": "500",
            "IpPermissions.1.IpRanges.1.CidrIp": "0.0.0.0/0"}),
        ("UDP 4800 (NATT discovery)",    {"IpPermissions.1.IpProtocol": "udp",
            "IpPermissions.1.FromPort": "4800", "IpPermissions.1.ToPort": "4800",
            "IpPermissions.1.IpRanges.1.CidrIp": "0.0.0.0/0"}),
        ("ESP (proto 50)",               {"IpPermissions.1.IpProtocol": "50",
            "IpPermissions.1.FromPort": "-1",   "IpPermissions.1.ToPort": "-1",
            "IpPermissions.1.IpRanges.1.CidrIp": "0.0.0.0/0"}),
        ("UDP 4490 (NAT-D probe)",       {"IpPermissions.1.IpProtocol": "udp",
            "IpPermissions.1.FromPort": "4490", "IpPermissions.1.ToPort": "4490",
            "IpPermissions.1.IpRanges.1.CidrIp": "0.0.0.0/0"}),
    ]

    for sg_id in all_sg_ids:
        print(f"Patching SG {sg_id}:")
        for label, rule in rules:
            params = {"GroupId": sg_id}
            params.update(rule)
            result = _ec2("AuthorizeSecurityGroupIngress", params, region, ak, sk, token)
            print(f"  {label}: {'already exists' if result is None else 'added OK'}")

    print(f"Done — Submariner IPsec rules applied to instance '{instance_id}'")

main()
PYEOF
}

# ── WaitForGatewayNode — wait for Submariner MachineSet and gateway-labeled node
# SPOKE CLUSTERS: identical to upstream main branch.
# subctl cloud prepare with --gateways 1 is async: it creates a submariner
# MachineSet and labels the node submariner.io/gateway=true once Ready.
# subctl join prompts interactively when no gateway-labeled node exists yet.
# This function gates the broker-join step until exactly one gateway node exists.
WaitForGatewayNode() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset -i wMax="${SUBMARINER_GATEWAY_WAIT_TIMEOUT}"
    typeset -i wInt=15
    typeset gwMachineSet="" ms allMachineSets

    # Loop 1: wait for a Submariner MachineSet to appear (name contains "submariner")
    SECONDS=0
    until [[ -n "${gwMachineSet}" ]] || (( SECONDS >= wMax )); do
        allMachineSets="$(KUBECONFIG="${kubeconfig}" oc get machineset \
            -n openshift-machine-api \
            -o jsonpath='{.items[*].metadata.name}' || true)"
        for ms in ${allMachineSets}; do
            if [[ "${ms,,}" == *submariner* ]]; then
                gwMachineSet="${ms}"
                break
            fi
        done
        [[ -n "${gwMachineSet}" ]] && break
        : "Waiting for Submariner MachineSet on '${spokeName}' (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    [[ -n "${gwMachineSet}" ]] || {
        : "No submariner MachineSet on '${spokeName}' after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get machineset -n openshift-machine-api || true
        return 1
    }

    # Loop 2: wait for the MachineSet to have readyReplicas=1
    KUBECONFIG="${kubeconfig}" oc wait "machineset/${gwMachineSet}" \
        -n openshift-machine-api \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        --timeout="${wMax}s" || {
        : "Gateway MachineSet '${gwMachineSet}' not ready on '${spokeName}' after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get machineset "${gwMachineSet}" \
            -n openshift-machine-api -o wide || true
        return 1
    }

    # Loop 3: wait for exactly 1 node labeled submariner.io/gateway=true
    typeset -i gwCount=0
    SECONDS=0
    until (( gwCount == 1 || SECONDS >= wMax )); do
        gwCount="$(KUBECONFIG="${kubeconfig}" oc get nodes \
            -l submariner.io/gateway=true \
            -o json | jq '.items | length')" || gwCount=0
        (( gwCount == 1 )) && break
        : "Waiting for gateway-labeled node on '${spokeName}' gwCount=${gwCount} (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    if (( gwCount != 1 )); then
        : "Expected 1 gateway-labeled node on '${spokeName}', found ${gwCount} after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get nodes -l submariner.io/gateway=true -o wide || true
        return 1
    fi
}

# ── WaitForHubGatewayNode — wait for hub gateway (MachineSet or direct label) ─
# Hub and spokes both use c5n.metal bare-metal.  subctl cloud prepare aws may create
# a submariner-gw MachineSet (same as spoke) OR label an existing worker directly
# (when MachineSet provisioning is unavailable).  This function tries MachineSet
# first (short timeout), then falls back to label-only polling — giving correct
# behaviour regardless of which path subctl took.
WaitForHubGatewayNode() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset -i wMax="${SUBMARINER_GATEWAY_WAIT_TIMEOUT}"
    typeset -i wInt=15
    typeset -i msetDetectTimeout=120  # how long to wait for a submariner MachineSet to appear

    # ── Loop 1: check for a submariner MachineSet (short window) ─────────────
    typeset gwMachineSet="" ms allMachineSets
    SECONDS=0
    until [[ -n "${gwMachineSet}" ]] || (( SECONDS >= msetDetectTimeout )); do
        allMachineSets="$(KUBECONFIG="${kubeconfig}" oc get machineset \
            -n openshift-machine-api \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
        for ms in ${allMachineSets}; do
            if [[ "${ms,,}" == *submariner* ]]; then
                gwMachineSet="${ms}"
                break
            fi
        done
        [[ -n "${gwMachineSet}" ]] && break
        : "Checking for submariner MachineSet on hub '${clusterName}' (${SECONDS}/${msetDetectTimeout}s)"
        sleep "${wInt}"
    done

    if [[ -n "${gwMachineSet}" ]]; then
        : "Hub '${clusterName}' has submariner MachineSet '${gwMachineSet}' — waiting for readyReplicas=1"
        # ── Loop 2: wait for MachineSet ready ────────────────────────────────
        KUBECONFIG="${kubeconfig}" oc wait "machineset/${gwMachineSet}" \
            -n openshift-machine-api \
            --for=jsonpath='{.status.readyReplicas}'=1 \
            --timeout="${wMax}s" || {
            : "Gateway MachineSet '${gwMachineSet}' not ready on hub '${clusterName}' after ${wMax}s"
            KUBECONFIG="${kubeconfig}" oc get machineset "${gwMachineSet}" \
                -n openshift-machine-api -o wide || true
            return 1
        }
    else
        : "No submariner MachineSet found on hub '${clusterName}' after ${msetDetectTimeout}s — subctl labeled an existing worker directly"
    fi

    # ── Loop 3: wait for exactly 1 gateway-labeled node ──────────────────────
    typeset -i gwCount=0
    SECONDS=0
    until (( gwCount == 1 || SECONDS >= wMax )); do
        gwCount="$(KUBECONFIG="${kubeconfig}" oc get nodes \
            -l submariner.io/gateway=true \
            -o json | jq '.items | length')" || gwCount=0
        (( gwCount == 1 )) && break
        : "Waiting for gateway-labeled node on hub '${clusterName}' gwCount=${gwCount} (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    if (( gwCount != 1 )); then
        : "Expected 1 gateway-labeled node on hub '${clusterName}', found ${gwCount} after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get nodes -l submariner.io/gateway=true -o wide || true
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
command -v curl 1>/dev/null

[[ -n "${KUBECONFIG}" && -r "${KUBECONFIG}" ]]

# Hub enrollment is only required for hub↔spoke CCLM jobs.
typeset enrollHub="${SUBMARINER_VERIFY_HUB_SPOKE:-false}"

typeset hubMetadataFile="${SHARED_DIR}/metadata.json"
if [[ "${enrollHub}" == "true" ]]; then
    [[ -f "${hubMetadataFile}" ]] || {
        : "Hub metadata file not found at ${hubMetadataFile} — required for hub cloud prepare" >&2
        exit 1
    }
fi

LoadSpokeConfig
InstallSubctl
SetAwsCredentials

typeset -i submarinerStepRc=0
(
    # bash set -e is suppressed inside ( ... ) || ... — use explicit || _cloudFailed=1
    # on every critical call and make (( _cloudFailed == 0 )) the LAST command so
    # the subshell exit code accurately reflects any failure.
    typeset -i _cloudFailed=0
    typeset -i i

    # ── Hub cloud prepare (hub-spoke jobs only) ───────────────────────────────
    # Start hub prepare first so its gateway provision runs concurrently with
    # the spokes (subctl cloud prepare is async; we wait for all clusters below).
    if [[ "${enrollHub}" == "true" ]]; then
        PrepareHubAwsCluster \
            "${KUBECONFIG}" \
            "${hubMetadataFile}" \
            "hub" \
            || _cloudFailed=1
    fi

    # ── Spoke cloud prepare (all jobs) ────────────────────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        PrepareAwsCluster \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeMetadataFilesArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _cloudFailed=1
    done

    # ── Wait for gateway nodes ────────────────────────────────────────────────
    # Wait BEFORE patching SGs so EnsureWorkerSgHasIpsecPorts always targets
    # the confirmed-ready final gateway node (not a transient label on a worker
    # that subctl may have set temporarily while a MachineSet node provisions).
    if [[ "${enrollHub}" == "true" ]]; then
        WaitForHubGatewayNode "${KUBECONFIG}" "hub" || _cloudFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        WaitForGatewayNode \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _cloudFailed=1
    done

    # ── Patch gateway node SGs (after nodes are Ready and labeled) ────────────
    # EnsureWorkerSgHasIpsecPorts finds the gateway node via oc, then calls
    # DescribeInstances to get its actual SGs and adds Submariner IPsec ports.
    # For MachineSet-provisioned gateways the submariner-gw-sg already has these
    # rules so the call is idempotent (rules come back "already exists").
    # For bare-metal direct-labeled gateways the worker SG needs patching.
    # Called for ALL clusters uniformly — hub and spokes are treated identically.
    if [[ "${enrollHub}" == "true" ]]; then
        EnsureWorkerSgHasIpsecPorts \
            "${KUBECONFIG}" \
            "${hubMetadataFile}" \
            "hub" \
            || _cloudFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        EnsureWorkerSgHasIpsecPorts \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeMetadataFilesArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _cloudFailed=1
    done

    # LAST command: propagate any critical failure as the subshell exit code.
    (( _cloudFailed == 0 ))
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    if [[ "${SUBMARINER_CLOUD_PREPARE_DEBUG_MODE}" == "true" ]]; then
        : "WARNING: cloud-prepare failed (rc=${submarinerStepRc}); continuing in debug mode"
    else
        exit "${submarinerStepRc}"
    fi
fi
true
