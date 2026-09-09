#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

umask 077
work_dir=""
sentinel_namespace=quay-omr-migration-sentinel
namespace_created=false

dump_sentinel_workloads() {
    local pod

    oc -n "${sentinel_namespace}" get daemonset,pods -o wide || true
    oc -n "${sentinel_namespace}" describe daemonset/omr-migration-sentinel || true
    while read -r pod; do
        [[ -n "${pod}" ]] || continue
        oc -n "${sentinel_namespace}" describe "${pod}" || true
        oc -n "${sentinel_namespace}" logs "${pod}" || true
    done < <(oc -n "${sentinel_namespace}" get pods -o name 2>/dev/null || true)
}

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ "${status}" -ne 0 && "${namespace_created}" == true ]]; then
        dump_sentinel_workloads
    fi
    if [[ "${namespace_created}" == true ]]; then
        oc delete namespace "${sentinel_namespace}" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        rm -rf -- "${work_dir}"
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

mkdir -p "${ARTIFACT_DIR}"
exec > >(tee "${ARTIFACT_DIR}/omr-v3-migration-sentinel.log") 2>&1

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

for command in base64 jq oc tar; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the sentinel validation image." >&2
        exit 1
    fi
done

for required_file in \
    "${SHARED_DIR}/mirror_registry_ca.crt" \
    "${SHARED_DIR}/mirror_registry_creds" \
    "${SHARED_DIR}/mirror_registry_url" \
    "${SHARED_DIR}/omr_migration_sentinel_digest" \
    "${SHARED_DIR}/omr_migration_sentinel_image" \
    "${SHARED_DIR}/omr_migration_sentinel_marker" \
    "${SHARED_DIR}/omr_migration_sentinel_tag"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required sentinel validation input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

