#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- Variables ---
typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

# Get the creds from ACMQE CI vault and run the automation on pre-existing HUB
if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    : "------------ Skipping OCP Deploy = ${SKIP_OCP_DEPLOY} ------------"
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

# Update the AWS credentials in options.yaml from cluster profile
if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=
    typeset awsAccKeyToken=

    set +x
    awsAccKeyID="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsAccKeyToken="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    [ -n "${awsAccKeyID}" ] && [ -n "${awsAccKeyToken}" ]

    echo "Updating credentials in ${optionFile}..."
    yq -o json eval . "${optionFile}" |
    jq -c \
          --arg awsAccKeyID "${awsAccKeyID}" \
          --arg awsAccKeyToken "${awsAccKeyToken}" \
        '
          .options.connections.apiKeys.aws|=(
                .awsAccessKeyID=$awsAccKeyID |
                .awsSecretAccessKeyID=$awsAccKeyToken
            )
        ' |
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"
    set -x

    unset awsAccKeyID awsAccKeyToken
fi

: "Executing CLC interop commands..."
set +x
export CYPRESS_OPTIONS_HUB_PASSWORD=
CYPRESS_OPTIONS_HUB_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
set -x

set +x
typeset -i _test_rc=0
CYPRESS_BASE_URL="$(oc whoami --show-console)" \
CYPRESS_HUB_API_URL="$(oc whoami --show-server)" \
CYPRESS_CLC_OCP_IMAGE_VERSION="$(cat "${secretsDir}/clc/ocp_image_version")" \
CLOUD_PROVIDERS="$(cat "${secretsDir}/clc/ocp_cloud_providers")" \
bash +x ./execute_clc_interop_commands.sh || _test_rc=$?
set -x

unset CYPRESS_OPTIONS_HUB_PASSWORD

# INTEROP-9749: tag CLC-created opp-aws-* VPCs with expirationDate for collector GC.
# Leak evidence: 15 untagged opp-aws-* clusters (4 full + 11 shells, all us-east-2)
# cleaned in INTEROP-9746; creator identified as CLC Hive/CAPI path which never runs
# ipi-conf-aws (spoke evidence: acm-interop-p2p-cluster-install has no userTags;
# CLC path is same defect class — options.yaml has no tag surface, confirmed in
# 07-clc-tag-surface-recon.md §3).
# Mechanism: Hive ClusterDeployment -> install-config.yaml rendered server-side by
# Hive, never via ipi-conf-aws-commands.sh:33,272-273, so VPCs lack expirationDate
# and are invisible to aws-deprovision-collector (collector-commands.sh:209).
# Fix: post-creation aws ec2 create-tags after CLC automation returns, using the
# hub kubeconfig (oc get clusterdeployments) + AWS creds already in CLUSTER_PROFILE_DIR/.awscred.
# TTL 8h (date -d '8 hours' --iso=minutes --utc) gives 5h+ headroom over greens 45-48m
# / watchdog-capped 75m and matches ipi-conf-aws house convention; collector adds
# 30m grace via CLUSTER_TTL="30 minutes ago" -> reap >=8.5h after creation.
# Landing spot: step-wrapper fallback (c) — rhpit/interop-tests is a near-empty shim
# (no execute_clc_interop_commands.sh in any branch: main/ascerra/PR heads all 4 files)
# and stolostron/clc-ui-e2e is private (404 via gh api repos/stolostron/clc-ui-e2e).
# This wrapper is team-owned (OWNERS cspi-qe-ocp-lp/dtthuynh/vboulos), runs even when
# automation returns nonzero (_test_rc captured), and is the only guaranteed-landable
# spot this cycle. Upstream image fix (stolostron/clc-ui-e2e) should follow.
# Limitation: hard pod aborts (8h timeout, node eviction) before this block never tag;
# the collector periodic (INTEROP-9751) plus eventual upstream fix close that window.
: "Tagging CLC-created opp-aws-* VPCs with expirationDate for collector GC (INTEROP-9749)..."
set +e
# Credentials for aws CLI — same file the step injects into options.yaml.
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR:-}/.awscred"
export AWS_CONFIG_FILE="/var/run/secrets/aws/config/config"
typeset expirationDate=""
expirationDate="$(date -d '8 hours' --iso=minutes --utc 2>/dev/null)" || true
if [[ -z "${expirationDate:-}" ]]; then
    echo "WARNING: failed to compute expirationDate, skipping VPC tagging" >&2
elif [[ ! -f "${AWS_SHARED_CREDENTIALS_FILE:-}" ]]; then
    echo "WARNING: AWS credentials not found at ${AWS_SHARED_CREDENTIALS_FILE}, skipping VPC tagging" >&2
