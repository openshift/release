#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ] && { echo "\$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is not filled. Failing."; exit 1; }

if [ "${DISCONNECTED}" == "true" ]; then
  [ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && {
    echo "Proxy conf file is not found. Failing."
    exit 1
  }
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
WORK_DIR="/var/lib/assisted/${CLUSTER_NAME}"

case "${architecture:-amd64}" in
  amd64) CPU_ARCH="x86_64" ;;
  arm64) CPU_ARCH="aarch64" ;;
  *) CPU_ARCH="${architecture}" ;;
esac

RELEASE_VERSION=$(oc adm release info --registry-config "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
[ -n "${RELEASE_VERSION}" ] || { echo "Could not read the release version."; exit 1; }
OPENSHIFT_VERSION=$(echo "${RELEASE_VERSION}" | cut -d. -f1,2)
echo "Release ${RELEASE_VERSION} (${OPENSHIFT_VERSION}, ${CPU_ARCH}) will be the only assisted-service release image."

OS_IMAGES=$(jq -nc \
  --arg openshift_version "${OPENSHIFT_VERSION}" \
  --arg cpu_architecture "${CPU_ARCH}" \
  --arg version "${RELEASE_VERSION}" \
  '[{
    openshift_version: $openshift_version,
    cpu_architecture: $cpu_architecture,
    url: "http://__AUX_IP__:__PORT__/base.iso",
    version: $version,
    type: "disconnected-iso"
  }]')
RELEASE_IMAGES=$(jq -nc \
  --arg openshift_version "${OPENSHIFT_VERSION}" \
  --arg cpu_architecture "${CPU_ARCH}" \
  --arg url "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --arg version "${RELEASE_VERSION}" \
  '[{
    openshift_version: $openshift_version,
    cpu_architecture: $cpu_architecture,
    cpu_architectures: [$cpu_architecture],
    url: $url,
    version: $version,
    default: true
  }]')

