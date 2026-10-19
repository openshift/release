#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars
cp "${SHARED_DIR}/seed-all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/seed-bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp "${SHARED_DIR}/seed-bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

mirror_seed() {
  cd /eco-ci-cd
  local budget limit=()
  if [[ "${IBI_MIRROR_SEED_DEPENDENCIES:-false}" == true ]]; then
    budget=$(remaining_budget)
    limit=(timeout --kill-after=10s "${budget}s")
  fi
  "${limit[@]}" ansible-playbook playbooks/ran/ibu-mirror-seed-image.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "version=${VERSION} target_registry_host=${TARGET_REGISTRY_HOST}"
}

# Ordinary IBU jobs retain the existing playbook and behavior.
case "${IBI_MIRROR_SEED_DEPENDENCIES:-false}" in
  false) mirror_seed; exit 0 ;;
  true) ;;
  *) echo "IBI_MIRROR_SEED_DEPENDENCIES must be true or false." >&2; exit 1 ;;
esac

# Disable tracing before accessing inventory credentials.
set +x
set -u
umask 077
# Reserve five minutes of the existing 60-minute step for reports and cleanup.
IBI_MIRROR_STARTED=$SECONDS
remaining_budget() {
  local remaining=$((3300 - SECONDS + IBI_MIRROR_STARTED))
  if (( remaining <= 0 )); then
    echo "IBI mirror execution budget exhausted; collecting reports." >&2
    return 1
  fi
  printf '%s\n' "$remaining"
}
# Remove stale handoffs even when input validation fails.
rm -f -- "${SHARED_DIR}/ibi-seed-digest" "${SHARED_DIR}/ibi-seed-git-revision"
: "${CLUSTER_NAME:?Seed hub name is required}"
: "${TARGET_CLUSTER_NAME:?Target hub name is required}"
: "${MIRROR_REGISTRY:?Registry is required}"
: "${ZTP_GIT_REPO:?ZTP repository is required}"
: "${ZTP_GIT_BRANCH:?ZTP branch is required}"
: "${TARGET_SPOKE_CLUSTER:?Target spoke name is required}"
[[ "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ && "$TARGET_CLUSTER_NAME" =~ ^[a-z0-9-]+$ ]]
[[ "$MIRROR_REGISTRY" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]
[[ "$TARGET_REGISTRY_HOST" =~ ^[a-zA-Z0-9.-]+$ ]]
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]
SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
[[ "$SEED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ && "$SEED_VERSION" == "$VERSION".* ]]
test -s "${SHARED_DIR}/ibi-seed-catalogs.json"
TARGET_SPOKE_NAME=$(printf '%s' "$TARGET_SPOKE_CLUSTER" | tr -d "[]'\" ")
[[ "$TARGET_SPOKE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]

TEMP_DIR=$(mktemp -d /tmp/ibi-seed-mirror.XXXXXX)
REPORT_DIR="${ARTIFACT_DIR}/ibi-seed-mirror"
mkdir -p "$REPORT_DIR"
SEED_DIR=
TARGET_DIR=
SEED_BASTION=
TARGET_BASTION=
SSH_OPTS=()

redact_bastions() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$SEED_BASTION" ]] || line="${line//${SEED_BASTION}/<seed-bastion>}"
    [[ -z "$TARGET_BASTION" ]] || line="${line//${TARGET_BASTION}/<target-bastion>}"
    [[ -z "${SEED_IP:-}" ]] || line="${line//${SEED_IP}/<seed-bastion>}"
    [[ -z "${TARGET_IP:-}" ]] || line="${line//${TARGET_IP}/<target-bastion>}"
    printf '%s\n' "$line"
  done
}

finish() {
  local rc=$? copy_rc=0
  trap - EXIT
  set +e
  if [[ "$SEED_DIR" =~ ^/tmp/ibi-seed-mirror\.[a-zA-Z0-9]+$ ]]; then
    scp -q -r "${SSH_OPTS[@]}" "$SEED_BASTION:$SEED_DIR/report" "$REPORT_DIR/seed" \
      2>&1 | redact_bastions
    (( ${PIPESTATUS[0]} == 0 )) || copy_rc=1
    ssh "${SSH_OPTS[@]}" "$SEED_BASTION" "rm -rf -- '$SEED_DIR'" 2>&1 | redact_bastions
    (( ${PIPESTATUS[0]} == 0 )) || copy_rc=1
  fi
  if [[ "$TARGET_DIR" =~ ^/tmp/ibi-seed-mirror\.[a-zA-Z0-9]+$ ]]; then
    scp -q -r "${SSH_OPTS[@]}" "$TARGET_BASTION:$TARGET_DIR/report" "$REPORT_DIR/target" \
      2>&1 | redact_bastions
    (( ${PIPESTATUS[0]} == 0 )) || copy_rc=1
    ssh "${SSH_OPTS[@]}" "$TARGET_BASTION" "rm -rf -- '$TARGET_DIR'" 2>&1 | redact_bastions
    (( ${PIPESTATUS[0]} == 0 )) || copy_rc=1
  fi
  rm -rf -- "$TEMP_DIR"
  (( rc != 0 )) || rc=$copy_rc
  if (( rc != 0 )); then
    rm -f -- "${SHARED_DIR}/ibi-seed-digest" "${SHARED_DIR}/ibi-seed-git-revision"
    echo "IBI image transfer/validation failed; target preinstall is blocked." >&2
  fi
  exit "$rc"
}
trap finish EXIT

cp /var/group_variables/common/all/ansible_ssh_private_key "$TEMP_DIR/ssh-key"
chmod 600 "$TEMP_DIR/ssh-key"
SSH_OPTS=(-i "$TEMP_DIR/ssh-key" -o BatchMode=yes -o ConnectTimeout=30
          -o ServerAliveInterval=30 -o ServerAliveCountMax=6
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SEED_IP=$(grep -oP '(?<=ansible_host: ).*' "${SHARED_DIR}/seed-bastion" | tr -d "'")
TARGET_IP=$(grep -oP '(?<=ansible_host: ).*' "${SHARED_DIR}/target-bastion" | tr -d "'")
SEED_USER=$(grep -oP '(?<=ansible_user: ).*' "${SHARED_DIR}/seed-all" | tr -d "'")
TARGET_USER=$(grep -oP '(?<=ansible_user: ).*' "${SHARED_DIR}/target-all" | tr -d "'")
[[ "$SEED_IP" =~ ^[a-zA-Z0-9.-]+$ && "$TARGET_IP" =~ ^[a-zA-Z0-9.-]+$ ]]
[[ "$SEED_USER" =~ ^[a-zA-Z0-9_-]+$ && "$TARGET_USER" =~ ^[a-zA-Z0-9_-]+$ ]]
SEED_BASTION="$SEED_USER@$SEED_IP"
TARGET_BASTION="$TARGET_USER@$TARGET_IP"
SEED_KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
TARGET_KUBECONFIG="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"

# Resolve the Git branch once; preinstall will consume this same revision.
GIT_REVISION=$(git ls-remote --exit-code "$ZTP_GIT_REPO" "refs/heads/$ZTP_GIT_BRANCH" | awk '{print $1}')
[[ "$GIT_REVISION" =~ ^[a-f0-9]{40}$ ]]
curl --fail --silent --show-error --retry 2 --connect-timeout 30 --max-time 120 \
  "${ZTP_GIT_REPO%.git}/-/raw/${GIT_REVISION}/${VERSION}/${TARGET_SPOKE_NAME}/clusterinstance/preinstall-test/image-based-installation-config.yaml" \
  > "$TEMP_DIR/template.yaml"
cp "${SHARED_DIR}/ibi-seed-catalogs.json" "$TEMP_DIR/catalogs.json"
python3 - "$MIRROR_REGISTRY" "$TARGET_REGISTRY_HOST" "$VERSION" "$SEED_VERSION" "$GIT_REVISION" \
  > "$TEMP_DIR/config.json" <<'PY'
import json, sys
registry, target, tag, version, revision = sys.argv[1:]
print(json.dumps({"registry": registry, "endpoint": target + ":" + registry.rsplit(":", 1)[1],
                  "tag": tag, "version": version, "git_revision": revision}))
PY

cat > "$TEMP_DIR/images.py" <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

# This file is generated by the Prow shell step, not installed in eco-ci-cd.
os.umask(0o077)
mode, directory, kubeconfig, budget = sys.argv[1:]
work = Path(directory)
config = json.loads((work / "config.json").read_text())
registry = config["registry"]
endpoint = config["endpoint"]
started = time.monotonic()
deadline = started + int(budget)
(work / "report").mkdir(exist_ok=True)
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
REFERENCE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9./_:@-]*")


def run(args, operation, timeout=600):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("Mirror execution budget exhausted before " + operation)
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=min(timeout, remaining), check=False, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise RuntimeError(operation + " timed out") from None
    if result.returncode:
        # Registry/oc stderr can include credentials or cluster URLs.
        raise RuntimeError(operation + " failed (exit " + str(result.returncode) + ")")
    return result.stdout


def write(name, value):
    path = work / name
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)
    if name in {"plan.json", "copy-results.json", "verify-results.json", "verified.json", "failure.json"}:
        (work / "report" / name).write_text(path.read_text())


def oc(*args):
    return json.loads(run(["oc", "--kubeconfig", kubeconfig, "--request-timeout=60s",
                           *args, "-o", "json"], "Read hub configuration", 90))


def sha(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def split(ref):
    if not REFERENCE.fullmatch(ref) or "/" not in ref or ".." in ref:
        raise ValueError("Invalid image reference")
    if "@" in ref:
        repo, value = ref.rsplit("@", 1)
        if not DIGEST.fullmatch(value):
            raise ValueError("Only sha256 image digests are supported")
        return repo, value, True
    if ":" not in ref.rsplit("/", 1)[-1]:
        ref += ":latest"
    repo, value = ref.rsplit(":", 1)
    if not value:
        raise ValueError("Empty image tag")
    return repo, value, False


def raw(ref, auth="auth.json"):
    split(ref)
    return run(["skopeo", "inspect", "--raw", "--tls-verify=false",
                "--authfile", str(work / auth), "docker://" + ref], "Read manifest " + ref, 90)


def check(ref, digest, auth="auth.json"):
    if sha(raw(ref, auth)) != digest:
        raise ValueError("Manifest digest mismatch: " + ref)


def copy(source, destination, destination_auth):
    run(["skopeo", "copy", "--all", "--preserve-digests", "--retry-times", "2",
         "--src-authfile", str(work / "auth.json"),
         "--dest-authfile", str(work / destination_auth),
         "--src-tls-verify=false", "--dest-tls-verify=false",
         "docker://" + source, "docker://" + destination], "Copy image " + source, 1800)


def dynamic_mirror(source, idms):
    mirrors = {mirror for item in idms["items"]
               for entry in item.get("spec", {}).get("imageDigestMirrors", [])
               if entry["source"] == source
               for mirror in entry.get("mirrors", []) if mirror.startswith(registry + "/")}
    if len(mirrors) != 1:
        raise ValueError("Expected one local ACM/MCE mirror for " + source)
    return mirrors.pop()


def mappings(template, idms):
    # Parse only imageDigestSources; the rest of this document is a Go template.
    blocks = re.findall(r"^imageDigestSources:\s*\n((?:[ \t].*\n|[ \t]*\n)*)",
                        template + "\n", re.M)
    if len(blocks) != 1:
        raise ValueError("Expected one preinstall imageDigestSources block")
    expressions = {
        '{{ printf "%q" .MCEMirror }}': dynamic_mirror("registry.redhat.io/multicluster-engine", idms),
        '{{ printf "%q" .ACMMirror }}': dynamic_mirror("registry.redhat.io/rhacm2", idms),
    }
    result, source, waiting = {}, None, False
    for line in blocks[0].splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("- source: "):
            if source is not None and source not in result:
                raise ValueError("Missing mirror")
            source = line[len("- source: "):].strip()
            if source in result or not REFERENCE.fullmatch(source):
                raise ValueError("Duplicate or invalid mirror source")
            waiting = False
        elif line == "mirrors:" and source is not None:
            waiting = True
        elif line.startswith("- ") and waiting and source not in result:
            value = line[2:].strip()
            match = re.fullmatch(r'{{ printf "%q" \(printf "%s(/[a-zA-Z0-9/_.-]+)" .PreinstallRegistry\) }}', value)
            if match:
                value = registry + match[1]
            elif value in expressions:
                value = expressions[value]
            elif value.startswith('"'):
                value = json.loads(value)
            if not value.startswith(registry + "/") or not REFERENCE.fullmatch(value):
                raise ValueError("Unsupported or non-local preinstall mirror")
            result[source] = value
        else:
            raise ValueError("Unsupported preinstall mirror syntax")
    if not result or source not in result:
        raise ValueError("Incomplete preinstall mirrors")
    return result


def mapped(repo, routes):
    if repo.startswith(registry + "/"):
        return repo
    for source in sorted(routes, key=len, reverse=True):
        if repo == source or repo.startswith(source + "/"):
            return routes[source] + repo[len(source):]
    raise ValueError("Unmapped seed image repository: " + repo)


def prepare():
    secret = oc("-n", "openshift-config", "get", "secret", "pull-secret")
    auths = json.loads(base64.b64decode(secret["data"][".dockerconfigjson"], validate=True))["auths"]
    entry = auths[registry]
    # Export only this registry credential, never the full hub pull secret.
    write("auth.json", {"auths": {registry: entry}})
    write("endpoint-auth.json", {"auths": {endpoint: entry}})
    write("idms.json", oc("get", "imagedigestmirrorsets.config.openshift.io"))


def plan():
    template = (work / "template.yaml").read_text()
    source_routes = mappings(template, json.loads((work / "idms.json").read_text()))
    target_routes = mappings(template, json.loads((work / "target-idms.json").read_text()))
    lock = json.loads((work / "catalogs.json").read_text())
    if lock["registry"] != registry or lock["version"] != config["version"]:
        raise ValueError("Catalog snapshot does not match this seed")
    seed = registry + "/ibu/seed:" + config["tag"]
    seed_digest = sha(raw(seed))
    pinned_seed = registry + "/ibu/seed@" + seed_digest
    metadata = json.loads(run(["skopeo", "inspect", "--no-tags", "--tls-verify=false",
                              "--authfile", str(work / "auth.json"), "docker://" + pinned_seed],
                             "Read seed metadata", 90))
    info = json.loads(metadata.get("Labels", {}).get("com.openshift.lifecycle-agent.seed_cluster_info", "{}"))
    if info.get("seed_cluster_ocp_version") != config["version"]:
        raise ValueError("Seed version does not match the recorded OpenShift version")
    # Retain the seed for later replacement preinstall even if its public tag moves.
    copy(pinned_seed, registry + "/ibu/seed:ibi-" + seed_digest[7:], "auth.json")
    with tempfile.TemporaryDirectory(prefix="inventory-", dir=work) as scratch:
        run(["oc", "image", "extract", pinned_seed, "--registry-config=" + str(work / "auth.json"),
             "--insecure=true", "--path=/containers.list:" + scratch], "Extract seed inventory", 1800)
        refs = list(dict.fromkeys(line.strip() for line in
                    (Path(scratch) / "containers.list").read_text().splitlines() if line.strip()))
    if not refs:
        raise ValueError("Seed inventory is empty")
    (work / "report" / "containers.list").write_text("\n".join(refs) + "\n")
    images = []
    for ref in refs:
        repo, value, immutable = split(ref)
        source_repo, target_repo = mapped(repo, source_routes), mapped(repo, target_routes)
        tag = None
        if not immutable:
            tag = value
            snapshot = lock["catalogs"].get(source_repo + ":" + tag)
            if not snapshot:
                raise ValueError("Inventory tag has no pre-generation catalog snapshot: " + ref)
            value = snapshot
            check(source_repo + ":" + tag, value)
        check(source_repo + "@" + value, value)
        images.append({"reference": ref, "source": source_repo + "@" + value,
                       "target": target_repo + "@" + value, "digest": value, "catalog_tag": tag})
    write("plan.json", {"seed_digest": seed_digest, "version": config["version"],
                       "git_revision": config["git_revision"], "mappings": target_routes,
                       "images": images})
    print("Locked seed inventory: " + str(len(images)) + " images", flush=True)


def transfer():
    plan = json.loads((work / "plan.json").read_text())
    seed_digest = plan["seed_digest"]
    check(endpoint + "/ibu/seed:" + config["tag"], seed_digest, "target-auth.json")
    results = []
    try:
        for index, item in enumerate(plan["images"], 1):
            repo = item["target"].split("@", 1)[0]
            remote_repo = endpoint + repo[len(registry):]
            retention = ":ibi-" + seed_digest[7:19] + "-" + item["digest"][7:]
            copy(item["source"], remote_repo + retention, "target-auth.json")
            check(remote_repo + "@" + item["digest"], item["digest"], "target-auth.json")
            if item["catalog_tag"]:
                check(item["source"].split("@", 1)[0] + ":" + item["catalog_tag"], item["digest"])
                copy(item["source"], remote_repo + ":" + item["catalog_tag"], "target-auth.json")
                check(remote_repo + ":" + item["catalog_tag"], item["digest"], "target-auth.json")
            results.append({"reference": item["reference"], "status": "copied"})
            print("Copied %d/%d images (%ds)" %
                  (index, len(plan["images"]), time.monotonic() - started), flush=True)
        copy(registry + "/ibu/seed@" + seed_digest,
             endpoint + "/ibu/seed:ibi-" + seed_digest[7:], "target-auth.json")
        check(endpoint + "/ibu/seed:" + config["tag"], seed_digest, "target-auth.json")
    finally:
        write("copy-results.json", results)


def verify():
    plan = json.loads((work / "plan.json").read_text())
    current = mappings((work / "template.yaml").read_text(),
                       oc("get", "imagedigestmirrorsets.config.openshift.io"))
    if current != plan["mappings"]:
        raise ValueError("Target preinstall mirror configuration changed")
    check(registry + "/ibu/seed:" + config["tag"], plan["seed_digest"])
    results = []
    try:
        for index, item in enumerate(plan["images"], 1):
            check(item["target"], item["digest"])
            if item["catalog_tag"]:
                check(item["target"].split("@", 1)[0] + ":" + item["catalog_tag"], item["digest"])
            with tempfile.TemporaryDirectory(prefix="image-", dir=work) as scratch:
                run(["skopeo", "--override-os", "linux", "--override-arch", "amd64", "copy",
                     "--retry-times", "2", "--authfile", str(work / "auth.json"),
                     "--src-tls-verify=false", "docker://" + item["target"], "dir:" + scratch],
                    "Pull target blobs for " + item["reference"], 600)
            results.append({"reference": item["reference"], "status": "passed"})
            print("Verified %d/%d images (%ds)" %
                  (index, len(plan["images"]), time.monotonic() - started), flush=True)
    finally:
        write("verify-results.json", results)
    write("verified.json", {"seed_digest": plan["seed_digest"], "version": plan["version"],
                           "git_revision": plan["git_revision"], "images": len(results),
                           "catalogs": sum(item["catalog_tag"] is not None for item in plan["images"])})
    print("All seed dependencies verified on target.", flush=True)


try:
    {"prepare": prepare, "plan": plan, "transfer": transfer, "verify": verify}[mode]()
except (RuntimeError, ValueError, KeyError, OSError) as error:
    write("failure.json", {"mode": mode, "error": str(error)})
    raise SystemExit(str(error)) from None
PY

SEED_DIR=$(ssh "${SSH_OPTS[@]}" "$SEED_BASTION" 'umask 077; mktemp -d /tmp/ibi-seed-mirror.XXXXXX')
[[ "$SEED_DIR" =~ ^/tmp/ibi-seed-mirror\.[a-zA-Z0-9]+$ ]]
TARGET_DIR=$(ssh "${SSH_OPTS[@]}" "$TARGET_BASTION" 'umask 077; mktemp -d /tmp/ibi-seed-mirror.XXXXXX')
[[ "$TARGET_DIR" =~ ^/tmp/ibi-seed-mirror\.[a-zA-Z0-9]+$ ]]

remote() {
  local bastion=$1 directory=$2 kubeconfig=$3 mode=$4
  local budget
  budget=$(remaining_budget)
  ssh "${SSH_OPTS[@]}" "$bastion" \
    "python3 '$directory/images.py' '$mode' '$directory' '$kubeconfig' '$budget'" \
    2>&1 | redact_bastions | tee -a "$REPORT_DIR/$mode.log"
}

scp -q "${SSH_OPTS[@]}" "$TEMP_DIR/"{images.py,config.json,template.yaml,catalogs.json} \
  "$SEED_BASTION:$SEED_DIR/" 2>&1 | redact_bastions
scp -q "${SSH_OPTS[@]}" "$TEMP_DIR/"{images.py,config.json,template.yaml} \
  "$TARGET_BASTION:$TARGET_DIR/" 2>&1 | redact_bastions
remote "$SEED_BASTION" "$SEED_DIR" "$SEED_KUBECONFIG" prepare
remote "$TARGET_BASTION" "$TARGET_DIR" "$TARGET_KUBECONFIG" prepare
scp -q "${SSH_OPTS[@]}" "$TARGET_BASTION:$TARGET_DIR/endpoint-auth.json" "$TEMP_DIR/target-auth.json" \
  2>&1 | redact_bastions
scp -q "${SSH_OPTS[@]}" "$TARGET_BASTION:$TARGET_DIR/idms.json" "$TEMP_DIR/target-idms.json" \
  2>&1 | redact_bastions
scp -q "${SSH_OPTS[@]}" "$TEMP_DIR/"{target-auth.json,target-idms.json} "$SEED_BASTION:$SEED_DIR/" \
  2>&1 | redact_bastions
remote "$SEED_BASTION" "$SEED_DIR" "$SEED_KUBECONFIG" plan

# Use the existing seed-copy playbook unchanged, then check its copied digest.
mirror_seed 2>&1 | redact_bastions | tee "$REPORT_DIR/seed-copy.log"
remote "$SEED_BASTION" "$SEED_DIR" "$SEED_KUBECONFIG" transfer
scp -q "${SSH_OPTS[@]}" "$SEED_BASTION:$SEED_DIR/plan.json" "$TEMP_DIR/plan.json" \
  2>&1 | redact_bastions
scp -q "${SSH_OPTS[@]}" "$TEMP_DIR/plan.json" "$TARGET_BASTION:$TARGET_DIR/plan.json" \
  2>&1 | redact_bastions
remote "$TARGET_BASTION" "$TARGET_DIR" "$TARGET_KUBECONFIG" verify
scp -q "${SSH_OPTS[@]}" "$TARGET_BASTION:$TARGET_DIR/verified.json" "$TEMP_DIR/verified.json" \
  2>&1 | redact_bastions
python3 - "$TEMP_DIR/verified.json" "$SHARED_DIR" "$SEED_VERSION" "$GIT_REVISION" <<'PY'
import json, pathlib, re, sys
report, shared, version, revision = sys.argv[1:]
result = json.loads(pathlib.Path(report).read_text())
assert result["version"] == version and result["git_revision"] == revision
assert result["images"] > 0 and re.fullmatch(r"sha256:[a-f0-9]{64}", result["seed_digest"])
for name, value in (("ibi-seed-digest", result["seed_digest"]), ("ibi-seed-git-revision", revision)):
    pathlib.Path(shared, name).write_text(value + "\n")
PY
echo "IBI seed and dependencies are verified; preinstall may proceed."
