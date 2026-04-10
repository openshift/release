#!/usr/bin/env bash
#
# Nuke a StackRox CI OpenShift cluster by Prow job ID.
#
# Usage:
#   ./nuke-ci-cluster.sh <prow-job-id>
#   ./nuke-ci-cluster.sh <prow-job-id> --dry-run
#   ./nuke-ci-cluster.sh <prow-job-id> --force
#   ./nuke-ci-cluster.sh <prow-job-id> --force --wait
#   ./nuke-ci-cluster.sh <prow-job-id> --force --after-create
#
# The script derives the cluster name prefix from the last 8 digits of the
# job ID (rox-ci-XXXXXXXX), discovers the full infra-id from running VMs,
# and deletes all associated GCP resources.
#
# Modes:
#
#   Default: Immediately nuke the cluster (sabotage auth, kill VMs, cleanup).
#     This fights the installer retry loop (up to 10 retries / 90 min).
#     Best when the cluster is already mid-install or you want to act now.
#
#   --after-create: Wait for the cluster install to succeed, then nuke it
#     right before tests run. This is FASTER overall (~50 min vs ~90 min)
#     because a successful install takes ~45 min, and then tests fail in
#     minutes when the cluster disappears. The CI post step handles cleanup.
#
# Strategy (default mode):
#   1. Delete the workload identity pool (prevents installer retries from
#      authenticating to GCP, making them fail faster)
#   2. Delete service accounts
#   3. Kill all VMs
#   4. Clean up remaining infrastructure in dependency order
#   5. Optionally loop (--wait) killing new VMs until the job finishes
#
# Strategy (--after-create mode):
#   1. Wait for ocp-4-create step to finish successfully
#   2. Immediately kill all VMs (just instances is enough)
#   3. Tests fail quickly, CI post step runs ocp-4-destroy to clean up
#
# Requires: gcloud CLI authenticated to the acs-san-stackroxci project.

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-acs-san-stackroxci}"
DRY_RUN=false
FORCE=false
WAIT=false
AFTER_CREATE=false
# GCS prefix for job artifacts - can be overridden for non-default job names
GCS_JOB_PATH="${GCS_JOB_PATH:-}"

usage() {
    echo "Usage: $0 <prow-job-id> [--dry-run] [--force] [--wait] [--after-create]"
    echo ""
    echo "  prow-job-id     The numeric Prow job build ID"
    echo "  --dry-run       Show what would be deleted without deleting"
    echo "  --force         Skip confirmation prompt"
    echo "  --wait          After nuking, loop killing new VMs until job finishes"
    echo "  --after-create  Wait for cluster install to succeed, then nuke (faster)"
    echo ""
    echo "Environment variables:"
    echo "  GCP_PROJECT     GCP project (default: acs-san-stackroxci)"
    echo "  GCS_JOB_PATH    Override GCS path for job artifacts"
    exit 1
}

[[ $# -lt 1 ]] && usage

JOB_ID="$1"
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        --wait) WAIT=true ;;
        --after-create) AFTER_CREATE=true ;;
        *) usage ;;
    esac
    shift
done

# Derive cluster name prefix from last 8 digits of job ID
CLUSTER_PREFIX="rox-ci-${JOB_ID: -8}"
echo "Job ID:          $JOB_ID"
echo "Cluster prefix:  $CLUSTER_PREFIX"
echo "GCP Project:     $GCP_PROJECT"
echo ""

# Helper: delete a global-or-regional resource
delete_global_or_regional() {
    local resource_type="$1" name="$2" region="$3"
    region=$(basename "$region")
    if [[ -z "$region" || "$region" == "$name" ]]; then
        echo "  deleting global $resource_type $name"
        gcloud compute "$resource_type" delete "$name" --global --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
    else
        echo "  deleting $resource_type $name (region: $region)"
        gcloud compute "$resource_type" delete "$name" --region="$region" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
    fi
}