ENV_FILE=$(mktemp)
chmod 600 "${ENV_FILE}"
{
  printf 'export CI=true\n'
  printf 'export OPENSHIFT_CI=true\n'
  printf 'export TEST_TEARDOWN=false\n'
  printf 'export DEPLOY_TARGET=%q\n' "${DEPLOY_TARGET:-onprem}"
  printf 'export PULL_SECRET_FILE=%q\n' "${WORK_DIR}/pull-secret"
  printf 'export SERVICE=%q\n' "${SERVICE}"
  printf 'export AGENT_DOCKER_IMAGE=%q\n' "${AGENT_DOCKER_IMAGE}"
  printf 'export CONTROLLER_IMAGE=%q\n' "${CONTROLLER_IMAGE}"
  printf 'export INSTALLER_IMAGE=%q\n' "${INSTALLER_IMAGE}"
  printf 'export IMAGE_SERVICE=%q\n' "${IMAGE_SERVICE}"
  printf 'export PUBLIC_CONTAINER_REGISTRIES=%q\n' "quay.io,registry.ci.openshift.org"
  printf 'export OPENSHIFT_VERSION=%q\n' "${OPENSHIFT_VERSION}"
  printf 'export OPENSHIFT_INSTALL_RELEASE_IMAGE=%q\n' "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  printf 'export OS_IMAGES=%q\n' "${OS_IMAGES}"
  printf 'export RELEASE_IMAGES=%q\n' "${RELEASE_IMAGES}"
  if [ -n "${ASSISTED_CONFIG:-}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [ -z "${line}" ] && continue
      [[ "${line}" == \#* ]] && continue
      if [[ "${line}" != export\ * ]]; then
        line="export ${line}"
      fi
      printf '%s\n' "${line}"
    done <<< "${ASSISTED_CONFIG}"
  fi
} > "${ENV_FILE}"

cleanup_local() {
  rm -f "${ENV_FILE}"
}
trap 'cleanup_local' EXIT

timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" "mkdir -p $(printf '%q' "${WORK_DIR}") && chmod 700 $(printf '%q' "${WORK_DIR}")"
# shellcheck disable=SC2029
scp "${SSHOPTS[@]}" "${ENV_FILE}" "root@${AUX_HOST}:${WORK_DIR}/env.sh"
# shellcheck disable=SC2029
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${AUX_HOST}:${WORK_DIR}/pull-secret"
if [ "${DISCONNECTED}" == "true" ]; then
  # shellcheck disable=SC2029
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/proxy-conf.sh" "root@${AUX_HOST}:${WORK_DIR}/proxy-conf.sh"
fi
secret_files=("${WORK_DIR}/env.sh" "${WORK_DIR}/pull-secret")
if [ "${DISCONNECTED}" == "true" ]; then
  secret_files+=("${WORK_DIR}/proxy-conf.sh")
fi
quoted_files=""
for secret_file in "${secret_files[@]}"; do
  quoted_files+=" $(printf '%q' "${secret_file}")"
done
# shellcheck disable=SC2029
ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" "chmod 600${quoted_files}"

# The ISO storage host is reached through the haproxy network namespace. Serve a copy on the
# aux host so the image service, which runs in podman on the aux host, can fetch the only OS image.
timeout -s 9 170m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "CLUSTER_NAME=$(printf '%q' "${CLUSTER_NAME}") WORK_DIR=$(printf '%q' "${WORK_DIR}") OVE_ISO_STORAGE_HOST=$(printf '%q' "${OVE_ISO_STORAGE_HOST}") ASSISTED_TEST_INFRA_IMAGE=$(printf '%q' "${ASSISTED_TEST_INFRA_IMAGE}") DISCONNECTED=$(printf '%q' "${DISCONNECTED}") bash -s" <<'EOF'
set -o errexit
set -o pipefail
set -o nounset

for cmd in git make podman python3; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "The aux host is missing ${cmd}."; exit 1; }
done

if [ "${DISCONNECTED}" == "true" ]; then
  # shellcheck disable=SC1091
  source "${WORK_DIR}/proxy-conf.sh"
fi

POD_SUFFIX=$(printf '%s' "${CLUSTER_NAME}" | cksum | awk '{print $1}')
ISO_PORT=$((20000 + POD_SUFFIX % 15000))
SERVICE_PORT=$((40000 + POD_SUFFIX % 5000))
IMAGE_PORT=$((SERVICE_PORT + 1))
UI_PORT=$((SERVICE_PORT + 2))
POD_NAME="ai-${POD_SUFFIX}"
CONFIGMAP_NAME="config-${POD_SUFFIX}"
CHOSEN_ISO_PORT="${ISO_PORT}"
CHOSEN_SERVICE_PORT="${SERVICE_PORT}"
CHOSEN_IMAGE_PORT="${IMAGE_PORT}"
CHOSEN_UI_PORT="${UI_PORT}"
CHOSEN_POD_NAME="${POD_NAME}"
CHOSEN_CONFIGMAP_NAME="${CONFIGMAP_NAME}"

mkdir -p "${WORK_DIR}/iso"
CONTAINER_NAME="haproxy-${CLUSTER_NAME}"
echo "Copying the extracted OVE ISO from the storage host."
nsenter -n -t "$(podman inspect -f '{{ .State.Pid }}' "${CONTAINER_NAME}")" \
  ssh -o StrictHostKeyChecking=no root@"${OVE_ISO_STORAGE_HOST}" \
  "cat /var/mnt/data-storage/html/${CLUSTER_NAME}.agent-ove.x86_64.iso" > "${WORK_DIR}/iso/base.iso"
[ -s "${WORK_DIR}/iso/base.iso" ] || { echo "Copied OVE ISO is empty."; exit 1; }

python3 - "${WORK_DIR}" "${ISO_PORT}" <<'PY'
import os, sys
work, port = sys.argv[1], sys.argv[2]
log = open(os.path.join(work, "iso-http.log"), "a")
pid = os.fork()
if pid > 0:
    os.waitpid(pid, 0)
    raise SystemExit(0)
os.setsid()
pid = os.fork()
if pid > 0:
    with open(os.path.join(work, "iso-http.pid"), "w") as fh:
        fh.write(str(pid))
    os._exit(0)
os.chdir(os.path.join(work, "iso"))
os.dup2(log.fileno(), 1)
os.dup2(log.fileno(), 2)
devnull = os.open("/dev/null", os.O_RDONLY)
os.dup2(devnull, 0)
os.execvp("python3", ["python3", "-m", "http.server", port, "--bind", "0.0.0.0"])
PY
python3 - "${ISO_PORT}" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
last = ""
for _ in range(30):
    try:
        s = socket.create_connection(("127.0.0.1", port), 2)
        s.sendall(b"GET /base.iso HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-0\r\nConnection: close\r\n\r\n")
        data = s.recv(80)
        s.close()
        if data.startswith(b"HTTP/1.") and b" 20" in data[:20]:
            raise SystemExit(0)
        last = data.decode("utf-8", "replace")
    except SystemExit:
        raise
    except Exception as exc:
        last = str(exc)
    time.sleep(1)
print("OVE ISO HTTP server did not become ready.", last)
raise SystemExit(1)
PY

AUX_IP=$(ip -4 route get 1 2>/dev/null | sed -n 's/^.*src \([^ ]*\).*$/\1/p' | head -n1)
if [ -z "${AUX_IP}" ]; then
  AUX_IP=$(ip -6 route get ::ffff:100:0 | sed -n 's/^.*src \([^ ]*\).*$/\1/p' | head -n1)
fi
[ -n "${AUX_IP}" ] || { echo "Could not determine the aux host address."; exit 1; }
if [[ "${AUX_IP}" == *:* ]]; then
  AUX_HOST_FOR_URL="[${AUX_IP}]"
else
  AUX_HOST_FOR_URL="${AUX_IP}"
fi
sed -i "s|__AUX_IP__|${AUX_HOST_FOR_URL}|g; s|__PORT__|${ISO_PORT}|g" "${WORK_DIR}/env.sh"
# shellcheck disable=SC1091
source "${WORK_DIR}/env.sh"
ISO_PORT="${CHOSEN_ISO_PORT}"
SERVICE_PORT="${CHOSEN_SERVICE_PORT}"
IMAGE_PORT="${CHOSEN_IMAGE_PORT}"
UI_PORT="${CHOSEN_UI_PORT}"
POD_NAME="${CHOSEN_POD_NAME}"
CONFIGMAP_NAME="${CHOSEN_CONFIGMAP_NAME}"
export SERVICE_PORT IMAGE_PORT UI_PORT POD_NAME CONFIGMAP_NAME ISO_PORT
export SERVICE_PUBLIC_HOST="${AUX_HOST_FOR_URL}"
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}${AUX_IP},127.0.0.1,localhost"
export no_proxy="${NO_PROXY}"
export GIT_TERMINAL_PROMPT=0
case "${OS_IMAGES}" in
  *__AUX_IP__*|*__PORT__*)
    echo "OS image URL was not rewritten for the aux host."
    exit 1
    ;;
