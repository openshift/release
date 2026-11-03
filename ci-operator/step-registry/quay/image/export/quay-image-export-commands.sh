#!/bin/bash
set +x
set -euo pipefail
umask 077

fail() {
    printf 'Quay image export: %s\n' "$1" >&2
    exit 1
}

[[ -n "${QUAY_EXPORT_SOURCE:-}" ]] || fail 'QUAY_EXPORT_SOURCE is required'
[[ -n "${QUAY_EXPORT_DESTINATION:-}" ]] || fail 'QUAY_EXPORT_DESTINATION is required'
[[ -n "${QUAY_EXPORT_AUTH_FILE:-}" ]] || fail 'QUAY_EXPORT_AUTH_FILE is required'
[[ -n "${ARTIFACT_DIR:-}" && -d "$ARTIFACT_DIR" ]] || fail 'ARTIFACT_DIR must be an existing directory'
[[ "$QUAY_EXPORT_SOURCE" =~ ^[a-z0-9][a-z0-9.:-]*/[a-z0-9._/-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})$ ]] || fail 'source must be a registry pullspec with a tag or sha256 digest'
[[ "$QUAY_EXPORT_DESTINATION" =~ ^quay\.io/[a-z0-9]+([._-][a-z0-9]+)*/[a-z0-9]+([._-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'destination must be quay.io/organization/repository:tag'
[[ -r "$QUAY_EXPORT_AUTH_FILE" ]] || fail 'destination auth file is not readable'

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq -e '(.auths["quay.io"].auth | type == "string" and length > 0)' \
    "$QUAY_EXPORT_AUTH_FILE" >/dev/null 2>&1 || fail 'destination auth must contain auths["quay.io"].auth'
oc registry login --to="$work_dir/source-auth.json" >/dev/null 2>&1 || fail 'cannot authenticate to the CI build registry'
jq --slurpfile destination "$QUAY_EXPORT_AUTH_FILE" \
    '.auths["quay.io"] = $destination[0].auths["quay.io"] | del(.credsStore, .credHelpers)' \
    "$work_dir/source-auth.json" >"$work_dir/auth.json" 2>/dev/null || fail 'cannot merge registry authentication'

oc image mirror --registry-config="$work_dir/auth.json" --keep-manifest-list \
    "$QUAY_EXPORT_SOURCE" "$QUAY_EXPORT_DESTINATION" >/dev/null 2>&1 || fail 'image mirror failed'
oc image info --registry-config="$work_dir/auth.json" --show-multiarch -o json \
    "$QUAY_EXPORT_DESTINATION" >"$work_dir/image.json" 2>/dev/null || fail 'destination inspection failed'
digest="$(jq -er 'if type == "array" then .[0] else . end | (.listDigest | select(. != null and . != "")) // .digest | select(type == "string")' "$work_dir/image.json" 2>/dev/null)" || fail 'destination inspection returned no digest'
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'destination inspection returned an invalid digest'
jq -n --arg destination "$QUAY_EXPORT_DESTINATION" --arg digest "$digest" \
    '{destination: $destination, digest: $digest, pullspec: (($destination | split(":")[0]) + "@" + $digest)}' \
    >"$ARTIFACT_DIR/quay-image-export.json"
printf 'Exported %s (observed digest %s)\n' "$QUAY_EXPORT_DESTINATION" "$digest"
