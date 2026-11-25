#!/bin/bash
set -euo pipefail

: "${SHARED_DIR:?SHARED_DIR must be set}"
: "${CLUSTER_PROFILE_DIR:?CLUSTER_PROFILE_DIR must be set}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"

echo "=== BYOH node-pool provisioning ==="

if [[ -z "${BYOH_INSTANCE_NAME:-}" ]]; then
    chars="0123456789abcdefghijklmnopqrstuvwxyz"
    suffix=""
    for _ in 1 2 3; do
        suffix+="${chars:$((RANDOM % ${#chars})):1}"
    done
    BYOH_INSTANCE_NAME="byoh-${suffix}"
fi
export BYOH_INSTANCE_NAME
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-3}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2025}"
export BYOH_TMP_DIR="${ARTIFACT_DIR}/terraform_byoh/"
export USE_NODE_POOL=true

case "${BYOH_NODE_POOL_WAIT_FOR_READY:-false}" in
    true)
        # Ready-node registration uses the provisioned InternalIPs. Keep the pool and
        # windows-instances address choices consistent for the pre-registered OTE path.
        export WMCO_IDENTIFIER_TYPE=ip
        ;;
    false) ;;
    *)
        echo "ERROR: BYOH_NODE_POOL_WAIT_FOR_READY must be true or false" >&2
        exit 1
        ;;
esac

printf '%s\n' "${BYOH_INSTANCE_NAME}" > "${SHARED_DIR}/byoh_instance_name.txt"

if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
    echo "ERROR: ${CLUSTER_PROFILE_DIR}/ssh-publickey not found" >&2
    exit 1
fi
WINC_SSH_PUBLIC_KEY="$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")"
export WINC_SSH_PUBLIC_KEY

if [[ ! -f "${CLUSTER_PROFILE_DIR}/.awscred" ]]; then
    echo "ERROR: ${CLUSTER_PROFILE_DIR}/.awscred not found" >&2
    exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_PROFILE=default

if [[ -f "${SHARED_DIR}/AWS_REGION" ]]; then
    AWS_REGION="$(<"${SHARED_DIR}/AWS_REGION")"
    export AWS_REGION
    export AWS_DEFAULT_REGION="${AWS_REGION}"
elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    export AWS_REGION="${AWS_DEFAULT_REGION}"
else
    echo "ERROR: AWS region is missing from SHARED_DIR/AWS_REGION and AWS_DEFAULT_REGION" >&2
    exit 1
fi

if [[ -f "${SHARED_DIR}/AWS_WINDOWS_AMI" ]]; then
    AWS_WINDOWS_AMI="$(<"${SHARED_DIR}/AWS_WINDOWS_AMI")"
    export AWS_WINDOWS_AMI
fi

if ! command -v terraform >/dev/null 2>&1 || [[ ! -x /usr/local/share/byoh-provisioner/byoh.sh ]]; then
    echo "ERROR: terraform-windows-provisioner image is missing terraform or byoh.sh" >&2
    exit 1
fi

cd /usr/local/share/byoh-provisioner
terraform version -no-color
echo "Provisioning ${BYOH_NUM_WORKERS} Windows ${BYOH_WINDOWS_VERSION} hosts with USE_NODE_POOL=true"

apply_status=0
if ./byoh.sh apply "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"; then
    echo "BYOH node-pool provisioning completed"
else
    apply_status=$?
    echo "ERROR: byoh.sh apply failed with status ${apply_status}; checking for partial Terraform state" >&2
fi

# This AWS UPI workflow is platform=none. Archive state before handling an
# apply failure so the post chain can destroy any instances Terraform created.
terraform_dir="${BYOH_TMP_DIR}none"
if [[ ! -d "${terraform_dir}" ]]; then
    echo "ERROR: Terraform directory not found at ${terraform_dir}" >&2
    ls -la "${BYOH_TMP_DIR}" || true
    if [[ "${apply_status}" -ne 0 ]]; then
        exit "${apply_status}"
    fi
    exit 1
fi

archive="${SHARED_DIR}/terraform_byoh_none.tar"
if tar -cf "${archive}" -C "${terraform_dir}" --exclude='.terraform' .; then
    echo "Terraform state archived to ${archive}"
    ls -lh "${archive}"
else
    archive_status=$?
    echo "ERROR: Failed to archive Terraform state from ${terraform_dir}" >&2
    exit "${archive_status}"
fi

if [[ "${apply_status}" -ne 0 ]]; then
    echo "ERROR: State was archived for teardown, but BYOH provisioning failed" >&2
    exit "${apply_status}"
fi

