#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Save an exit code for the junit generated in gather-must-gather: pre-config steps
# report 100 on failure, 0 on success (see other ipi/*-pre steps). We also clean up any
# credential uploaded to the bastion. A single EXIT/TERM handler does both.
EXIT_CODE=100
REMOTE_CLEANUP_CMD=""
function on_exit() {
  local rc=$?
  if [[ "${rc}" == "0" ]]; then EXIT_CODE=0; fi
  echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
  if [[ -n "${REMOTE_CLEANUP_CMD}" ]]; then eval "${REMOTE_CLEANUP_CMD}" >/dev/null 2>&1 || true; fi
}
trap on_exit EXIT TERM

# No-op unless the caller asked for custom images. This keeps the step safe to place in
# shared disconnected chains.
if [[ -z "${MIRROR_CUSTOM_IMAGES:-}" ]]; then
  echo "MIRROR_CUSTOM_IMAGES is empty; nothing to mirror. Skipping."
  exit 0
fi

if [[ "${CUSTOM_MIRROR_APPLY_MODE}" != "manifest" ]]; then
  echo "ERROR: CUSTOM_MIRROR_APPLY_MODE='${CUSTOM_MIRROR_APPLY_MODE}' is not supported yet; only 'manifest' is implemented." >&2
  exit 1
fi

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}"

if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
  echo "ERROR: ${SHARED_DIR}/mirror_registry_url not found. This step requires a disconnected job with a bastion mirror registry." >&2
  exit 1
fi
MIRROR_REGISTRY_HOST="$(head -n 1 "${SHARED_DIR}/mirror_registry_url")"
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

# ci-operator points KUBECONFIG at the cluster under test once it exists; unset it so every
# oc call here talks to the build farm (which hosts the pipeline imagestream).
unset KUBECONFIG

work="$(mktemp -d)"
authfile="${work}/auth.json"

# Build a combined auth file: cluster pull-secret + custom mirror-registry credential +
# build-farm registry credentials (for pulling pipeline images). We never enable `set -x`,
# so credentials are not traced into the CI logs.
registry_cred="$(head -n 1 /var/run/vault/mirror-registry/registry_creds | base64 -w 0)"
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"${registry_cred}\"}}" \
   '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${authfile}"
oc registry login --to "${authfile}"
chmod 600 "${authfile}"

# Public repository of this job's pipeline imagestream. ci-operator resolves pipeline
# dependencies to "<this repo>@<digest>", so deriving the redirect source from the same
# value guarantees it matches the pullspec the workload actually deploys.
pipeline_repo=""
if oc get imagestream pipeline -n "${NAMESPACE}" >/dev/null 2>&1; then
  pipeline_repo="$(oc get imagestream pipeline -n "${NAMESPACE}" -o jsonpath='{.status.publicDockerImageRepository}')"
fi
echo "pipeline imagestream repo: ${pipeline_repo:-<none>}"

# Wait (bounded) for a pipeline tag to be built, then echo "<repo>@<digest>". ci-operator
# does not gate this pre-step on image builds, so some step in the workflow must declare the
# tag as a dependency (the consumer e2e ref does); this only covers the case where the build
# is still in flight when the pre-phase reaches us. istag has no watch verb, so we poll.
function resolve_pipeline_tag() {
  local tag="$1" deadline=$(( SECONDS + 900 )) digest=""
  while true; do
    if oc get istag "pipeline:${tag}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      digest="$(oc get istag "pipeline:${tag}" -n "${NAMESPACE}" -o jsonpath='{.image.metadata.name}')"
      [[ -n "${digest}" ]] && break
    fi
    if oc get builds -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -qx 'Failed'; then
      echo "ERROR: a pipeline Build reports phase=Failed while waiting for pipeline:${tag}." >&2
      return 1
    fi
    if (( SECONDS >= deadline )); then
      echo "ERROR: timed out (15m) waiting for pipeline:${tag} to be built." >&2
      return 1
    fi
    echo "waiting for pipeline:${tag} to be built..." >&2
    sleep 15
  done
  if [[ -z "${pipeline_repo}" ]]; then
    echo "ERROR: pipeline imagestream public repository could not be resolved in namespace ${NAMESPACE}." >&2
    return 1
  fi
  echo "${pipeline_repo}@${digest}"
}

function retry() {
  local n=0 max="$1"; shift
  until "$@"; do
    n=$(( n + 1 ))
    if (( n >= max )); then return 1; fi
    echo "attempt ${n}/${max} failed; retrying in 30s..." >&2
    sleep 30
  done
}

