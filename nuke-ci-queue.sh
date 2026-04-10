#!/usr/bin/env bash
#
# Automatically chain-kill queued StackRox CI jobs using --after-create strategy.
#
# Usage:
#   ./nuke-ci-queue.sh                    # Kill all queued jobs
#   ./nuke-ci-queue.sh --keep-after TIME  # Keep jobs triggered after TIME (UTC)
#   ./nuke-ci-queue.sh --max-kills N      # Stop after killing N jobs
#   ./nuke-ci-queue.sh --dry-run          # Show what would be killed
#
# Strategy:
#   1. Query prowjobs.js for pending/triggered ocp-4-21-merge-qa-e2e jobs
#   2. Wait for the current pending job's create step to succeed
#   3. Kill the cluster instances to fail the tests
#   4. Wait for the job to finish
#   5. Repeat for the next job in the queue
#
# Requires: gcloud CLI, gsutil, curl, python3

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-acs-san-stackroxci}"
JOB_NAME="${JOB_NAME:-branch-ci-stackrox-stackrox-master-ocp-4-21-merge-qa-e2e-tests}"
GCS_BASE="${GCS_BASE:-gs://test-platform-results/logs/${JOB_NAME}}"
PROVISIONER_SA="${PROVISIONER_SA:-openshift-ipi-provisioner@acs-san-stackroxci.iam.gserviceaccount.com}"
KEEP_AFTER="${KEEP_AFTER:-}"
MAX_KILLS="${MAX_KILLS:-0}"
DRY_RUN=false
DISABLE_SA=false
KILL_COUNT=0

usage() {
    echo "Usage: $0 [--keep-after TIME] [--max-kills N] [--dry-run] [--disable-sa]"
    echo ""
    echo "  --keep-after TIME   Keep jobs triggered after this UTC time (e.g. 2026-03-10T14:35:00Z)"
    echo "  --max-kills N       Stop after killing N jobs (0 = unlimited)"
    echo "  --dry-run           Show queue status without killing"
    echo "  --disable-sa        Use SA-disable strategy (fastest, ~2 min per job)"
    echo "                      Only used when no other jobs are in create/destroy phase"
    echo ""
    echo "Environment variables:"
    echo "  GCP_PROJECT      GCP project (default: acs-san-stackroxci)"
    echo "  JOB_NAME         Prow job name to target"
    echo "  PROVISIONER_SA   GCP SA to disable (default: openshift-ipi-provisioner@...)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-after) KEEP_AFTER="$2"; shift ;;
        --max-kills) MAX_KILLS="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        --disable-sa) DISABLE_SA=true ;;
        --help|-h) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
    shift
done

# Get the current queue state from prowjobs.js
get_queue() {
    curl -s "https://prow.ci.openshift.org/prowjobs.js?var=allBuilds&omit=annotations,labels,decoration_config,pod_spec" 2>/dev/null \
        | sed 's/^var allBuilds = //;s/;$//' \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
job_name = '${JOB_NAME}'
keep_after = '${KEEP_AFTER}'
jobs = [j for j in data.get('items', [])
        if j.get('spec',{}).get('job','') == job_name
        and j['status'].get('state','') in ('pending', 'triggered')]
jobs.sort(key=lambda j: j['metadata'].get('creationTimestamp',''))
for j in jobs:
    created = j['metadata'].get('creationTimestamp','')
    if keep_after and created > keep_after:
        continue
    state = j['status'].get('state','')
    build_id = j['status'].get('build_id','')
    print(f'{state}|{created}|{build_id}')
" 2>/dev/null
}

# Get the pending job (the one currently running or about to run)
get_pending_job_id() {
    curl -s "https://prow.ci.openshift.org/prowjobs.js?var=allBuilds&omit=annotations,labels,decoration_config,pod_spec" 2>/dev/null \
        | sed 's/^var allBuilds = //;s/;$//' \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
job_name = '${JOB_NAME}'
keep_after = '${KEEP_AFTER}'
jobs = [j for j in data.get('items', [])
        if j.get('spec',{}).get('job','') == job_name
        and j['status'].get('state','') == 'pending'
        and j['status'].get('build_id','')]
jobs.sort(key=lambda j: j['metadata'].get('creationTimestamp',''))
for j in jobs:
    created = j['metadata'].get('creationTimestamp','')
    if keep_after and created > keep_after:
        continue
    print(j['status']['build_id'])
    break
" 2>/dev/null
}

# Count remaining jobs to kill
count_remaining() {
    get_queue | wc -l | tr -d ' '
}

