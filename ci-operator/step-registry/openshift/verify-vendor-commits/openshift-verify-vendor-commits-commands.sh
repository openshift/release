#!/bin/bash

set -euo pipefail

if [ -z "${PULL_BASE_SHA:-}" ]; then
    echo "ERROR: PULL_BASE_SHA is not set; this check must run in a PR context."
    exit 1
fi

echo "=== Vendor Commit Structure Check ==="
echo "Checking commits from ${PULL_BASE_SHA} to HEAD"

FAILED=0

while IFS= read -r sha; do
    subject=$(git log -1 --format='%s' "${sha}")

    mapfile -t all_files < <(git diff-tree -m --no-commit-id -r --name-only "${sha}")

    vendor_files=()
    non_vendor_files=()
    for f in "${all_files[@]}"; do
        if [[ "${f}" =~ (^|/)vendor/ ]]; then
            vendor_files+=("${f}")
        else
            non_vendor_files+=("${f}")
        fi
    done

    if [[ ${#vendor_files[@]} -eq 0 ]]; then
        continue
    fi

    if [[ ${#non_vendor_files[@]} -gt 0 ]]; then
        echo ""
        echo "ERROR: Commit ${sha} \"${subject}\" mixes vendor/ files with non-vendor files."
        echo ""
        echo "  Vendor files:     ${vendor_files[*]}"
        echo "  Non-vendor files: ${non_vendor_files[*]}"
        echo ""
        echo "  This causes rebase conflicts when rebasebot cherry-picks the commit onto"
        echo "  a new upstream (which has independently updated vendor/)."
        echo ""
        echo "  Fix: split into two commits:"
        echo "    1. UPSTREAM: <pr_number>: <description>   <- go.mod, go.sum only"
        echo "    2. UPSTREAM: <drop>: vendor               <- vendor/ only"
        echo ""
        echo "  Rebasebot regenerates vendor/ as the last commit after every rebase."
        echo "  The vendor commit is therefore always dropped and recreated — it must"
        echo "  never be carried forward."
        FAILED=1
        continue
    fi

    if ! echo "${subject}" | grep -qP '^UPSTREAM: <drop>:'; then
        echo ""
        echo "ERROR: Commit ${sha} \"${subject}\" touches only vendor/ files but is not"
        echo "       tagged UPSTREAM: <drop>:"
        echo ""
        echo "  Fix: change the commit message prefix to:"
        echo "    UPSTREAM: <drop>: <description>"
        echo ""
        echo "  Rebasebot skips UPSTREAM: <drop>: commits during cherry-pick and"
        echo "  regenerates vendor/ fresh after the rebase completes."
        FAILED=1
    fi
done < <(git log --format='%H' "${PULL_BASE_SHA}..HEAD")

if [[ ${FAILED} -ne 0 ]]; then
    exit 1
fi

echo "All commits passed vendor structure check."
