#!/usr/bin/env bash

set -euo pipefail

# Probe GCP on-demand capacity before the hypershift-gcp-create chain runs.
#
# GCP has no public real-time capacity API, but on-demand stockouts
# (ZONE_RESOURCE_POOL_EXHAUSTED) fail fast on the instances.insert call, so a
# trial-create is a cheap and reliable probe. We create a VM with the REAL
# candidate machine type (capacity pools are per zone x family, so a smaller
# probe shape could succeed where the actual shape fails), in a RANDOMIZED zone
# order (to avoid a concurrency stampede on whichever zone probes first), and
# delete it immediately on success.
#
# Outputs to ${SHARED_DIR}:
# - gcp-zone: first zone where a candidate machine type was available
# - gcp-machine-type: the machine type that was available in that zone
# - gcp-capacity-probe-vm: the probe VM name (for best-effort cleanup)
#
# The probe VM name is deterministic from PROW_JOB_ID so the deprovision step
# can clean it up even if SHARED_DIR is unavailable.

# Authenticate with GCP via WIF credential written by hypershift-gcp-wif-auth
# (this step runs after hypershift-gcp-gke-provision, which requires it too).
if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "ERROR: ${SHARED_DIR}/wif-cred.json not found — run hypershift-gcp-wif-auth first"
  exit 1
fi
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json"

GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"
HC_PROJECT_ID="$(<"${SHARED_DIR}/hosted-cluster-project-id")"

# amd64 only: the create chain pins an x86-64 RHCOS boot image.
# Candidate order: the machine type current e2e jobs implicitly use
# (hypershift's n2-standard-4 default) first, then the cheapest same-spec
# (4 vCPU / 16GB) alternative on the OpenShift-supported GCP machine type
# list. All candidates must be OpenShift-supported — e.g. E2 is NOT on the
# supported list and must not be added here.
MACHINE_TYPES=(${HYPERSHIFT_GCP_MACHINE_TYPES:-n2-standard-4 n2d-standard-4})

# Randomize zone order so concurrent jobs don't stampede the same zone first.
ZONES=("${GCP_REGION}-a" "${GCP_REGION}-b" "${GCP_REGION}-c")
for ((i=${#ZONES[@]}-1; i>0; i--)); do
  j=$((RANDOM % (i+1)))
  tmp="${ZONES[i]}"; ZONES[i]="${ZONES[j]}"; ZONES[j]="${tmp}"
done
echo "Probing zones in order: ${ZONES[*]}"

PROBE_VM_NAME="ci-probe-$(echo -n "${PROW_JOB_ID:-${BUILD_ID}}" | sha256sum | cut -c1-11)"
echo "${PROBE_VM_NAME}" > "${SHARED_DIR}/gcp-capacity-probe-vm"

# Leak prevention: sweep ALL zones of the region, not just the last probed
# zone — a gcloud timeout can leave a created VM behind in an earlier zone
# with a non-zero exit code. Every delete is best-effort (|| true); the
# hypershift-gcp-capacity-probe-cleanup post step validates that nothing
# leaked, and hypershift-gcp-gke-deprovision / Hosted Cluster project
# deletion are further backstops.
delete_probe_vm() {
  local del_zone
  for del_zone in "${ZONES[@]}"; do
    gcloud compute instances delete "${PROBE_VM_NAME}" \
      --project="${HC_PROJECT_ID}" \
      --zone="${del_zone}" \
      --quiet || true
  done
}
trap delete_probe_vm EXIT
# Ensure the EXIT trap (and thus VM cleanup) also runs on SIGTERM/SIGINT,
# which Prow sends when aborting a job.
trap 'exit 143' TERM
trap 'exit 130' INT

# Capacity-exhaustion is the ONLY failure that justifies trying the next
# candidate. Any other error (permission denied, auth failure, missing
# network/image, quota, a timed-out API call) must hard-fail with the real
# gcloud error, otherwise an unrelated regression would be mislabeled as a
# stockout by the GCP_NO_CAPACITY_IN_REGION message below.
is_capacity_error() {
  grep -Eq "ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED" <<<"$1"
}

probe_zone_and_type() {
  local zone="$1" machine_type="$2"
  # Bound each attempt: stockouts fail fast, but a hung API call must not
  # delay the signal-trap cleanup (or hold the job) indefinitely. 90s keeps
  # the worst case (zones x types hung attempts = 6 x 90s = 9m) inside the
  # step's 10m timeout, with VM cleanup covered by the 5m grace period.
  # A timed-out attempt (rc 124) is treated as a non-capacity error and
  # hard-fails: a hung insert is an infra problem worth human eyes, not a
  # reason to churn through the remaining candidates.
  #
  # --network=default: the probe relies on the ephemeral hosted cluster
  # project retaining GCP's implicit auto-mode default network — nothing in
  # this repo creates or disables it, but org-policy hardening that sets
  # compute.skipDefaultNetworkCreation would break the probe. Passing the
  # network explicitly makes that failure loud ("network not found") instead
  # of an ambiguous create error.
  timeout 90s gcloud compute instances create "${PROBE_VM_NAME}" \
    --project="${HC_PROJECT_ID}" \
    --zone="${zone}" \
    --machine-type="${machine_type}" \
    --network=default \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=10GB \
    --no-address \
    --quiet
}

for zone in "${ZONES[@]}"; do
  for machine_type in "${MACHINE_TYPES[@]}"; do
    echo "Probing on-demand capacity: zone=${zone} machine-type=${machine_type}"
    PROBE_RC=0
    PROBE_OUTPUT="$(probe_zone_and_type "${zone}" "${machine_type}" 2>&1)" || PROBE_RC=$?
    if [[ "${PROBE_RC}" -eq 0 ]]; then
      echo "Capacity available: zone=${zone} machine-type=${machine_type}"
      echo "${zone}" > "${SHARED_DIR}/gcp-zone"
      echo "${machine_type}" > "${SHARED_DIR}/gcp-machine-type"
      # Success path: the VM can only be in ${zone}, so a single targeted
      # delete is enough — the all-zone sweep stays trap-only (failure paths).
      gcloud compute instances delete "${PROBE_VM_NAME}" \
        --project="${HC_PROJECT_ID}" \
        --zone="${zone}" \
        --quiet || true
      trap - EXIT
      echo "Probe complete: create chain will use zone=${zone} machine-type=${machine_type}"
      exit 0
    fi
    if is_capacity_error "${PROBE_OUTPUT}"; then
      echo "No capacity: zone=${zone} machine-type=${machine_type}"
      continue
    fi
    echo "ERROR: GCP_CAPACITY_PROBE_UNEXPECTED_ERROR: probe create failed for a non-capacity reason (zone=${zone} machine-type=${machine_type} exit=${PROBE_RC}) — refusing to misreport this as a stockout:"
    echo "${PROBE_OUTPUT}"
    exit 1
  done
done

# Fail fast with a greppable message so the job fails in minutes instead of
# hanging ~45m in cluster rollout (and being misclassified by Sippy as a test
# failure rather than infrastructure capacity exhaustion).
echo "GCP_NO_CAPACITY_IN_REGION: no on-demand capacity for machine types [${MACHINE_TYPES[*]}] in any zone of region ${GCP_REGION} (zones probed: ${ZONES[*]})"
exit 1