esac
printf '%s' "${OS_IMAGES}" | grep -q 'disconnected-iso' || { echo "OS image list is missing the disconnected-iso entry."; exit 1; }

cat > "${WORK_DIR}/runtime.env" <<RUNTIME
POD_NAME=${POD_NAME}
CONFIGMAP_NAME=${CONFIGMAP_NAME}
SERVICE_PORT=${SERVICE_PORT}
IMAGE_PORT=${IMAGE_PORT}
UI_PORT=${UI_PORT}
ISO_PORT=${ISO_PORT}
RUNTIME
chmod 600 "${WORK_DIR}/runtime.env"

echo "Copying assisted-test-infra from ${ASSISTED_TEST_INFRA_IMAGE}."
podman pull "${ASSISTED_TEST_INFRA_IMAGE}"
src_name="assisted-test-infra-src-${POD_SUFFIX}"
podman rm -f "${src_name}" >/dev/null 2>&1 || true
podman create --name "${src_name}" "${ASSISTED_TEST_INFRA_IMAGE}" >/dev/null
src_dir=$(podman inspect --format '{{.Config.WorkingDir}}' "${ASSISTED_TEST_INFRA_IMAGE}")
[ -n "${src_dir}" ] || { echo "assisted-test-infra image has no working directory."; exit 1; }
mkdir -p "${WORK_DIR}/assisted-test-infra"
podman cp "${src_name}:${src_dir}/." "${WORK_DIR}/assisted-test-infra"
podman rm -f "${src_name}" >/dev/null