# Wait for instances to appear for a cluster prefix
wait_for_instances() {
    local prefix="$1"
    local job_id="$2"
    local gcs_path="${GCS_BASE}/${job_id}"
    echo "  Waiting for instances to appear..."
    for i in $(seq 1 120); do
        # Check if job or create step already finished (no point waiting)
        if gsutil -q stat "${gcs_path}/finished.json" 2>/dev/null; then
            echo "  Job already finished while waiting for instances."
            return 1
        fi
        if gsutil -q stat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null; then
            echo "  Create step finished while waiting. Checking for instances one more time..."
            local inst
            inst=$(gcloud compute instances list --project="$GCP_PROJECT" \
                --filter="name~^${prefix}" --format="value(name)" 2>/dev/null | head -1)
            if [[ -n "$inst" ]]; then
                echo "  Found instance: $inst"
                return 0
            fi
            echo "  No instances found after create finished."
            return 1
        fi
        local inst
        inst=$(gcloud compute instances list --project="$GCP_PROJECT" \
            --filter="name~^${prefix}" --format="value(name)" 2>/dev/null | head -1)
        if [[ -n "$inst" ]]; then
            echo "  Found instance: $inst"
            return 0
        fi
        sleep 15
    done
    echo "  Timed out waiting for instances"
    return 1
}

# Extract kubeconfig from the bootstrap ignition stored in GCS
extract_kubeconfig() {
    local prefix="$1"
    local infra_id="$2"
    local outfile="$3"
    local ign_bucket="${infra_id}-bootstrap-ignition"
    echo "  Extracting kubeconfig from gs://${ign_bucket}/bootstrap.ign..."
    gsutil cat "gs://${ign_bucket}/bootstrap.ign" 2>/dev/null | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
for f in data.get('storage', {}).get('files', []):
    if f.get('path') == '/opt/openshift/auth/kubeconfig':
        source = f['contents']['source']
        _, encoded = source.split(',', 1)
        decoded = base64.b64decode(encoded).decode()
        # Replace api-int with api for external access
        print(decoded.replace('api-int.', 'api.'))
        break
" > "$outfile" 2>/dev/null
    if [[ -s "$outfile" ]]; then
        echo "  Kubeconfig saved to $outfile"
        return 0
    fi
    echo "  Failed to extract kubeconfig"
    return 1
}

# Wait for the cluster API to be reachable
wait_for_api() {
    local cluster_name="$1"
    local api_host="api.${cluster_name}.ocp.ci.rox.systems"
    echo "  Waiting for API at ${api_host}:6443..."
    for i in $(seq 1 60); do
        if timeout 5 curl -sk "https://${api_host}:6443/version" &>/dev/null; then
            echo "  API is up!"
            return 0
        fi
        sleep 10
    done
    echo "  Timed out waiting for API"
    return 1
}

# Create the bootstrap-complete configmap to trick the installer
signal_bootstrap_complete() {
    local kubeconfig="$1"
    echo "  Creating bootstrap-complete configmap..."
    if KUBECONFIG="$kubeconfig" kubectl get configmap bootstrap -n kube-system &>/dev/null; then
        KUBECONFIG="$kubeconfig" kubectl patch configmap bootstrap -n kube-system \
            -p '{"data":{"status":"complete"}}' 2>&1 | sed 's/^/  /'
    else
        KUBECONFIG="$kubeconfig" kubectl create configmap bootstrap -n kube-system \
            --from-literal=status=complete 2>&1 | sed 's/^/  /'
    fi
}