# Phase 1: Sabotage authentication (fastest way to prevent retries)
sabotage_auth() {
    echo "=== Phase 1: Sabotaging cluster authentication ==="

    echo "Deleting workload identity pool..."
    if gcloud iam workload-identity-pools describe "$CLUSTER_PREFIX" \
        --location=global --project="$GCP_PROJECT" &>/dev/null; then
        gcloud iam workload-identity-pools delete "$CLUSTER_PREFIX" \
            --location=global --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/  /' || true
        echo "  Deleted."
    else
        echo "  Not found (may already be deleted)."
    fi

    echo "Deleting service accounts..."
    local sa_list
    sa_list=$(gcloud iam service-accounts list --project="$GCP_PROJECT" \
        --filter="email~${INFRA_ID}" --format="value(email)" 2>/dev/null || true)
    if [[ -n "$sa_list" ]]; then
        echo "$sa_list" | while read -r email; do
            echo "  deleting $email"
            gcloud iam service-accounts delete "$email" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done
    else
        echo "  None found."
    fi
    echo ""
}

# Phase 2: Kill all VMs
kill_instances() {
    echo "=== Phase 2: Killing instances ==="
    local instances
    instances=$(gcloud compute instances list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,zone)" 2>/dev/null || true)
    if [[ -z "$instances" ]]; then
        echo "  No instances found."
        return
    fi
    echo "$instances" | while IFS=, read -r name zone; do
        zone=$(basename "$zone")
        echo "  killing $name ($zone)"
        gcloud compute instances delete "$name" --zone="$zone" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' &
    done
    wait
    echo ""
}

# Phase 3: Clean up infrastructure in correct dependency order
cleanup_infra() {
    echo "=== Phase 3: Cleaning up infrastructure ==="

    # 1. Forwarding rules (must go before target proxies and backend services)
    echo "[1/13] Forwarding rules..."
    gcloud compute forwarding-rules list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,region)" 2>/dev/null \
        | while IFS=, read -r name region; do
            [[ -z "$name" ]] && continue
            delete_global_or_regional "forwarding-rules" "$name" "$region"
        done

    # 2. Target TCP proxies (sits between forwarding rules and backend services)
    echo "[2/13] Target TCP proxies..."
    gcloud compute target-tcp-proxies list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="value(name)" 2>/dev/null \
        | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  deleting target-tcp-proxy $name"
            gcloud compute target-tcp-proxies delete "$name" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 3. Backend services (before instance groups and health checks)
    echo "[3/13] Backend services..."
    gcloud compute backend-services list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,region)" 2>/dev/null \
        | while IFS=, read -r name region; do
            [[ -z "$name" ]] && continue
            delete_global_or_regional "backend-services" "$name" "$region"
        done

    # 4. Instance groups
    echo "[4/13] Instance groups..."
    gcloud compute instance-groups list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,zone)" 2>/dev/null \
        | while IFS=, read -r name zone; do
            [[ -z "$name" ]] && continue
            zone=$(basename "$zone")
            echo "  deleting instance group $name ($zone)"
            gcloud compute instance-groups unmanaged delete "$name" --zone="$zone" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 5. Target pools
    echo "[5/13] Target pools..."
    gcloud compute target-pools list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,region)" 2>/dev/null \
        | while IFS=, read -r name region; do
            [[ -z "$name" ]] && continue
            region=$(basename "$region")
            echo "  deleting target pool $name ($region)"
            gcloud compute target-pools delete "$name" --region="$region" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 6. Health checks
    echo "[6/13] Health checks..."
    gcloud compute health-checks list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="value(name)" 2>/dev/null \
        | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  deleting health check $name"
            gcloud compute health-checks delete "$name" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 7. Firewall rules
    echo "[7/13] Firewall rules..."
    gcloud compute firewall-rules list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="value(name)" 2>/dev/null \
        | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  deleting firewall rule $name"
            gcloud compute firewall-rules delete "$name" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 8. Addresses
    echo "[8/13] Addresses..."
    gcloud compute addresses list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,region)" 2>/dev/null \
        | while IFS=, read -r name region; do
            [[ -z "$name" ]] && continue
            delete_global_or_regional "addresses" "$name" "$region"
        done

    # 9. Routers
    echo "[9/13] Routers..."
    gcloud compute routers list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,region)" 2>/dev/null \
        | while IFS=, read -r name region; do
            [[ -z "$name" ]] && continue
            region=$(basename "$region")
            echo "  deleting router $name ($region)"
            gcloud compute routers delete "$name" --region="$region" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 10. Subnets
    echo "[10/13] Subnets..."
    gcloud compute networks subnets list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,region)" 2>/dev/null \
        | while IFS=, read -r name region; do
            [[ -z "$name" ]] && continue
            region=$(basename "$region")
            echo "  deleting subnet $name ($region)"
            gcloud compute networks subnets delete "$name" --region="$region" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 11. Networks
    echo "[11/13] Networks..."
    gcloud compute networks list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="value(name)" 2>/dev/null \
        | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  deleting network $name"
            gcloud compute networks delete "$name" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    # 12. Remaining disks
    echo "[12/13] Remaining disks..."
    gcloud compute disks list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="csv[no-heading](name,zone)" 2>/dev/null \
        | while IFS=, read -r name zone; do
            [[ -z "$name" ]] && continue
            zone=$(basename "$zone")
            echo "  deleting disk $name ($zone)"
            gcloud compute disks delete "$name" --zone="$zone" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' &
        done
    wait

    # 13. DNS zones
    echo "[13/13] DNS zones..."
    gcloud dns managed-zones list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="value(name)" 2>/dev/null \
        | while read -r zone_name; do
            [[ -z "$zone_name" ]] && continue
            echo "  clearing DNS records in $zone_name"
            gcloud dns record-sets list --zone="$zone_name" --project="$GCP_PROJECT" \
                --format="csv[no-heading](name,type)" 2>/dev/null \
                | grep -v ',NS$' | grep -v ',SOA$' \
                | while IFS=, read -r rname rtype; do
                    gcloud dns record-sets delete "$rname" --zone="$zone_name" \
                        --type="$rtype" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/      /' || true
                done
            echo "  deleting DNS zone $zone_name"
            gcloud dns managed-zones delete "$zone_name" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' || true
        done

    echo ""
}

# Phase 4: Wait loop - keep killing new VMs until job finishes
wait_for_job() {
    echo "=== Phase 4: Monitoring for new instances until job finishes ==="
    local max_iterations=120  # 60 minutes at 30s intervals
    for (( i=1; i<=max_iterations; i++ )); do
        # Kill any new instances
        local instances
        instances=$(gcloud compute instances list --project="$GCP_PROJECT" \
            --filter="name~${CLUSTER_PREFIX}" --format="csv[no-heading](name,zone)" 2>/dev/null || true)
        if [[ -n "$instances" ]]; then
            echo "$(date): Found new instances, killing..."
            echo "$instances" | while IFS=, read -r name zone; do
                zone=$(basename "$zone")
                echo "  killing $name ($zone)"
                gcloud compute instances delete "$name" --zone="$zone" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' &
            done
            wait
        fi

        # Check if the job has finished
        resolve_gcs_path
        if gsutil -q stat "${GCS_JOB_PATH}/finished.json" 2>/dev/null; then
            local result
            result=$(gsutil cat "${GCS_JOB_PATH}/finished.json" 2>/dev/null || echo "unknown")
            echo "$(date): Job finished! $result"
            return 0
        fi

        sleep 30
    done
    echo "$(date): Timed out waiting for job to finish after $((max_iterations * 30 / 60)) minutes."
    return 1
}