cat > "${WORK_DIR}/patch_onprem.py" <<'PY'
import os
import pathlib
import re
import sys

def replace_line(text, key, value):
    pattern = rf"^  {re.escape(key)}:.*$"
    repl = "  " + key + ": '" + value + "'"
    new_text, count = re.subn(pattern, repl, text, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"assisted-service configmap is missing {key}")
    return new_text

def prepare(root):
    utils_path = root / "scripts/utils.sh"
    utils = utils_path.read_text()
    old = "function get_namespace_index() {\n    namespace=$1\n"
    new = "function get_namespace_index() {\n    echo 0\n    return\n    namespace=$1\n"
    if old not in utils:
        raise SystemExit("assisted-test-infra get_namespace_index() did not match the expected script.")
    utils_path.write_text(utils.replace(old, new, 1))

    for path in (root / "scripts").glob("*.sh"):
        lines = []
        for line in path.read_text().splitlines(True):
            if line.strip() in {"set -o xtrace", "set -x"}:
                continue
            lines.append(line.replace("set -euxo pipefail", "set -euo pipefail"))
        path.write_text("".join(lines))

    deploy_path = root / "scripts/deploy_assisted_service.sh"
    deploy = deploy_path.read_text()
    needle = "    ROOT_DIR=$(realpath assisted-service/) make -C assisted-service/ deploy-onprem\n"
    inject = '    python3 "${ASSISTED_ONPREM_PATCH}" manifests\n' + needle
    if needle not in deploy:
        raise SystemExit("assisted-test-infra deploy-onprem command did not match the expected script.")
    deploy = deploy.replace(needle, inject, 1)
    jq_line = "HW_VALIDATOR_REQUIREMENTS_LOW_DISK=$(echo $validator_requirements | jq '(.[].worker.disk_size_gb, .[].master.disk_size_gb, .[].sno.disk_size_gb) |= 20' | tr -d \"\\n\\t \")"
    py_line = """HW_VALIDATOR_REQUIREMENTS_LOW_DISK=$(printf '%s' \"$validator_requirements\" | python3 -c 'import json,sys; data=json.load(sys.stdin)
for item in data:
    for role in (\"worker\",\"master\",\"sno\"):
        role_reqs=item.get(role)
        if isinstance(role_reqs, dict):
            role_reqs[\"disk_size_gb\"]=20
print(json.dumps(data, separators=(\",\", \":\")))')"""
    if jq_line not in deploy:
        raise SystemExit("assisted-test-infra disk-size command did not match the expected script.")
    deploy_path.write_text(deploy.replace(jq_line, py_line, 1))