# SSH helpers for the bastion. ssh_opts intentionally word-splits.
function bssh() {
  # shellcheck disable=SC2086,SC2029
  ssh ${ssh_opts} "${bastion_user}@${bastion_ip}" "$@"
}
function bscp() {
  # shellcheck disable=SC2086
  scp ${ssh_opts} "$1" "${bastion_user}@${bastion_ip}:$2"
}

# Resolve every token into a mirror pair (SRC=DEST) and a redirect (source repo -> mirror repo).
mirror_pairs=()                # lines "SRC=DEST" for `oc image mirror`
verify_targets=()              # destination pullspecs to confirm landed
declare -A digest_mirrors=()   # source_repo -> mirror_repo   (digest references)
declare -A tag_mirrors=()      # source_repo -> mirror_repo   (tag references)

IFS=',' read -ra _tokens <<< "${MIRROR_CUSTOM_IMAGES}"
for _raw in "${_tokens[@]}"; do
  tok="${_raw//[[:space:]]/}"
  [[ -z "${tok}" ]] && continue
  if [[ "${tok}" == *"/"* ]]; then
    src="${tok}"                                   # external pullspec, used verbatim
  else
    src="$(resolve_pipeline_tag "${tok}")"         # pipeline tag -> repo@digest
  fi
  echo "resolved '${tok}' -> ${src}"
  src_repo="${src%@*}"; src_repo="${src_repo%:*}"  # strip @digest or :tag
  repo_path="${src_repo#*/}"                       # drop registry host, keep repo path
  dest_repo="${MIRROR_REGISTRY_HOST}/${repo_path}"
  if [[ "${src}" == *"@sha256:"* ]]; then
    digest="${src##*@}"
    mirror_pairs+=("${src}=${dest_repo}")          # push by digest (bare destination repo)
    verify_targets+=("${dest_repo}@${digest}")
    digest_mirrors["${src_repo}"]="${dest_repo}"
  else
    tag="${src##*:}"; [[ "${tag}" == "${src}" ]] && tag="latest"
    mirror_pairs+=("${src}=${dest_repo}:${tag}")   # preserve the tag
    verify_targets+=("${dest_repo}:${tag}")
    tag_mirrors["${src_repo}"]="${dest_repo}"
  fi
done