# Resolve GCS job path for checking job artifacts
resolve_gcs_path() {
    if [[ -n "$GCS_JOB_PATH" ]]; then
        return
    fi
    # Try to find the job path from GCS by searching common patterns
    for path_pattern in \
        "gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-21-merge-qa-e2e-tests/${JOB_ID}" \
        "gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-22-merge-qa-e2e-tests/${JOB_ID}"; do
        if gsutil -q stat "${path_pattern}/prowjob.json" 2>/dev/null; then
            GCS_JOB_PATH="$path_pattern"
            return
        fi
    done
    # Fallback: try to find via prowjob.json
    GCS_JOB_PATH="gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-21-merge-qa-e2e-tests/${JOB_ID}"
}

# Phase 0: --after-create mode - wait for install, then nuke
after_create_mode() {
    resolve_gcs_path
    echo "=== After-create mode: waiting for cluster install to succeed ==="
    echo "Monitoring: ${GCS_JOB_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json"
    echo ""

    # Wait for the create step to finish
    while true; do
        local create_finished
        create_finished=$(gsutil cat "${GCS_JOB_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null || true)
        if [[ -n "$create_finished" ]]; then
            echo ""
            echo "$(date): Create step finished!"
            echo "$create_finished"
            break
        fi

        # Also check if the overall job already finished (e.g. timed out)
        local job_finished
        job_finished=$(gsutil cat "${GCS_JOB_PATH}/finished.json" 2>/dev/null || true)
        if [[ -n "$job_finished" ]]; then
            echo ""
            echo "$(date): Job already finished: $job_finished"
            echo "Nothing to nuke."
            exit 0
        fi

        echo -n "."
        sleep 30
    done

    echo ""
    echo "Cluster install complete. Nuking cluster to fail tests..."
    echo ""

    # Discover infra-id from instances or logs
    INFRA_ID=$(gcloud compute instances list \
        --project="$GCP_PROJECT" \
        --filter="name~^${CLUSTER_PREFIX}" \
        --format="value(name)" 2>/dev/null \
        | head -1 \
        | grep -oP "^rox-ci-\d+-[a-z0-9]+" || true)

    if [[ -z "$INFRA_ID" ]]; then
        # Try from logs
        INFRA_ID=$(gsutil cat "${GCS_JOB_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/build-log.txt" 2>/dev/null \
            | gunzip 2>/dev/null \
            | grep -oP 'CLUSTER_NAME=\K\S+' \
            | head -1 || true)
    fi

    if [[ -z "$INFRA_ID" ]]; then
        echo "ERROR: Could not determine cluster infra-id."
        exit 1
    fi

    echo "Infra-id: $INFRA_ID"

    # Just kill the instances - that's enough to fail the tests.
    # The CI post step (ocp-4-destroy) will handle full cleanup.
    kill_instances

    echo "========================================="
    echo "  Cluster instances killed."
    echo "  Tests should fail shortly."
    echo "  CI post step will handle cleanup."
    echo "========================================="

    if $WAIT; then
        wait_for_job
    fi
    exit 0
}

# === Main ===

# Handle --after-create mode early
if $AFTER_CREATE; then
    after_create_mode
fi

# Discover the full infra-id from running instances
echo "Discovering infra-id from running instances..."
INFRA_ID=$(gcloud compute instances list \
    --project="$GCP_PROJECT" \
    --filter="name~^${CLUSTER_PREFIX}" \
    --format="value(name)" 2>/dev/null \
    | head -1 \
    | grep -oP "^rox-ci-\d+-[a-z0-9]+" || true)

if [[ -z "$INFRA_ID" ]]; then
    echo "No instances found matching prefix '${CLUSTER_PREFIX}'."
    echo ""
    echo "Checking GCS for cluster name from job artifacts..."
    INFRA_ID=$(gsutil cat \
        "gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-21-merge-qa-e2e-tests/${JOB_ID}/artifacts/merge-qa-e2e-tests/ocp-4-create/build-log.txt" 2>/dev/null \
        | gunzip 2>/dev/null \
        | grep -oP 'CLUSTER_NAME=\K\S+' \
        | head -1 || true)
    if [[ -n "$INFRA_ID" ]]; then
        echo "Found cluster name from logs: $INFRA_ID"
        echo "No running instances, but will proceed with cleanup of other resources."
        echo ""
    else
        echo "No cluster found. The cluster may not have been provisioned yet."
        if $WAIT; then
            echo "Waiting for cluster to appear..."
            while true; do
                INFRA_ID=$(gcloud compute instances list \
                    --project="$GCP_PROJECT" \
                    --filter="name~^${CLUSTER_PREFIX}" \
                    --format="value(name)" 2>/dev/null \
                    | head -1 \
                    | grep -oP "^rox-ci-\d+-[a-z0-9]+" || true)
                if [[ -n "$INFRA_ID" ]]; then
                    echo "Found infra-id: $INFRA_ID"
                    break
                fi
                echo "$(date): waiting..."
                sleep 30
            done
        else
            exit 1
        fi
    fi
fi

echo "Infra-id:        $INFRA_ID"
echo ""

if $DRY_RUN; then
    echo "[DRY RUN] Surveying resources..."
    echo ""
    for desc_filter_fmt in \
        "Instances|instances list|name~${INFRA_ID}|csv[no-heading](name,zone)" \
        "Instance Groups|instance-groups list|name~${INFRA_ID}|csv[no-heading](name,zone)" \
        "Forwarding Rules|forwarding-rules list|name~${INFRA_ID}|csv[no-heading](name,region)" \
        "Target TCP Proxies|target-tcp-proxies list|name~${INFRA_ID}|value(name)" \
        "Backend Services|backend-services list|name~${INFRA_ID}|csv[no-heading](name,region)" \
        "Health Checks|health-checks list|name~${INFRA_ID}|value(name)" \
        "Firewall Rules|firewall-rules list|name~${INFRA_ID}|value(name)" \
        "Routers|routers list|name~${INFRA_ID}|csv[no-heading](name,region)" \
        "Subnets|networks subnets list|name~${INFRA_ID}|csv[no-heading](name,region)" \
        "Networks|networks list|name~${INFRA_ID}|value(name)" \
        "Addresses|addresses list|name~${INFRA_ID}|csv[no-heading](name,region)" \
        "Disks|disks list|name~${INFRA_ID}|csv[no-heading](name,zone)"; do
        IFS='|' read -r desc cmd filter fmt <<< "$desc_filter_fmt"
        echo "--- $desc ---"
        # shellcheck disable=SC2086
        gcloud compute $cmd --project="$GCP_PROJECT" --filter="$filter" --format="$fmt" 2>/dev/null | grep . || echo "(none)"
        echo ""
    done
    echo "--- Workload Identity Pool ---"
    gcloud iam workload-identity-pools describe "$CLUSTER_PREFIX" \
        --location=global --project="$GCP_PROJECT" --format="value(name)" 2>/dev/null || echo "(none)"
    echo ""
    echo "--- DNS Zones ---"
    gcloud dns managed-zones list --project="$GCP_PROJECT" \
        --filter="name~${INFRA_ID}" --format="value(name)" 2>/dev/null | grep . || echo "(none)"
    echo ""
    echo "--- Service Accounts ---"
    gcloud iam service-accounts list --project="$GCP_PROJECT" \
        --filter="email~${INFRA_ID}" --format="value(email)" 2>/dev/null | grep . || echo "(none)"
    echo ""
    echo "[DRY RUN] Would delete all resources listed above."
    exit 0
fi

if ! $FORCE; then
    read -rp "Nuke cluster ${INFRA_ID} (job ${JOB_ID})? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; exit 1; }
fi

echo ""

# Execute in order: sabotage auth first (fastest impact), then kill VMs, then cleanup
sabotage_auth
kill_instances
cleanup_infra

echo "========================================="
echo "  Cluster $INFRA_ID nuked."
echo "========================================="

if $WAIT; then
    wait_for_job
fi