: "${UNIQUE_HASH:?UNIQUE_HASH is required}"
if [[ ! "${UNIQUE_HASH}" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "UNIQUE_HASH contains unexpected characters." >&2
    exit 1
fi

if ! whoami >/dev/null 2>&1; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and the current UID has no passwd entry." >&2
        exit 1
    fi
fi

registry_host=$(tr -d '\r\n' < "${SHARED_DIR}/mirror_registry_url")
expected_digest=$(tr -d '\r\n' < "${SHARED_DIR}/omr_migration_sentinel_digest")
expected_image=$(tr -d '\r\n' < "${SHARED_DIR}/omr_migration_sentinel_image")
expected_marker=$(tr -d '\r\n' < "${SHARED_DIR}/omr_migration_sentinel_marker")
expected_tag=$(tr -d '\r\n' < "${SHARED_DIR}/omr_migration_sentinel_tag")
expected_repository="${registry_host}/admin/omr-migration-sentinel"
if [[ -z "${registry_host}" || "${registry_host}" == */* ||
      "${registry_host}" =~ [[:space:]] ]]; then
    echo "The runtime OMR endpoint is invalid." >&2
    exit 1
fi
if [[ ! "${expected_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] ||
   [[ "${expected_tag}" != "${expected_repository}:pre-${UNIQUE_HASH}" ]] ||
   [[ "${expected_image}" != "${expected_repository}@${expected_digest}" ]] ||
   [[ "${expected_marker}" != "omr-v2-${UNIQUE_HASH}" ]]; then
    echo "The published OMR v2 sentinel metadata is inconsistent." >&2
    exit 1
fi

work_dir=$(mktemp -d /tmp/quay-omr-v3-sentinel.XXXXXX)
chmod 0700 "${work_dir}"
auth_file="${work_dir}/registry-auth.json"

registry_credentials=$(tr -d '\r\n' < "${SHARED_DIR}/mirror_registry_creds")
if [[ -z "${registry_credentials}" || "${registry_credentials}" != *:* ]]; then
    echo "The runtime OMR credential is invalid." >&2
    exit 1
fi
registry_auth=$(printf '%s' "${registry_credentials}" | base64 -w 0)
unset registry_credentials
jq -n --arg host "${registry_host}" --arg auth "${registry_auth}" '
  {auths: {($host): {auth: $auth}}}
' > "${auth_file}"
unset registry_auth
chmod 0600 "${auth_file}"

pre_info="${ARTIFACT_DIR}/omr-v3-migrated-sentinel-image.json"
oc image info "${expected_tag}" \
    --registry-config="${auth_file}" \
    --certificate-authority="${SHARED_DIR}/mirror_registry_ca.crt" \
    -o json > "${pre_info}"
actual_digest=$(jq -er '
  .digest | select(test("^sha256:[a-f0-9]{64}$"))
' "${pre_info}")
if [[ "${actual_digest}" != "${expected_digest}" ]]; then
    echo "The migrated sentinel tag changed digest: expected ${expected_digest}, got ${actual_digest}." >&2
    exit 1
fi

oc create namespace "${sentinel_namespace}" --dry-run=client -o yaml | oc apply -f -
namespace_created=true

daemonset_file="${work_dir}/sentinel-daemonset.json"
jq -n --arg image "${expected_image}" --arg marker "${expected_marker}" '
  {
    apiVersion: "apps/v1",
    kind: "DaemonSet",
    metadata: {
      name: "omr-migration-sentinel",
      namespace: "quay-omr-migration-sentinel"
    },
    spec: {
      selector: {matchLabels: {app: "omr-migration-sentinel"}},
      template: {
        metadata: {labels: {app: "omr-migration-sentinel"}},
        spec: {
          tolerations: [{operator: "Exists"}],
          terminationGracePeriodSeconds: 1,
          containers: [{
            name: "sentinel",
            image: $image,
            imagePullPolicy: "Always",
            command: [
              "/bin/sh",
              "-ec",
              "test \"$(cat /omr-sentinel/pre-migration-marker)\" = \"${EXPECTED_MARKER}\"\nprintf \"validated %s on %s\\n\" \"${EXPECTED_MARKER}\" \"${NODE_NAME}\"\nwhile true; do sleep 3600; done"
            ],
            env: [
              {name: "EXPECTED_MARKER", value: $marker},
              {
                name: "NODE_NAME",
                valueFrom: {fieldRef: {fieldPath: "spec.nodeName"}}
              }
            ],
            resources: {
              requests: {cpu: "10m", memory: "32Mi"},
              limits: {memory: "128Mi"}
            },
            securityContext: {
              allowPrivilegeEscalation: false,
              capabilities: {drop: ["ALL"]},
              runAsNonRoot: true,
              seccompProfile: {type: "RuntimeDefault"}
            }
          }]
        }
      }
    }
  }
' > "${daemonset_file}"
oc apply -f "${daemonset_file}"
if ! oc -n "${sentinel_namespace}" rollout status \
    daemonset/omr-migration-sentinel --timeout=10m; then
    echo "The migrated sentinel did not start on every node." >&2
    exit 1
fi

nodes_file="${work_dir}/nodes.json"
daemonset_status_file="${ARTIFACT_DIR}/omr-migration-sentinel-daemonset.json"
oc get nodes -o json > "${nodes_file}"
oc -n "${sentinel_namespace}" get daemonset/omr-migration-sentinel \
    -o json > "${daemonset_status_file}"
node_count=$(jq -er '.items | length | select(. > 0)' "${nodes_file}")
if ! jq -e --argjson nodes "${node_count}" '
  (.status.desiredNumberScheduled // 0) == $nodes
  and (.status.currentNumberScheduled // 0) == $nodes
  and (.status.updatedNumberScheduled // 0) == $nodes
  and (.status.numberReady // 0) == $nodes
  and (.status.numberAvailable // 0) == $nodes
  and (.status.numberMisscheduled // 0) == 0
' "${daemonset_status_file}" >/dev/null; then
    echo "The sentinel DaemonSet did not validate exactly one ready pod on each node." >&2
    exit 1
fi
oc -n "${sentinel_namespace}" get pods -l app=omr-migration-sentinel \
    -o wide | tee "${ARTIFACT_DIR}/omr-migration-sentinel-pods.txt"

post_marker="omr-v3-${UNIQUE_HASH}"
post_tag="${expected_repository}:post-${UNIQUE_HASH}"
post_rootfs="${work_dir}/post-rootfs"
post_layer="${work_dir}/post-migration-layer.tar.gz"
install -d -m 0755 "${post_rootfs}/omr-sentinel"
printf '%s\n' "${post_marker}" > "${post_rootfs}/omr-sentinel/post-migration-marker"
chmod 0644 "${post_rootfs}/omr-sentinel/post-migration-marker"
tar --create --gzip --file "${post_layer}" --directory "${post_rootfs}" .

oc image append \
    --from="${expected_image}" \
    --to="${post_tag}" \
    --registry-config="${auth_file}" \
    --certificate-authority="${SHARED_DIR}/mirror_registry_ca.crt" \
    "${post_layer}"

post_info="${ARTIFACT_DIR}/omr-v3-post-migration-sentinel-image.json"
oc image info "${post_tag}" \
    --registry-config="${auth_file}" \
    --certificate-authority="${SHARED_DIR}/mirror_registry_ca.crt" \
    -o json > "${post_info}"
post_digest=$(jq -er '
  .digest | select(test("^sha256:[a-f0-9]{64}$"))
' "${post_info}")
if [[ "${post_digest}" == "${expected_digest}" ]]; then
    echo "The post-migration write did not produce a new image digest." >&2
    exit 1
fi
post_image="${expected_repository}@${post_digest}"

post_pod_file="${work_dir}/post-migration-pod.json"
jq -n \
    --arg image "${post_image}" \
    --arg pre_marker "${expected_marker}" \
    --arg post_marker "${post_marker}" '
  {
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: "omr-v3-post-migration-write",
      namespace: "quay-omr-migration-sentinel"
    },
    spec: {
      restartPolicy: "Never",
      tolerations: [{operator: "Exists"}],
      containers: [{
        name: "sentinel",
        image: $image,
        imagePullPolicy: "Always",
        command: [
          "/bin/sh",
          "-ec",
          "test \"$(cat /omr-sentinel/pre-migration-marker)\" = \"${PRE_MARKER}\"\ntest \"$(cat /omr-sentinel/post-migration-marker)\" = \"${POST_MARKER}\"\nprintf \"validated post-migration write %s\\n\" \"${POST_MARKER}\""
        ],
        env: [
          {name: "PRE_MARKER", value: $pre_marker},
          {name: "POST_MARKER", value: $post_marker}
        ],
        resources: {
          requests: {cpu: "10m", memory: "32Mi"},
          limits: {memory: "128Mi"}
        },
        securityContext: {
          allowPrivilegeEscalation: false,
          capabilities: {drop: ["ALL"]},
          runAsNonRoot: true,
          seccompProfile: {type: "RuntimeDefault"}
        }
      }]
    }
  }
' > "${post_pod_file}"
oc apply -f "${post_pod_file}"
if ! oc -n "${sentinel_namespace}" wait pod/omr-v3-post-migration-write \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m; then
    echo "OpenShift could not pull and validate the image written through OMR v3." >&2
    exit 1
fi
oc -n "${sentinel_namespace}" get pod/omr-v3-post-migration-write -o wide
oc -n "${sentinel_namespace}" logs pod/omr-v3-post-migration-write |
    tee "${ARTIFACT_DIR}/omr-v3-post-migration-write.log"

echo "OMR v2 sentinel content survived migration, every OpenShift node pulled it, and OMR v3 accepted and served a new write."
