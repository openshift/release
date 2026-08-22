#!/usr/bin/env bash

echo "Current PWD: $(pwd)"
ls -lah
echo "Current Git branch:"
git branch --show-current

echo "Latest Git commits:"
git log --oneline -5
echo "Git status:"
git status
# Resolve the newest 40-char SHA tag of a Quay repo via the Quay tag API.
# Reads push timestamps (start_ts) in bulk instead of running `skopeo inspect`
# per tag, which does not scale with the number of accumulated CI build tags.
# Prints "<repo>:<sha>" for the newest tag, or nothing if none is found.
resolve_latest_image() {
  local repo=$1
  local api_repo="${repo#quay.io/}"
  local page=1 resp attempt latest=""
  # Quay returns tags newest-first, so page 1 normally already holds the newest
  # SHA-form tag; keep paging only while Quay reports additional pages.
  while :; do
    resp=""
    for attempt in 1 2 3; do
      if resp=$(wget -q -O - --tries=1 --timeout=30 \
          "https://quay.io/api/v1/repository/${api_repo}/tag/?onlyActiveTags=true&limit=100&page=${page}"); then
        break
      fi
      echo "WARN: Quay tag API call failed for ${api_repo} (page ${page}, attempt ${attempt}); retrying..." >&2
      resp=""
      sleep $((attempt * 3))
    done
    [ -n "$resp" ] || { echo "ERROR: Quay tag API unreachable for ${api_repo} after retries" >&2; return 1; }
    latest=$(echo "$resp" | jq -r '
      [.tags[]? | select(.name | test("^[a-f0-9]{40}$"))]
      | sort_by(.start_ts) | reverse | .[0].name // empty')
    [ -n "$latest" ] && break
    [ "$(echo "$resp" | jq -r '.has_additional')" = "true" ] || break
    page=$((page + 1))
    if [ "$page" -gt 100 ]; then
      echo "ERROR: no SHA-form tag found for ${api_repo} within ${page} pages" >&2
      return 1
    fi
  done
  if [ -z "$latest" ]; then
    echo "ERROR: no SHA-form tag found for ${api_repo}" >&2
    return 1
  fi
  echo "${repo}:${latest}"
}

REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-bundle-dev-main"
BUNDLE_IMAGE=$(resolve_latest_image "$REPO")

if [[ -z "$BUNDLE_IMAGE" ]]; then
  echo "ERROR: Failed to resolve BUNDLE_IMAGE from $REPO"
  exit 1
fi

echo "Resolved BUNDLE_IMAGE: ${BUNDLE_IMAGE}"
echo "export BUNDLE_IMAGE=${BUNDLE_IMAGE}" >> "${SHARED_DIR}/env"

oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite
