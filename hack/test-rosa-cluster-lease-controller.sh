#!/bin/bash
set -euo pipefail

script="$(dirname "$0")/../ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh"
post_check=$(sed -n '/^    # Restore clusters that recovered from error$/,/^done$/p' "$script")
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

[[ "$post_check" == *'HEALTHY=$((HEALTHY + 1))'* ]]
[[ "$post_check" == *$'\ndone' ]]

log() { :; }
dry_run_guard() { [[ "$DRY_RUN" == true ]]; }
lease_oc() {
    [[ "$1 $2" == 'patch configmap' ]]
    printf '%s\n' "${@: -1}" > "$test_dir/patch.json"
    PATCHES=$((PATCHES + 1))
}

run_case() {
    local status="$1" reason="$2" dry_run="$3" expected_healthy="$4" expected_unhealthy="$5" expected_patches="$6"
    export STATUS="$status" DRY_RUN="$dry_run" LEASE_NAMESPACE=fixture-namespace
    export CM
    CM=$(jq -n --arg reason "$reason" '{metadata:{annotations:{"rosa-cluster-lease/error-reason":$reason}}}')
    REPORT="$test_dir/report"
    : > "$REPORT"
    HEALTHY=0 UNHEALTHY=0 PATCHES=0

    eval $'for CM_NAME in fixture-cluster; do\n'"$post_check"

    if [[ "$HEALTHY $UNHEALTHY $PATCHES" != "$expected_healthy $expected_unhealthy $expected_patches" ]]; then
        printf 'FAIL: status=%s reason=%s dry_run=%s: healthy=%s unhealthy=%s patches=%s; expected %s %s %s\n' \
            "$status" "$reason" "$dry_run" "$HEALTHY" "$UNHEALTHY" "$PATCHES" \
            "$expected_healthy" "$expected_unhealthy" "$expected_patches" >&2
        return 1
    fi
    if [[ "$status" == error && "$reason" == ClusterPackage:* ]]; then
        grep -Fq 'SKIPPED RESTORE: fixture-cluster' "$REPORT"
        if grep -Fq 'RESTORED: fixture-cluster' "$REPORT"; then
            printf 'FAIL: deferred ClusterPackage recovery was reported as restored\n' >&2
            return 1
        fi
    elif [[ "$status" == error ]]; then
        grep -Fxq 'RESTORED: fixture-cluster' "$REPORT"
    else
        [[ ! -s "$REPORT" ]]
    fi
    if [[ "$expected_patches" -gt 0 ]]; then
        jq -e '.metadata.labels["rosa-cluster-lease/status"] == "available" and
            .metadata.annotations["rosa-cluster-lease/error-reason"] == "" and
            .metadata.annotations["rosa-cluster-lease/error-at"] == ""' "$test_dir/patch.json" > /dev/null
    fi
    printf 'PASS: status=%s reason=%s dry_run=%s (%s healthy, %s unhealthy, %s patches)\n' \
        "$status" "$reason" "$dry_run" "$HEALTHY" "$UNHEALTHY" "$PATCHES"
}

for dry_run in false true; do
    expected_patches=0
    if [[ "$dry_run" == false ]]; then expected_patches=1; fi
    run_case error 'ClusterPackage: degraded:cloud-ingress-operator' "$dry_run" 0 1 0
    run_case error 'ClusterPackage: refusing adoption' "$dry_run" 0 1 0
    run_case error 'OCM status: installing' "$dry_run" 1 0 "$expected_patches"
    run_case available '' "$dry_run" 1 0 0
done