def manifests():
    pod_name = os.environ["POD_NAME"]
    configmap_name = os.environ["CONFIGMAP_NAME"]
    service_port = os.environ["SERVICE_PORT"]
    image_port = os.environ["IMAGE_PORT"]
    ui_port = os.environ["UI_PORT"]
    public_host = os.environ["SERVICE_PUBLIC_HOST"]
    root = pathlib.Path("assisted-service")
    pod_path = root / "deploy/podman/pod.yml"
    pod = pod_path.read_text()
    pod = pod.replace("  name: assisted-installer\n", f"  name: {pod_name}\n", 1)
    pod = pod.replace("        name: config\n", f"        name: {configmap_name}\n")
    pod = pod.replace("    - hostPort: 8080\n", f"    - containerPort: 8080\n      hostPort: {ui_port}\n")
    pod = pod.replace("    - hostPort: 8888\n", f"    - containerPort: 8888\n      hostPort: {image_port}\n")
    pod = pod.replace("    - hostPort: 8090\n", f"    - containerPort: 8090\n      hostPort: {service_port}\n")
    pod_path.write_text(pod)

    cm_path = root / "deploy/podman/configmap.yml"
    cm = cm_path.read_text()
    cm = cm.replace("  name: config\n", f"  name: {configmap_name}\n", 1)
    cm = replace_line(cm, "OS_IMAGES", os.environ["OS_IMAGES"])
    cm = replace_line(cm, "RELEASE_IMAGES", os.environ["RELEASE_IMAGES"])
    cm = replace_line(cm, "ISO_IMAGE_TYPE", "disconnected-iso")
    cm = replace_line(cm, "IMAGE_SERVICE_BASE_URL", f"http://127.0.0.1:{image_port}")
    cm = replace_line(cm, "SERVICE_BASE_URL", f"http://{public_host}:{service_port}")
    cm_path.write_text(cm)

    makefile_path = root / "Makefile"
    makefile = makefile_path.read_text()
    patched = makefile.replace("http://127.0.0.1:8090/ready", f"http://127.0.0.1:{service_port}/ready")
    patched = patched.replace("http://127.0.0.1:8888/health", f"http://127.0.0.1:{image_port}/health")
    if patched == makefile:
        raise SystemExit("assisted-service onprem health checks did not match the expected Makefile.")
    makefile_path.write_text(patched)
    print(f"Prepared onprem pod {pod_name} on service port {service_port}.")

if __name__ == "__main__":
    action = sys.argv[1]
    if action == "prepare":
        prepare(pathlib.Path(sys.argv[2]))
    elif action == "manifests":
        manifests()
    else:
        raise SystemExit(f"unknown patch action {action}")
PY

export ASSISTED_ONPREM_PATCH="${WORK_DIR}/patch_onprem.py"
python3 "${ASSISTED_ONPREM_PATCH}" prepare "${WORK_DIR}/assisted-test-infra"
podman pod rm --force --ignore "${POD_NAME}" >/dev/null 2>&1 || true
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --quiet --add-port="${ISO_PORT}/tcp" || true
  firewall-cmd --quiet --add-port="${SERVICE_PORT}/tcp" || true
  firewall-cmd --quiet --add-port="${IMAGE_PORT}/tcp" || true
fi

cd "${WORK_DIR}/assisted-test-infra"
echo "Deploying assisted-service with make run."
make run

ready=false
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${SERVICE_PORT}/ready" >/dev/null \
    && curl -sf "http://127.0.0.1:${SERVICE_PORT}/api/assisted-install/v2/openshift-versions" >/dev/null; then
    ready=true
    break
  fi
  sleep 10
done
if [ "${ready}" != "true" ]; then
  echo "assisted-service did not become ready on port ${SERVICE_PORT}."
  exit 1
fi

image_container=$(podman ps --filter "pod=${POD_NAME}" --format '{{.Names}}' | grep 'image-service' | head -n1 || true)
if [ -n "${image_container}" ] && podman exec "${image_container}" curl -sf -o /dev/null --max-time 20 -r 0-0 "http://${AUX_HOST_FOR_URL}:${ISO_PORT}/base.iso"; then
  echo "Image service can read the OVE ISO."
else
  echo "Could not confirm that the image service can read the OVE ISO. Discovery generation fails later if it cannot."
fi
echo "http://${AUX_HOST_FOR_URL}:${SERVICE_PORT}" > "${WORK_DIR}/service-url"
EOF

# shellcheck disable=SC2029
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:${WORK_DIR}/service-url" "${SHARED_DIR}/assisted-service-url"
echo "${OPENSHIFT_VERSION}" > "${SHARED_DIR}/assisted-openshift-version"
echo "${RELEASE_VERSION}" > "${SHARED_DIR}/assisted-release-version"
echo "${CPU_ARCH}" > "${SHARED_DIR}/assisted-cpu-arch"
echo "assisted-service is ready at $(<"${SHARED_DIR}/assisted-service-url")"