if [[ "${BYOH_NODE_POOL_WAIT_FOR_READY:-false}" == "true" ]]; then
    instance_ips="$(terraform -chdir="${terraform_dir}" output -json instance_ip)"
    instance_hostnames="$(terraform -chdir="${terraform_dir}" output -json instance_hostname)"
    if ! jq -e --argjson expected "${BYOH_NUM_WORKERS}" '
        type == "array" and length == $expected and (unique | length) == $expected
        and all(.[]; type == "string" and length > 0)
    ' <<< "${instance_ips}" >/dev/null; then
        echo "ERROR: Terraform must provide one distinct IP per requested BYOH host" >&2
        exit 1
    fi

    # Reserve these entries before registering the hosts. The final provisioned host
    # is marked disposable for the key-rotation coverage; the other hosts remain
    # reusable. oc replace retains the resourceVersion, so a concurrent claim fails closed.
    disposable_ip="$(jq -r '.[-1]' <<< "${instance_ips}")"
    pool="$(oc get configmap windows-node-pool -n openshift-windows-machine-config-operator -o json)"
    held_pool="$(jq -e --argjson ips "${instance_ips}" --argjson hostnames "${instance_hostnames}" \
        --arg disposable "${disposable_ip}" \
        --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        . as $pool
        | if all($ips[]; . as $ip | $pool.data[$ip] | type == "string") then .
          else error("node pool is missing provisioned IP entries") end
        | ($ips + $hostnames) as $addresses
        | .data |= with_entries(
            .key as $address
            | if ($addresses | index($address)) != null then
                (.value | split("\n")) as $lines
                | if ([$lines[] | select(startswith("status:"))] == ["status: available"])
                    and ([$lines[] | select(startswith("test-id:"))] | length == 1)
                    and ([$lines[] | select(startswith("allocated-at:"))] | length == 1)
                    and all($lines[] | select(startswith("test-id:") or startswith("allocated-at:"));
                        test("^[a-z-]+:[[:space:]]*$")) then
                    .value = ($lines
                        | map(select(startswith("disposable:") | not))
                        | map(
                            if startswith("last-updated:") then "last-updated: " + $updated
                            else . end)
                        + ["disposable: " + (if $address == $disposable then "true" else "false" end)]
                        | join("\n"))
                  else error("refusing to register an owned or unavailable pool host") end
              else . end)
    ' <<< "${pool}")"
    printf '%s\n' "${held_pool}" | oc replace -f -

    # Reuse the provisioner's registration action, not another VM apply. Leave
    # the hosts joined for the pre-registered OTE run; teardown still destroys the pool VMs.
    USE_NODE_POOL=false ./byoh.sh configmap "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"

    ready_timeout="${BYOH_READY_TIMEOUT:-45m}"
    echo "Waiting for ${BYOH_NUM_WORKERS} BYOH Windows nodes to become Ready (timeout: ${ready_timeout})..."
    if timeout "${ready_timeout}" bash -s -- "${instance_ips}" "${BYOH_NUM_WORKERS}" <<'READINESS_EOF'
        set -euo pipefail
        ips="$1"
        expected="$2"
        loops=0
        while true; do
            if nodes="$(oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true -o json)"; then
                selected="$(jq --argjson ips "${ips}" '
                    [.items[] | select(any(.status.addresses[]?;
                        .type == "InternalIP" and (.address as $ip | $ips | index($ip) != null)))]
                ' <<< "${nodes}")"
                total="$(jq length <<< "${selected}")"
                ready="$(jq '[.[] | select(.spec.unschedulable != true and
                    any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<< "${selected}")"
                echo "[${loops}] BYOH nodes ready: ${ready}/${total} (waiting for ${expected})"
                if [[ "${total}" -eq "${expected}" && "${ready}" -eq "${expected}" ]]; then
                    printf "NAME\tSTATUS\tINTERNAL-IP\n"
                    jq -r '.[] | [.metadata.name, "Ready",
                        ([.status.addresses[] | select(.type == "InternalIP") | .address] | join(","))] | @tsv' <<< "${selected}"
                    exit 0
                fi
            else
                echo "Windows Node lookup failed; retrying until the readiness deadline" >&2
            fi
            loops=$((loops + 1))
            sleep 30
        done
READINESS_EOF
    then
        echo "All ${BYOH_NUM_WORKERS} BYOH Windows nodes are Ready; pool entries remain available for the OTE fixture to claim"
    else
        ready_status=$?
        echo "ERROR: BYOH Windows Node readiness check failed with status ${ready_status}" >&2
        oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true -o wide || true
        exit "${ready_status}"
    fi
fi