# Fake the ClusterVersion to signal install-complete.
# Strategy: delete admission webhooks that block status changes,
# scale down CVO to prevent it from overwriting, then patch.
signal_install_complete() {
    local kubeconfig="$1"
    echo "  Signaling install-complete..."

    # Step 1: Delete admission webhooks that may block status patches
    echo "  Deleting admission webhooks..."
    KUBECONFIG="$kubeconfig" kubectl delete validatingwebhookconfigurations --all 2>&1 | sed 's/^/    /'
    KUBECONFIG="$kubeconfig" kubectl delete mutatingwebhookconfigurations --all 2>&1 | sed 's/^/    /'

    # Step 2: Scale down CVO to prevent it from overwriting our status
    echo "  Scaling down CVO..."
    KUBECONFIG="$kubeconfig" kubectl scale deployment cluster-version-operator \
        -n openshift-cluster-version --replicas=0 2>&1 | sed 's/^/    /'
    KUBECONFIG="$kubeconfig" kubectl delete pod -n openshift-cluster-version \
        --all --force --grace-period=0 2>&1 | sed 's/^/    /'
    sleep 5

    # Step 3: Wait for ClusterVersion to exist
    echo "  Waiting for ClusterVersion 'version' to exist..."
    for i in $(seq 1 30); do
        if KUBECONFIG="$kubeconfig" kubectl get clusterversion version &>/dev/null; then
            echo "  ClusterVersion exists."
            break
        fi
        sleep 10
    done

    # Step 4: Build and apply patch preserving required fields
    echo "  Patching ClusterVersion status..."
    local current_status
    current_status=$(KUBECONFIG="$kubeconfig" kubectl get clusterversion version -o json 2>/dev/null)
    if [[ -n "$current_status" ]]; then
        echo "$current_status" | python3 -c "
import sys, json
cv = json.load(sys.stdin)
status = cv.get('status', {})
patch = {
    'status': {
        'desired': status.get('desired', {'version': '4.21.0', 'image': 'unknown'}),
        'observedGeneration': status.get('observedGeneration', 1),
        'versionHash': status.get('versionHash', 'fake'),
        'availableUpdates': status.get('availableUpdates') or [],
        'conditions': [
            {'type': 'Available', 'status': 'True', 'lastTransitionTime': '2026-01-01T00:00:00Z', 'reason': 'Done', 'message': 'Done'},
            {'type': 'Failing', 'status': 'False', 'lastTransitionTime': '2026-01-01T00:00:00Z', 'reason': 'Done', 'message': ''},
            {'type': 'Progressing', 'status': 'False', 'lastTransitionTime': '2026-01-01T00:00:00Z', 'reason': 'Done', 'message': ''}
        ]
    }
}
print(json.dumps(patch))
" > /tmp/cv-patch.json
        KUBECONFIG="$kubeconfig" kubectl patch clusterversion version --type=merge --subresource=status \
            -p "$(cat /tmp/cv-patch.json)" 2>&1 | sed 's/^/    /'
        rm -f /tmp/cv-patch.json
    else
        echo "  Could not get current ClusterVersion."
    fi

    # Step 5: Verify the patch stuck and keep patching if CVO respawns
    echo "  Verifying ClusterVersion conditions..."
    local patch_success=false
    for attempt in $(seq 1 10); do
        local conditions
        conditions=$(KUBECONFIG="$kubeconfig" kubectl get clusterversion version \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status},{.status.conditions[?(@.type=="Failing")].status},{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
        echo "    Attempt $attempt: Available,Failing,Progressing = $conditions"
        if [[ "$conditions" == "True,False,False" ]]; then
            echo "  [OK] ClusterVersion conditions are correct!"
            patch_success=true
            break
        fi
        # Re-kill CVO if it respawned
        KUBECONFIG="$kubeconfig" kubectl delete pod -n openshift-cluster-version --all --force --grace-period=0 &>/dev/null
        # Re-apply patch
        if [[ -n "$current_status" ]]; then
            echo "$current_status" | python3 -c "
import sys, json
cv = json.load(sys.stdin)
status = cv.get('status', {})
patch = {
    'status': {
        'desired': status.get('desired', {'version': '4.21.0', 'image': 'unknown'}),
        'observedGeneration': status.get('observedGeneration', 1),
        'versionHash': status.get('versionHash', 'fake'),
        'availableUpdates': status.get('availableUpdates') or [],
        'conditions': [
            {'type': 'Available', 'status': 'True', 'lastTransitionTime': '2026-01-01T00:00:00Z', 'reason': 'Done', 'message': 'Done'},
            {'type': 'Failing', 'status': 'False', 'lastTransitionTime': '2026-01-01T00:00:00Z', 'reason': 'Done', 'message': ''},
            {'type': 'Progressing', 'status': 'False', 'lastTransitionTime': '2026-01-01T00:00:00Z', 'reason': 'Done', 'message': ''}
        ]
    }
}
print(json.dumps(patch))
" | KUBECONFIG="$kubeconfig" kubectl patch clusterversion version --type=merge --subresource=status -p "$(cat -)" &>/dev/null
        fi
        sleep 5
    done
    if ! $patch_success; then
        echo "  [WARN] Could not get ClusterVersion conditions to stick after 10 attempts."
        echo "  [WARN] Falling back to wait-for-create approach."
    fi
}

# Check if any other jobs have clusters being created/destroyed right now.
# Checks for bootstrap nodes (active provisioning) and also for clusters
# that are still installing (have bootstrap but no workers yet).
# The provisioner SA (OCP_4_GCP_SA) is used by all ocp-4 jobs during
# create and destroy phases.
other_jobs_creating() {
    local our_prefix="$1"

    # Check for bootstrap nodes from other jobs (active provisioning)
    local other_bootstraps
    other_bootstraps=$(gcloud compute instances list --project="$GCP_PROJECT" \
        --filter="name~bootstrap AND NOT name~${our_prefix}" \
        --format="value(name)" 2>/dev/null || true)
    if [[ -n "$other_bootstraps" ]]; then
        echo "$other_bootstraps"
        return 0  # other jobs ARE creating
    fi

    # Check for very recently created instances (< 5 min old) from other jobs
    # These might be in early provisioning before bootstrap appears
    local recent
    recent=$(gcloud compute instances list --project="$GCP_PROJECT" \
        --filter="name~^rox-ci- AND NOT name~${our_prefix} AND creationTimestamp>-PT5M" \
        --format="value(name)" 2>/dev/null | head -1 || true)
    if [[ -n "$recent" ]]; then
        echo "(recently created) $recent"
        return 0
    fi

    return 1  # safe to proceed
}

# Disable the provisioner SA to make the installer fail instantly
disable_provisioner_sa() {
    echo "  [SA] Disabling provisioner SA: $PROVISIONER_SA"
    gcloud iam service-accounts disable "$PROVISIONER_SA" \
        --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /'
}

# Re-enable the provisioner SA
enable_provisioner_sa() {
    echo "  [SA] Re-enabling provisioner SA: $PROVISIONER_SA"
    gcloud iam service-accounts enable "$PROVISIONER_SA" \
        --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /'
}

# SA-disable abort: disable the provisioner SA so the installer fails instantly.
# Only used when no other jobs are in create/destroy phase.
sa_disable_abort() {
    local job_id="$1"
    local prefix="$2"
    local gcs_path="${GCS_BASE}/${job_id}"

    echo "  [SA] Checking if SA-disable is safe..."

    # Check if other jobs are creating clusters
    local others
    if others=$(other_jobs_creating "$prefix"); then
        echo "  [SA] Other jobs have clusters being created:"
        echo "$others" | sed 's/^/    /'
        echo "  [SA] Not safe to disable SA. Falling back to fast_abort."
        return 1
    fi
    echo "  [SA] No other jobs creating. Safe to proceed."

    # Disable the SA
    disable_provisioner_sa

    # Set trap to always re-enable SA on exit/error
    trap 'enable_provisioner_sa' EXIT

    # Wait for the create step to finish (should be very fast)
    echo "  [SA] Waiting for create step to fail (should be ~2-5 min)..."
    local sa_start
    sa_start=$(date +%s)
    for i in $(seq 1 60); do
        # Safety check: re-enable if other jobs start creating
        if others=$(other_jobs_creating "$prefix"); then
            echo "  [SA] WARNING: Other job started creating! Re-enabling SA immediately."
            echo "$others" | sed 's/^/    /'
            enable_provisioner_sa
            trap - EXIT
            echo "  [SA] SA re-enabled. Falling back to fast_abort."
            return 1
        fi

        # Check if create step finished
        if gsutil -q stat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null; then
            local elapsed=$(( $(date +%s) - sa_start ))
            local create_result
            create_result=$(gsutil cat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null)
            echo "  [SA] Create step finished in ${elapsed}s! $create_result"
            break
        fi

        # Check if job already finished
        if gsutil -q stat "${gcs_path}/finished.json" 2>/dev/null; then
            echo "  [SA] Job already finished."
            enable_provisioner_sa
            trap - EXIT
            return 0
        fi

        sleep 10
    done

    # Re-enable SA immediately
    enable_provisioner_sa
    trap - EXIT

    echo "  [SA] SA re-enabled. Waiting for job to fail..."
    return 0
}

# Fast abort: extract kubeconfig from ignition, signal bootstrap complete,
# then kill instances. Falls back to wait-for-create if anything fails.
fast_abort() {
    local job_id="$1"
    local prefix="$2"
    local gcs_path="${GCS_BASE}/${job_id}"
    local cluster_name="$prefix"  # e.g. rox-ci-49586688

    echo "  [FAST] Attempting ignition-kubeconfig abort..."

    # Wait for instances to appear
    if ! wait_for_instances "$prefix" "$job_id"; then
        echo "  [FAST] No instances found, falling back to wait-for-create."
        return 1
    fi

    # Discover infra-id from instances
    local infra_id
    infra_id=$(gcloud compute instances list --project="$GCP_PROJECT" \
        --filter="name~^${prefix}" --format="value(name)" 2>/dev/null \
        | head -1 | grep -oP "^rox-ci-\d+-[a-z0-9]+" || true)
    if [[ -z "$infra_id" ]]; then
        echo "  [FAST] Could not determine infra-id, falling back."
        return 1
    fi
    echo "  [FAST] Infra-id: $infra_id"

    # Extract kubeconfig from ignition
    local kubeconfig="/tmp/${infra_id}-kubeconfig.yaml"
    if ! extract_kubeconfig "$prefix" "$infra_id" "$kubeconfig"; then
        echo "  [FAST] Kubeconfig extraction failed, falling back."
        return 1
    fi

    local gcs_path="${GCS_BASE}/${job_id}"

    # Check if create step already finished — if so, skip bootstrap signal and just kill
    if gsutil -q stat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null; then
        local create_result
        create_result=$(gsutil cat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null)
        echo "  [FAST] Create step already finished: $create_result"
        echo "  [FAST] Killing cluster instances to fail tests..."
        kill_cluster_instances "$prefix" || true
        rm -f "$kubeconfig"
        echo "  [FAST] Instances killed. Waiting for job to fail..."
        return 0
    fi

    # Wait for API to come up, but also check if create step finishes while waiting
    echo "  [FAST] Waiting for API..."
    local api_host="api.${cluster_name}.ocp.ci.rox.systems"
    local api_up=false
    for i in $(seq 1 60); do
        # Check if create step finished while we wait
        if gsutil -q stat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null; then
            echo "  [FAST] Create step finished while waiting for API."
            echo "  [FAST] Killing cluster instances..."
            kill_cluster_instances "$prefix" || true
            rm -f "$kubeconfig"
            return 0
        fi
        if gsutil -q stat "${gcs_path}/finished.json" 2>/dev/null; then
            echo "  [FAST] Job already finished."
            rm -f "$kubeconfig"
            return 0
        fi
        if timeout 5 curl -sk "https://${api_host}:6443/version" &>/dev/null; then
            api_up=true
            echo "  [FAST] API is up!"
            break
        fi
        sleep 10
    done

    if $api_up; then
        # Signal bootstrap complete (speeds up the bootstrap wait phase)
        signal_bootstrap_complete "$kubeconfig"
    fi

    # Wait for the create step to finish
    echo "  [FAST] Waiting for create step to complete..."
    for i in $(seq 1 60); do
        if gsutil -q stat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null; then
            local create_result
            create_result=$(gsutil cat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null)
            echo "  [FAST] Create step finished: $create_result"
            break
        fi
        if gsutil -q stat "${gcs_path}/finished.json" 2>/dev/null; then
            echo "  [FAST] Job already finished."
            rm -f "$kubeconfig"
            return 0
        fi
        sleep 15
    done

    # Now kill instances to fail the test steps
    echo "  [FAST] Killing cluster instances..."
    kill_cluster_instances "$prefix" || true

    # Clean up kubeconfig
    rm -f "$kubeconfig"

    echo "  [FAST] Instances killed. Waiting for job to fail..."
    return 0
}

# Fallback: wait for the create step to finish (success or failure)
wait_for_create() {
    local job_id="$1"
    local gcs_path="${GCS_BASE}/${job_id}"
    echo "  [FALLBACK] Waiting for create step to finish..."
    while true; do
        # Check if job already finished entirely
        if gsutil -q stat "${gcs_path}/finished.json" 2>/dev/null; then
            local result
            result=$(gsutil cat "${gcs_path}/finished.json" 2>/dev/null)
            echo "  Job already finished: $result"
            return 1
        fi
        # Check if create step finished
        if gsutil -q stat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null; then
            local create_result
            create_result=$(gsutil cat "${gcs_path}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" 2>/dev/null)
            echo "  Create step finished: $create_result"
            return 0
        fi
        sleep 30
    done
}

# Kill instances for a cluster prefix
kill_cluster_instances() {
    local prefix="$1"
    local instances
    instances=$(gcloud compute instances list --project="$GCP_PROJECT" \
        --filter="name~^${prefix}" --format="csv[no-heading](name,zone)" 2>/dev/null || true)
    if [[ -z "$instances" ]]; then
        echo "  No instances found for ${prefix}"
        return 1
    fi
    echo "$instances" | while IFS=, read -r name zone; do
        [[ -z "$name" ]] && continue
        zone=$(basename "$zone")
        echo "  Killing $name ($zone)"
        gcloud compute instances delete "$name" --zone="$zone" --project="$GCP_PROJECT" --quiet 2>&1 | sed 's/^/    /' &
    done
    wait
    return 0
}

# Wait for the overall job to finish
wait_for_job_finish() {
    local job_id="$1"
    local prefix="$2"
    local gcs_path="${GCS_BASE}/${job_id}"
    echo "  Waiting for job to finish..."
    for i in $(seq 1 120); do
        # Keep killing instances in case they respawn
        kill_cluster_instances "$prefix" 2>/dev/null || true
        # Check if done
        if gsutil -q stat "${gcs_path}/finished.json" 2>/dev/null; then
            local result
            result=$(gsutil cat "${gcs_path}/finished.json" 2>/dev/null)
            echo "  Job finished: $result"
            return 0
        fi
        sleep 30
    done
    echo "  Timed out waiting for job to finish"
    return 1
}

# === Main ===

echo "============================================"
echo "  StackRox CI Queue Killer"
echo "============================================"
echo "Job name:    $JOB_NAME"
echo "GCP project: $GCP_PROJECT"
[[ -n "$KEEP_AFTER" ]] && echo "Keep after:  $KEEP_AFTER"
[[ "$MAX_KILLS" -gt 0 ]] && echo "Max kills:   $MAX_KILLS"
echo ""

# Show queue
echo "Current queue:"
QUEUE=$(get_queue)
if [[ -z "$QUEUE" ]]; then
    echo "  No jobs to kill!"
    exit 0
fi
TOTAL=$(echo "$QUEUE" | wc -l | tr -d ' ')
echo "$QUEUE" | while IFS='|' read -r state created build_id; do
    printf "  %-12s %s %s\n" "$state" "$created" "${build_id:-(queued)}"
done
echo ""
echo "Total jobs to kill: $TOTAL"
echo ""

if $DRY_RUN; then
    echo "[DRY RUN] Would kill $TOTAL jobs using --after-create strategy."
    exit 0
fi

echo "Starting automated kill loop..."
echo ""

while true; do
    # Check kill limit
    if [[ "$MAX_KILLS" -gt 0 && "$KILL_COUNT" -ge "$MAX_KILLS" ]]; then
        echo "Reached max kills ($MAX_KILLS). Stopping."
        break
    fi

    # Get the current pending job
    JOB_ID=$(get_pending_job_id || true)
    if [[ -z "$JOB_ID" ]]; then
        REMAINING=$(count_remaining || echo "0")
        if [[ "$REMAINING" -gt 0 ]]; then
            echo "$(date): $REMAINING jobs queued but none pending yet. Waiting..."
            sleep 60
            continue
        else
            echo "$(date): No more jobs to kill!"
            break
        fi
    fi

    CLUSTER_PREFIX="rox-ci-${JOB_ID: -8}"
    KILL_COUNT=$((KILL_COUNT + 1))
    REMAINING=$(count_remaining || echo "?")

    echo "============================================"
    echo "  Kill #${KILL_COUNT} | ~${REMAINING} remaining"
    echo "  Job ID: $JOB_ID"
    echo "  Cluster: $CLUSTER_PREFIX"
    echo "  Time: $(date)"
    echo "============================================"

    # Strategy: fast_abort (bootstrap configmap + wait for create + kill instances)
    # Falls back to wait-for-create if fast_abort can't get started
    if fast_abort "$JOB_ID" "$CLUSTER_PREFIX"; then
        wait_for_job_finish "$JOB_ID" "$CLUSTER_PREFIX" || echo "  (wait timed out, moving on)"
    else
        echo ""
        echo "  Falling back to wait-for-create approach..."
        if wait_for_create "$JOB_ID"; then
            echo ""
            echo "  Create step finished. Nuking instances..."
            kill_cluster_instances "$CLUSTER_PREFIX" || true
            echo ""
            echo "  Instances killed. Waiting for job to fail..."
            wait_for_job_finish "$JOB_ID" "$CLUSTER_PREFIX" || echo "  (wait timed out, moving on)"
        else
            echo "  Job finished on its own (or failed during create)."
        fi
    fi

    echo ""
    echo "  Kill #${KILL_COUNT} complete."
    echo ""

    # Brief pause before next iteration
    sleep 10
done

echo ""
echo "============================================"
echo "  Queue killing complete."
echo "  Total jobs killed: $KILL_COUNT"
echo "============================================"
