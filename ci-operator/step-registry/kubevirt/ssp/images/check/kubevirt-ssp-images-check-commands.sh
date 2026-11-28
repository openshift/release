#!/bin/bash
set +x
set -euo pipefail
umask 077
# 1. CI supplies the two images built from the SSP revision under test. This
# step runs before provisioning, so bad images stop us before a cluster rebuild.
: "${SHARED_DIR:?}" "${CI_OPERATOR_IMG:?}" "${CI_VALIDATOR_IMG:?}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# CI labels its index with the builder architecture (amd64), even for cross
# builds. Inspect the actual member config, not that label, and deploy only the
# checked single-image digest. Never pass the mislabeled index to the cluster.
check_image() {
  local pullspec=$1 digest
  oc image info "$pullspec" --filter-by-os='.*' --show-multiarch -o json > "$tmp/info.json"
  # oc emits an object for one result, an array for several. These builds must
  # produce exactly one member; reject unexpected mixed/ambiguous outputs.
  jq 'if type == "array" then . else [.] end' "$tmp/info.json" > "$tmp/members.json"
  if ! jq -e 'length == 1' "$tmp/members.json" >/dev/null; then
    echo 'Expected exactly one image member' >&2
    return 1
  fi
  jq '.[0]' "$tmp/members.json" > "$tmp/image.json"
  jq -e '.config.os == "linux" and .config.architecture == "s390x"' "$tmp/image.json" >/dev/null || {
    echo 'Expected a linux/s390x image' >&2; return 1;
  }
  digest=$(jq -er '.digest | select(test("^sha256:[a-f0-9]{64}$"))' "$tmp/image.json")
  # CI dependency pullspecs have a tag or digest, with the repository after /.
  pullspec=${pullspec%@*}
  if [[ ${pullspec##*/} == *:* ]]; then pullspec=${pullspec%:*}; fi
  printf '%s@%s' "$pullspec" "$digest"
}
# 2. Check both images, then share their immutable digests with the test step.
# A digest fixes the image contents even if a registry tag changes later.
operator=$(check_image "$CI_OPERATOR_IMG")
validator=$(check_image "$CI_VALIDATOR_IMG")
jq -n --arg operator "$operator" --arg validator "$validator" \
  '{operator:$operator,validator:$validator}' > "${SHARED_DIR}/ssp-images.json"
echo 'Validated linux/s390x SSP images and pinned their digests'
