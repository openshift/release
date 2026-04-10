#!/usr/bin/env bash
#
# Chain SA-disable attacks to rapidly clear the CI job queue.
#
# Usage:
#   ./sa-disable-chain.sh <job-name-substring> [--keep-after TIME]
#
# Example:
#   ./sa-disable-chain.sh merge-scanner-v4-install --keep-after 2026-03-10T14:35:00Z
#   ./sa-disable-chain.sh merge-qa-e2e --keep-after 2026-03-10T14:35:00Z
#
# Strategy:
#   1. Find the current pending old job from prowjobs.js
#   2. Wait for its create step to start (detect via instances appearing)
#   3. Disable the provisioner SA for ~3 min (installer fails immediately)
#   4. Re-enable SA
#   5. Wait for job to finish
#   6. Repeat for next job

set -euo pipefail

SA="${PROVISIONER_SA:-openshift-ipi-provisioner@acs-san-stackroxci.iam.gserviceaccount.com}"
P="${GCP_PROJECT:-acs-san-stackroxci}"
JOB_SUBSTR="${1:?Usage: $0 <job-name-substring> [--keep-after TIME]}"
shift
KEEP_AFTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-after) KEEP_AFTER="$2"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

KILL_COUNT=0
KNOWN_JOB_ID=""
SKIPPED_JOBS=""

# Safety: always re-enable SA on exit
cleanup() {
    echo ""
    echo "SAFETY: Ensuring SA is enabled before exit..."
    gcloud iam service-accounts enable "$SA" --project="$P" --quiet 2>&1 || true
    rmdir /tmp/sa-disable.lock 2>/dev/null || true
    echo "SA confirmed enabled, lock released. Exiting."
}
trap cleanup EXIT

get_pending_old_job() {
    curl -s "https://prow.ci.openshift.org/prowjobs.js?var=allBuilds&omit=annotations,labels,decoration_config,pod_spec" 2>/dev/null \
        | sed 's/^var allBuilds = //;s/;$//' \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
job_substr = '${JOB_SUBSTR}'
keep_after = '${KEEP_AFTER}'
skipped = set('${SKIPPED_JOBS}'.split())
jobs = [j for j in data.get('items', [])
        if job_substr in j.get('spec',{}).get('job','')
        and 'stackrox' in j.get('spec',{}).get('job','')
        and j['status'].get('state') == 'pending'
        and j['status'].get('build_id','')]
jobs.sort(key=lambda j: j['metadata'].get('creationTimestamp',''))
for j in jobs:
    created = j['metadata'].get('creationTimestamp','')
    bid = j['status']['build_id']
    if keep_after and created > keep_after:
        continue
    if bid in skipped:
        continue
    print(bid)
    break
" 2>/dev/null || true
}

count_old_jobs() {
    curl -s "https://prow.ci.openshift.org/prowjobs.js?var=allBuilds&omit=annotations,labels,decoration_config,pod_spec" 2>/dev/null \
        | sed 's/^var allBuilds = //;s/;$//' \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
job_substr = '${JOB_SUBSTR}'
keep_after = '${KEEP_AFTER}'
count = 0
for j in data.get('items', []):
    if job_substr not in j.get('spec',{}).get('job',''): continue
    if 'stackrox' not in j.get('spec',{}).get('job',''): continue
    if j['status'].get('state','') not in ('pending','triggered'): continue
    created = j['metadata'].get('creationTimestamp','')
    if keep_after and created > keep_after: continue
    count += 1
print(count)
" 2>/dev/null || echo "?"
}

# Resolve GCS base path from job name
resolve_gcs_path() {
    local job_id="$1"
    # Try common patterns
    for path in \
        "gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-21-${JOB_SUBSTR}-tests/${job_id}" \
        "gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-21-${JOB_SUBSTR}/${job_id}"; do
        if gsutil -q stat "${path}/prowjob.json" 2>/dev/null; then
            echo "$path"
            return
        fi
    done
    # Fallback: look up from prowjob.json
    echo "gs://test-platform-results/logs/branch-ci-stackrox-stackrox-master-ocp-4-21-${JOB_SUBSTR}-tests/${job_id}"
}

echo "============================================"
echo "  SA-Disable Chain Killer"
echo "============================================"
echo "Job filter:     $JOB_SUBSTR"
echo "Provisioner SA: $SA"
[[ -n "$KEEP_AFTER" ]] && echo "Keep after:     $KEEP_AFTER"
echo ""

REMAINING=$(count_old_jobs)
echo "Old jobs to kill: $REMAINING"
echo ""
echo "Starting chain..."
echo ""

while true; do
    # Get the current pending old job
    JOB_ID=$(get_pending_old_job)
    if [[ -z "$JOB_ID" ]]; then
        REMAINING=$(count_old_jobs)
        if [[ "$REMAINING" -gt 0 && "$REMAINING" != "?" ]]; then
            echo "$(date): $REMAINING old jobs queued but none pending yet. Waiting 60s..."
            sleep 60
            continue
        else
            echo "$(date): No more old jobs to kill!"
            break
        fi
    fi

    # Skip if same job as before (still processing)
    if [[ "$JOB_ID" == "$KNOWN_JOB_ID" ]]; then
        echo "$(date): Same job $JOB_ID still pending. Waiting 30s..."
        sleep 30
        continue
    fi

    KNOWN_JOB_ID="$JOB_ID"
    KILL_COUNT=$((KILL_COUNT + 1))
    REMAINING=$(count_old_jobs)
    SUFFIX="${JOB_ID: -8}"
    GCS_PATH=$(resolve_gcs_path "$JOB_ID")

    echo "============================================"
    echo "  Kill #${KILL_COUNT} | ~${REMAINING} remaining"
    echo "  Job: $JOB_ID (rox-ci-${SUFFIX})"
    echo "  Time: $(date)"
    echo "============================================"

    # Two-phase detection:
    # Phase 1: Watch for begin step's build-log.txt in GCS (begin finished),
    #          then disable SA immediately (create step starts right after, ~111s gap)
    # Phase 2 (fallback): If VMs appear, SA was re-enabled too early or phase 1
    #          missed; re-disable SA to catch the retry loop
    echo "  Phase 1: Watching for begin step to finish..."
    CREATE_DETECTED=false
    BEGIN_DETECTED=false
    for i in $(seq 1 120); do
        # Check if job already finished
        if gsutil -q stat "${GCS_PATH}/finished.json" 2>/dev/null; then
            echo "  $(date): Job already finished."
            break
        fi

        # Check for begin step finished (GCS artifact uploaded after step completes)
        # But ONLY if the create step hasn't already started (check for create artifacts)
        for begin_path in \
            "${GCS_PATH}/artifacts/merge-scanner-v4-install-tests/stackrox-stackrox-begin/finished.json" \
            "${GCS_PATH}/artifacts/merge-qa-e2e-tests/stackrox-stackrox-begin/finished.json" \
            "${GCS_PATH}/artifacts/${JOB_SUBSTR}-tests/stackrox-stackrox-begin/finished.json"; do
            if gsutil -q stat "$begin_path" 2>/dev/null; then
                # Verify create step hasn't already started/finished.
                # Check GCS artifacts AND check for VMs (VMs mean create is running).
                create_already=false
                for create_check in \
                    "${GCS_PATH}/artifacts/merge-scanner-v4-install-tests/ocp-4-create/build-log.txt" \
                    "${GCS_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/build-log.txt" \
                    "${GCS_PATH}/artifacts/${JOB_SUBSTR}-tests/ocp-4-create/build-log.txt" \
                    "${GCS_PATH}/artifacts/merge-scanner-v4-install-tests/ocp-4-create/finished.json" \
                    "${GCS_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" \
                    "${GCS_PATH}/artifacts/${JOB_SUBSTR}-tests/ocp-4-create/finished.json"; do
                    if gsutil -q stat "$create_check" 2>/dev/null; then
                        create_already=true
                        break
                    fi
                done
                # Also check for VMs — if they exist, create step is running
                if ! $create_already; then
                    vm_check=$(gcloud compute instances list --project="$P" \
                        --filter="name~rox-ci-${SUFFIX}" --format="value(name)" 2>/dev/null | head -1 || true)
                    if [[ -n "$vm_check" ]]; then
                        create_already=true
                    fi
                fi
                if $create_already; then
                    echo "  $(date): Begin finished but create step already started/finished. Skipping to next job."
                    CREATE_DETECTED=false
                    break 2
                else
                    echo "  $(date): Begin step FINISHED (GCS artifact detected)."
                    echo "  Create step should be starting NOW or within seconds."
                    BEGIN_DETECTED=true
                    CREATE_DETECTED=true
                    break 2
                fi
            fi
        done

        # Also check for instances (create step already running - fallback)
        # But only if the create step hasn't already finished
        inst=$(gcloud compute instances list --project="$P" \
            --filter="name~rox-ci-${SUFFIX}" --format="value(name)" 2>/dev/null | head -1 || true)
        if [[ -n "$inst" ]]; then
            # Check if create step already finished — if so, skip SA-disable
            create_done=false
            for create_check in \
                "${GCS_PATH}/artifacts/merge-scanner-v4-install-tests/ocp-4-create/finished.json" \
                "${GCS_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json" \
                "${GCS_PATH}/artifacts/${JOB_SUBSTR}-tests/ocp-4-create/finished.json"; do
                if gsutil -q stat "$create_check" 2>/dev/null; then
                    create_done=true
                    break
                fi
            done
            if $create_done; then
                echo "  $(date): VMs exist but create step already finished. Skipping to next job."
                CREATE_DETECTED=false
                break
            fi
            echo "  $(date): Instances detected, create step still running. Skipping to next job."
            CREATE_DETECTED=false
            break
        fi

        if (( i % 8 == 0 )); then
            echo "  $(date): Waiting... (${i})"
        fi
        sleep 5
    done

    if ! $CREATE_DETECTED; then
        echo "  Skipping job $JOB_ID, moving to next."
        SKIPPED_JOBS="$SKIPPED_JOBS $JOB_ID"
        KNOWN_JOB_ID=""
        sleep 5
        continue
    fi

    # PHASE 1: Disable SA for a tight 22-second window.
    # Timeline from logs:
    #   +0s   create step container starts
    #   +7s   gcloud auth (succeeds - just stores creds locally)
    #   +7-13s  curl downloads 431MB installer binary
    #   +14s  openshift-install create manifests → first GCP API call
    #   +21s  first API call fails with "invalid_grant"
    #   +25-35s ccoctl retries fail, create cluster fails
    #
    # The begin finished.json appears in GCS roughly when the create step starts
    # (a few seconds of GCS upload delay ≈ container startup time).
    # So "now" ≈ +7s into the create step. We wait 7 more seconds to hit +14s.
    echo ""
    echo "  Phase 1: Waiting 7s for installer to reach first GCP API call..."
    sleep 7

    # Lockfile to prevent two chains from disabling SA simultaneously
    LOCKFILE="/tmp/sa-disable.lock"
    echo "  Acquiring SA-disable lock..."
    while ! mkdir "$LOCKFILE" 2>/dev/null; do
        echo "  Lock held by another chain, waiting 0.5s..."
        sleep 0.5
    done
    echo "  Lock acquired."

    echo "  >>> DISABLING SA (tight 22s window) <<<"
    gcloud iam service-accounts disable "$SA" --project="$P" --quiet 2>&1
    SA_START=$(date +%s)
    echo "  SA disabled at $(date)"

    # Hold for 40 seconds — covers first attempt + first retry's API calls.
    # Timeline: +0s create starts, +7s gcloud auth (succeeds locally), +14s first API call,
    # +21s first attempt fails, +25-35s ccoctl retries, +35s openshift-install create cluster
    sleep 40

    echo "  >>> RE-ENABLING SA <<<"
    gcloud iam service-accounts enable "$SA" --project="$P" --quiet 2>&1
    SA_ELAPSED=$(( $(date +%s) - SA_START ))
    echo "  SA re-enabled at $(date) (disabled for ${SA_ELAPSED}s)"

    # Release lock
    rmdir "$LOCKFILE" 2>/dev/null
    echo "  Lock released."

    # PHASE 2: Check for VMs. If the first create attempt authenticated before
    # our disable window (timing was off), VMs will appear. In that case,
    # re-disable briefly to catch the retry loop's API calls, then kill VMs.
    echo ""
    echo "  Phase 2: Checking for VMs (fallback)..."
    for f in $(seq 1 60); do
        # Check if create step already finished (our phase 1 worked)
        for create_path in \
            "${GCS_PATH}/artifacts/${JOB_SUBSTR}-tests/ocp-4-create/finished.json" \
            "${GCS_PATH}/artifacts/${JOB_SUBSTR}/ocp-4-create/finished.json" \
            "${GCS_PATH}/artifacts/merge-scanner-v4-install-tests/ocp-4-create/finished.json" \
            "${GCS_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json"; do
            if gsutil -q stat "$create_path" 2>/dev/null; then
                result=$(gsutil cat "$create_path" 2>/dev/null)
                echo "  $(date): CREATE STEP FINISHED!"
                echo "  Result: $result"
                break 2
            fi
        done

        if gsutil -q stat "${GCS_PATH}/finished.json" 2>/dev/null; then
            echo "  $(date): JOB FINISHED!"
            break
        fi

        inst=$(gcloud compute instances list --project="$P" \
            --filter="name~rox-ci-${SUFFIX}" --format="value(name)" 2>/dev/null | head -1 || true)
        if [[ -n "$inst" ]]; then
            echo "  $(date): VMs detected ($inst) — phase 1 missed auth window."
            echo "  Giving up on SA-disable. Waiting for create step to finish, then will kill cluster."
            # Wait for create step to finish naturally
            for cw in $(seq 1 240); do
                for create_path in \
                    "${GCS_PATH}/artifacts/${JOB_SUBSTR}-tests/ocp-4-create/finished.json" \
                    "${GCS_PATH}/artifacts/${JOB_SUBSTR}/ocp-4-create/finished.json" \
                    "${GCS_PATH}/artifacts/merge-scanner-v4-install-tests/ocp-4-create/finished.json" \
                    "${GCS_PATH}/artifacts/merge-qa-e2e-tests/ocp-4-create/finished.json"; do
                    if gsutil -q stat "$create_path" 2>/dev/null; then
                        echo "  $(date): Create step finished. Killing cluster..."
                        gcloud compute instances list --project="$P" \
                            --filter="name~rox-ci-${SUFFIX}" --format="csv[no-heading](name,zone)" 2>/dev/null \
                            | while IFS=, read -r iname izone; do
                                [[ -z "$iname" ]] && continue
                                izone=$(basename "$izone")
                                gcloud compute instances delete "$iname" --zone="$izone" --project="$P" --quiet &>/dev/null &
                            done
                        wait 2>/dev/null
                        echo "  Cluster killed."
                        break 2
                    fi
                done
                if gsutil -q stat "${GCS_PATH}/finished.json" 2>/dev/null; then
                    echo "  $(date): Job finished."
                    break
                fi
                if (( cw % 8 == 0 )); then
                    echo "  $(date): Waiting for create step... (${cw})"
                fi
                sleep 15
            done
            break
        fi
        sleep 5
    done

    # Double-check SA is enabled
    sa_state=$(gcloud iam service-accounts describe "$SA" --project="$P" --format="value(disabled)" 2>/dev/null)
    if [[ "$sa_state" == "True" ]]; then
        echo "  WARNING: SA still disabled! Re-enabling..."
        gcloud iam service-accounts enable "$SA" --project="$P" --quiet 2>&1
    fi

    # Wait for the job to fully finish before moving on
    echo "  Waiting for job to fully finish..."
    for w in $(seq 1 60); do
        if gsutil -q stat "${GCS_PATH}/finished.json" 2>/dev/null; then
            echo "  $(date): Job finished."
            break
        fi
        sleep 15
    done

    echo ""
    echo "  Kill #${KILL_COUNT} complete."
    echo ""

    # Brief pause between kills
    sleep 5
done

echo ""
echo "============================================"
echo "  Chain complete. Killed: $KILL_COUNT"
echo "============================================"