else
    # Bootstrap aws CLI if missing — clc-ui-e2e image lacks it (round-2 finding: every rehearsal
    # logged "WARNING: aws CLI not found, skipping VPC tagging"). Precedent: INTEROP-9517
    # (fcc1c63a77786:ci-operator/step-registry/interop/aws-cspi-qe-cleanup/interop-aws-cspi-qe-cleanup-commands.sh)
    # bootstrapped AWS CLI v2 in a golang image via curl+unzip to /tmp:
    #   curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    #   cd /tmp && unzip -q awscliv2.zip && ./aws/install --bin-dir /tmp/aws-bin --install-dir /tmp/aws-cli
    #   export PATH="/tmp/aws-bin:${PATH}"; aws --version
    # Layered, guarded, fail-soft: try v2 bundle if curl+unzip exist, else pip3, else loud-skip.
    if ! command -v aws >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
            echo "aws CLI not found, bootstrapping AWS CLI v2 bundle (INTEROP-9517 precedent)..." >&2
            if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip 2>&1; then
                if cd /tmp && unzip -q awscliv2.zip 2>&1 && ./aws/install --bin-dir /tmp/aws-bin --install-dir /tmp/aws-cli 2>/dev/null; then
                    export PATH="/tmp/aws-bin:${PATH}"
                    aws --version 2>&1 || true
                else
                    echo "WARNING: AWS CLI v2 bundle install failed" >&2 || true
                fi
                cd - >/dev/null 2>&1 || true
            else
                echo "WARNING: failed to download AWS CLI v2 bundle" >&2 || true
            fi
        fi
        if ! command -v aws >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
            echo "aws CLI still not found, trying pip3 install..." >&2
            pip3 install --user awscli 2>&1 || true
            export PATH="${HOME}/.local/bin:${PATH}"
            aws --version 2>&1 || true
        fi
    fi
    if ! command -v aws >/dev/null 2>&1; then
        echo "WARNING: aws CLI not found (bootstrap failed), skipping VPC tagging" >&2
    elif ! command -v oc >/dev/null 2>&1; then
        echo "WARNING: oc not found, skipping ClusterDeployment discovery" >&2
    elif ! command -v jq >/dev/null 2>&1; then
        echo "WARNING: jq not found, skipping ClusterDeployment discovery" >&2
    else
    echo "Tagging VPCs with expirationDate=${expirationDate} (TTL 8h, --iso=minutes --utc)" 
    typeset clusterNames=""
    # Prefer live ClusterDeployments from the hub (has hub kubeconfig via SHARED_DIR).
    clusterNames="$(oc get clusterdeployments -A --request-timeout=30s -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("^opp-aws-")) | .metadata.name' 2>/dev/null || true)"
    if [[ -z "${clusterNames:-}" ]]; then
        echo "No opp-aws-* ClusterDeployments via oc, checking reports for cluster names..." 
        if [[ -d reports ]]; then
            clusterNames="$(grep -rho 'opp-aws-[0-9]\+' reports 2>/dev/null | sort -u || true)"
        fi
    fi
    if [[ -z "${clusterNames:-}" ]]; then
        echo "No CLC-created opp-aws-* clusters discovered, skipping VPC tagging" 
    else
        typeset taggedCount=0
        # Region: active account regions (leaked inventory was all us-east-2); scan 3 to cover rotation.
        typeset regions="us-east-2 us-east-1 us-west-2"
        # Allow optionFile to override if it carries a region (not proven to exist, best-effort).
        if [[ -f "${optionFile:-}" ]]; then
            typeset optionRegion=""
            optionRegion="$(yq eval '.options.region // .platform.aws.region // ""' "${optionFile}" 2>/dev/null || true)"
            if [[ -n "${optionRegion:-}" && "${optionRegion}" != "null" ]]; then
                regions="${optionRegion} ${regions}"
            fi
        fi
        for clusterName in ${clusterNames}; do
            [[ -z "${clusterName:-}" ]] && continue
            echo "Processing CLC cluster ${clusterName}..." 
            for region in ${regions}; do
                [[ -z "${region:-}" ]] && continue
                typeset vpcIds=""
                vpcIds="$(aws ec2 describe-vpcs --region "${region}" --filters "Name=tag:Name,Values=${clusterName}-*-vpc" --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)"
                if [[ -z "${vpcIds:-}" || "${vpcIds}" == "None" ]]; then
                    continue
                fi
                for vpcId in ${vpcIds}; do
                    [[ -z "${vpcId:-}" || "${vpcId}" == "None" ]] && continue
                    typeset existingExpiration=""
                    if ! existingExpiration="$(aws ec2 describe-tags --region "${region}" --filters "Name=resource-id,Values=${vpcId}" "Name=key,Values=expirationDate" --query 'Tags[0].Value' --output text 2>/dev/null)"; then
                        echo "WARNING: failed to read expirationDate for VPC ${vpcId} in ${region}, skipping" >&2 || true
                        continue
                    fi
                    if [[ -n "${existingExpiration:-}" && "${existingExpiration}" != "None" ]]; then
                        echo "VPC ${vpcId} in ${region} already has expirationDate=${existingExpiration}, preserving (not overwriting)" 
                        if aws ec2 create-tags --region "${region}" --resources "${vpcId}" --tags "Key=clusterName,Value=${clusterName}" 2>&1; then
                            echo "Tagged VPC ${vpcId} in ${region} clusterName=${clusterName} (expirationDate preserved)" 
                        else
                            echo "WARNING: failed to tag VPC ${vpcId} clusterName in ${region} for ${clusterName}" >&2 || true
                        fi
                    else
                        echo "Tagging VPC ${vpcId} in ${region} for cluster ${clusterName} with expirationDate=${expirationDate}" 
                        if aws ec2 create-tags --region "${region}" --resources "${vpcId}" --tags "Key=expirationDate,Value=${expirationDate}" "Key=clusterName,Value=${clusterName}" 2>&1; then
                            echo "Tagged VPC ${vpcId} in ${region} (cluster ${clusterName})" 
                            taggedCount=$((taggedCount + 1))
                        else
                            echo "WARNING: failed to tag VPC ${vpcId} in ${region} for ${clusterName}" >&2 || true
                        fi
                    fi
                done
            done
        done
        echo "VPC tagging complete: ${taggedCount} VPC(s) tagged with expirationDate=${expirationDate}" 
    fi
    fi
fi
set -e

: "Copying artifacts..."
cp -r reports "${ARTIFACT_DIR}/"

exit "${_test_rc}"