if [[ ${#mirror_pairs[@]} -eq 0 ]]; then
  echo "No images resolved to mirror."
  exit 0
fi

# Detect and match the redirect family established by the release-payload mirror. A cluster
# cannot run ImageContentSourcePolicy together with ImageDigestMirrorSet/ImageTagMirrorSet.
patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
family="icsp"
if [[ -f "${patch}" ]] && grep -q '^imageDigestSources:' "${patch}"; then
  family="idms"
elif [[ -f "${patch}" ]] && grep -q '^imageContentSources:' "${patch}"; then
  family="icsp"
fi
echo "redirect family (matched to payload mirror): ${family}"

if [[ "${family}" == "icsp" && ${#tag_mirrors[@]} -gt 0 ]]; then
  echo "ERROR: tag-referenced sources require the IDMS/ITMS family, but the payload mirror uses ICSP." >&2
  echo "       Set ENABLE_IDMS=yes at the chain level so both the payload and this step use IDMS/ITMS." >&2
  echo "       Offending sources: ${!tag_mirrors[*]}" >&2
  exit 1
fi

mirror_list="${work}/mirror-list.txt"
printf '%s\n' "${mirror_pairs[@]}" > "${mirror_list}"
echo "Images to mirror (SRC=DEST):"
cat "${mirror_list}"

# --- perform the mirror, on the bastion over SSH or directly from the build farm ---
if [[ "${MIRROR_IN_BASTION}" == "yes" ]]; then
  # A random UID must exist in /etc/passwd to be able to SSH.
  if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
      echo "ERROR: /etc/passwd is not writeable and no user matches this uid." >&2
      exit 1
    fi
  fi
  ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  bastion_ip="$(<"${SHARED_DIR}/bastion_private_address")"
  if [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
    bastion_ip="$(<"${SHARED_DIR}/bastion_public_address")"
  fi
  bastion_user="$(<"${SHARED_DIR}/bastion_ssh_user")"
  ssh_opts="-o UserKnownHostsFile=/dev/null -o IdentityFile=${ssh_key} -o StrictHostKeyChecking=no"
  remote_auth="/tmp/mirror-images-custom-auth.json"
  remote_oc="/tmp/oc"

  oc_bin="oc"
  if bssh "which oc && oc version --client" >/dev/null 2>&1; then
    echo "using oc already installed on the bastion"
  elif bssh "test -x ${remote_oc}"; then
    oc_bin="${remote_oc}"
  else
    echo "copying oc to the bastion"
    bscp "$(command -v oc)" "${remote_oc}"
    oc_bin="${remote_oc}"
  fi

  bscp "${authfile}" "${remote_auth}"
  # Remove the uploaded credential when the step ends.
  REMOTE_CLEANUP_CMD="bssh 'rm -f ${remote_auth}'"

  mirror_flags="--insecure=true"
  if bssh "${oc_bin} image mirror --help 2>&1 | grep -q -- --keep-manifest-list"; then
    mirror_flags="${mirror_flags} --keep-manifest-list=true"
  fi
  # Mirror one image per invocation: several images (e.g. handler + operator) share the
  # same destination repo (.../pipeline), which `oc image mirror` refuses to accept in a
  # single mapping set ("each destination tag may only be specified once").
  for pair in "${mirror_pairs[@]}"; do
    echo "mirroring (bastion): ${pair}"
    retry 3 bssh "${oc_bin} image mirror ${mirror_flags} --registry-config=${remote_auth} ${pair}"
  done

  echo "verifying mirrored images exist in the bastion registry"
  for t in "${verify_targets[@]}"; do
    retry 3 bssh "${oc_bin} image info --insecure=true -a ${remote_auth} ${t} >/dev/null" \
      || { echo "ERROR: mirrored image not found in registry: ${t}" >&2; exit 1; }
    echo "  ok: ${t}"
  done
else
  mirror_flags=(--insecure=true)
  if oc image mirror --help 2>&1 | grep -q -- --keep-manifest-list; then
    mirror_flags+=(--keep-manifest-list=true)
  fi
  # Mirror one image per invocation (see the note in the bastion branch above).
  for pair in "${mirror_pairs[@]}"; do
    echo "mirroring: ${pair}"
    retry 3 oc image mirror "${mirror_flags[@]}" "--registry-config=${authfile}" "${pair}"
  done

  echo "verifying mirrored images exist in the bastion registry"
  for t in "${verify_targets[@]}"; do
    retry 3 oc image info --insecure=true -a "${authfile}" "${t}" >/dev/null \
      || { echo "ERROR: mirrored image not found in registry: ${t}" >&2; exit 1; }
    echo "  ok: ${t}"
  done
fi

# --- emit the redirect as day-1 install manifests (matched family) ---
function digest_mirror_entries() {
  local src
  for src in "${!digest_mirrors[@]}"; do
    printf '  - mirrors:\n    - %s\n    source: %s\n' "${digest_mirrors[$src]}" "${src}"
    if [[ "${1:-}" == "idms" ]]; then
      printf '    mirrorSourcePolicy: NeverContactSource\n'
    fi
  done
  return 0
}

if [[ "${family}" == "idms" ]]; then
  if [[ ${#digest_mirrors[@]} -gt 0 ]]; then
    {
      echo "apiVersion: config.openshift.io/v1"
      echo "kind: ImageDigestMirrorSet"
      echo "metadata:"
      echo "  name: mirror-images-custom"
      echo "spec:"
      echo "  imageDigestMirrors:"
      digest_mirror_entries idms
    } > "${SHARED_DIR}/manifest_mirror-images-custom-idms.yaml"
    echo "wrote IDMS manifest:"; cat "${SHARED_DIR}/manifest_mirror-images-custom-idms.yaml"
  fi
  if [[ ${#tag_mirrors[@]} -gt 0 ]]; then
    {
      echo "apiVersion: config.openshift.io/v1"
      echo "kind: ImageTagMirrorSet"
      echo "metadata:"
      echo "  name: mirror-images-custom"
      echo "spec:"
      echo "  imageTagMirrors:"
      for src in "${!tag_mirrors[@]}"; do
        printf '  - mirrors:\n    - %s\n    source: %s\n    mirrorSourcePolicy: NeverContactSource\n' "${tag_mirrors[$src]}" "${src}"
      done
    } > "${SHARED_DIR}/manifest_mirror-images-custom-itms.yaml"
    echo "wrote ITMS manifest:"; cat "${SHARED_DIR}/manifest_mirror-images-custom-itms.yaml"
  fi
else
  {
    echo "apiVersion: operator.openshift.io/v1alpha1"
    echo "kind: ImageContentSourcePolicy"
    echo "metadata:"
    echo "  name: mirror-images-custom"
    echo "spec:"
    echo "  repositoryDigestMirrors:"
    digest_mirror_entries icsp
  } > "${SHARED_DIR}/manifest_mirror-images-custom-icsp.yaml"
  echo "wrote ICSP manifest:"; cat "${SHARED_DIR}/manifest_mirror-images-custom-icsp.yaml"
fi

echo "mirror-images-custom completed successfully."
