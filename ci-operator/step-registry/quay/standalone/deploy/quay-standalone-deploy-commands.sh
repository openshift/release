#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

workdir=""

cleanup() {
    local status=$?

    trap - EXIT TERM
    if [[ -n "${workdir}" ]]; then
        rm -rf -- "${workdir}"
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

# Writes a SHARED_DIR file atomically, without a trailing newline, so a
# consumer never reads a partial value.
publish() {
    local name=$1 value=$2 mode=${3:-0644} tmp

    tmp=$(mktemp "${SHARED_DIR}/.${name}.XXXXXX")
    chmod "${mode}" "${tmp}"
    printf '%s' "${value}" > "${tmp}"
    mv -f -- "${tmp}" "${SHARED_DIR}/${name}"
}

for command in aws base64 curl jq oc openssl ssh yq-v4; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the deploy step image." >&2
        exit 1
    fi
done

for required_file in \
    "${CLUSTER_PROFILE_DIR}/.awscred" \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    /var/run/quay-qe-aws-secret/access_key \
    /var/run/quay-qe-aws-secret/secret_key \
    /var/run/quay-qe-quay-secret/username \
    /var/run/quay-qe-quay-secret/password \
    /var/run/quay-qe-quay-secret/email \
    /var/run/vault/mirror-registry/registry_stage.json \
    "${SHARED_DIR}/quay_standalone_region" \
    "${SHARED_DIR}/quay_standalone_hostname" \
    "${SHARED_DIR}/quay_standalone_target_group_arn" \
    "${SHARED_DIR}/quay_standalone_clair_endpoint" \
    "${SHARED_DIR}/quay_standalone_clair_target_group_arn" \
    "${SHARED_DIR}/quay_standalone_nodes" \
    "${SHARED_DIR}/quay_standalone_redis" \
    "${SHARED_DIR}/quay_standalone_ssh_user" \
    "${SHARED_DIR}/quay_standalone_db_endpoint" \
    "${SHARED_DIR}/quay_standalone_db_port" \
    "${SHARED_DIR}/quay_standalone_db_name" \
    "${SHARED_DIR}/quay_standalone_db_user" \
    "${SHARED_DIR}/quay_standalone_db_password" \
    "${SHARED_DIR}/quay_standalone_s3_bucket"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required deploy input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
region=$(<"${SHARED_DIR}/quay_standalone_region")
hostname=$(<"${SHARED_DIR}/quay_standalone_hostname")
target_group_arn=$(<"${SHARED_DIR}/quay_standalone_target_group_arn")
clair_endpoint=$(<"${SHARED_DIR}/quay_standalone_clair_endpoint")
clair_target_group_arn=$(<"${SHARED_DIR}/quay_standalone_clair_target_group_arn")
ssh_user=$(<"${SHARED_DIR}/quay_standalone_ssh_user")
db_endpoint=$(<"${SHARED_DIR}/quay_standalone_db_endpoint")
db_port=$(<"${SHARED_DIR}/quay_standalone_db_port")
db_name=$(<"${SHARED_DIR}/quay_standalone_db_name")
db_user=$(<"${SHARED_DIR}/quay_standalone_db_user")
bucket=$(<"${SHARED_DIR}/quay_standalone_s3_bucket")
mapfile -t nodes < "${SHARED_DIR}/quay_standalone_nodes"
read -r _ redis_public_ip redis_private_ip < "${SHARED_DIR}/quay_standalone_redis"
if [[ "${#nodes[@]}" -ne 3 ]]; then
    echo "Expected 3 lines in ${SHARED_DIR}/quay_standalone_nodes, got ${#nodes[@]}." >&2
    exit 1
fi
# These reach remote shells unquoted.
if [[ ! "${redis_public_ip}" =~ ^[0-9.]+$ || ! "${redis_private_ip}" =~ ^[0-9.]+$ ]] ||
   [[ ! "${db_endpoint}" =~ ^[A-Za-z0-9.-]+$ || ! "${db_port}" =~ ^[0-9]+$ ]] ||
   [[ ! "${db_name}" =~ ^[A-Za-z0-9_]+$ || ! "${db_user}" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Invalid Redis or database details in SHARED_DIR." >&2
    exit 1
fi

umask 077
workdir=$(mktemp -d /tmp/quay-standalone-deploy.XXXXXX)

# a. The Quay and Clair images and the stage pull auth that reads them.
if [[ -z "${QUAY_STANDALONE_IMAGE}" || -z "${QUAY_STANDALONE_CLAIR_IMAGE}" ]]; then
    index_ref="${QUAY_INDEX_IMAGE_REPO}:${QUAY_INDEX_IMAGE_TAG}"
    echo "Resolving ART FBC ${index_ref} to a digest..."
    index_digest=$(oc image info --show-multiarch "${index_ref}" -o json \
        | jq -r 'if type == "array" then .[0].listDigest else .digest end')
    if [[ ! "${index_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        echo "Could not resolve ${index_ref} to a digest." >&2
        exit 1
    fi
    index_image="${QUAY_INDEX_IMAGE_REPO}@${index_digest}"
    echo "Resolved ${index_ref} -> ${index_image}"

    # ART labels each FBC with the bundle it was built for; older bundles in
    # the same catalog also carry quay-rhel9 and clair-rhel9 relatedImages.
    bundle=$(oc image info "${index_image}" --filter-by-os linux/amd64 -o json \
        | jq -r '.config.config.Labels["com.redhat.art.bundle.pullspec"] // empty')
    if [[ -z "${bundle}" ]]; then
        echo "${index_image} has no com.redhat.art.bundle.pullspec label." >&2
        exit 1
    fi
    mkdir -p "${workdir}/catalog"
    oc image extract "${index_image}" --filter-by-os linux/amd64 \
        --path "/configs/:${workdir}/catalog" --confirm
    find "${workdir}/catalog" -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print0 \
        | while IFS= read -r -d '' file; do
            case "${file}" in
                *.json) cat "${file}" ;;
                *) yq-v4 -o=json -I=0 '.' "${file}" ;;
            esac
        done \
        | jq -c --arg bundle "${bundle}" \
            'select(.schema == "olm.bundle" and .image == $bundle) | .relatedImages[]?' \
        > "${workdir}/related.json"
fi

# stage_image FILTER REPOSITORY: the bundle's single registry.redhat.io/quay/
# REPOSITORY digest among relatedImages matching the jq FILTER, rewritten to
# the stage registry, where ART publishes pre-release digests.
stage_image() {
    local filter=$1 repository=$2 images

    mapfile -t images < <(jq -r "select(${filter}) | .image" "${workdir}/related.json" | sort -u)
    if [[ "${#images[@]}" -ne 1 ]] ||
       [[ ! "${images[0]}" =~ ^registry\.redhat\.io/quay/${repository}@sha256:[a-f0-9]{64}$ ]]; then
        echo "Bundle ${bundle} in ${index_image} has no single ${repository} relatedImage digest (found: ${images[*]:-none})." >&2
        return 1
    fi
    printf 'registry.stage.redhat.io/quay/%s\n' "${images[0]#registry.redhat.io/quay/}"
}

if [[ -n "${QUAY_STANDALONE_IMAGE}" ]]; then
    app_image="${QUAY_STANDALONE_IMAGE}"
    echo "Using QUAY_STANDALONE_IMAGE ${app_image}"
else
    app_image=$(stage_image '.name == "quay-rhel9"' quay-rhel9)
    echo "Quay image for bundle ${bundle}: ${app_image}"
fi
publish quay_app_image "${app_image}"
if [[ -n "${QUAY_STANDALONE_CLAIR_IMAGE}" ]]; then
    clair_image="${QUAY_STANDALONE_CLAIR_IMAGE}"
    echo "Using QUAY_STANDALONE_CLAIR_IMAGE ${clair_image}"
else
    clair_image=$(stage_image '.name | contains("clair")' clair-rhel9)
    echo "Clair image for bundle ${bundle}: ${clair_image}"
fi
publish quay_clair_image "${clair_image}"

# Disable tracing while registry credentials are in scope.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
stage_json=/var/run/vault/mirror-registry/registry_stage.json
stage_user=$(jq -er '.user | strings | select(length > 0)' "${stage_json}")
stage_password=$(jq -er '.password | strings | select(length > 0)' "${stage_json}")
STAGE_AUTH=$(printf '%s:%s' "${stage_user}" "${stage_password}" | base64 -w 0) \
    jq -n '{auths: {"registry.stage.redhat.io": {auth: env.STAGE_AUTH}}}' > "${workdir}/pull-auth.json"
unset stage_user stage_password
install -m 0600 "${workdir}/pull-auth.json" "${SHARED_DIR}/quay-pull-auth.json"
$WAS_TRACING && set -x

# b. Per-job CA and server certificate. The NLB DNS name can exceed the 64
# characters a CN allows, so it goes in the SAN only.
openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 3 \
    -keyout "${workdir}/ca.key" -out "${workdir}/ca.crt" \
    -subj "/CN=Quay standalone CI CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -new -nodes -newkey rsa:2048 -sha256 \
    -keyout "${workdir}/ssl.key" -out "${workdir}/ssl.csr" \
    -subj "/CN=quay-standalone" 2>/dev/null
printf '%s\n' \
    "subjectAltName=DNS:${hostname}" \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth" \
    "subjectKeyIdentifier=hash" \
    "authorityKeyIdentifier=keyid,issuer" > "${workdir}/server.ext"
openssl x509 -req -sha256 -days 3 -in "${workdir}/ssl.csr" \
    -CA "${workdir}/ca.crt" -CAkey "${workdir}/ca.key" -CAcreateserial \
    -extfile "${workdir}/server.ext" -out "${workdir}/ssl.cert" 2>/dev/null
openssl verify -CAfile "${workdir}/ca.crt" "${workdir}/ssl.cert"
cp "${workdir}/ca.crt" "${workdir}/extra_ca_cert_quay_standalone.crt"
install -m 0644 "${workdir}/ca.crt" "${SHARED_DIR}/quay_standalone_ca.crt"

if ! whoami >/dev/null 2>&1; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and the current UID has no passwd entry." >&2
        exit 1
    fi
fi

ssh_options=(
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
    -o ConnectTimeout=10
    -o ConnectionAttempts=3
    -o ServerAliveInterval=30
)

# Runs a command on a host. Secrets go over stdin, never in the command.
on_host() {
    local host=$1

    shift
    # shellcheck disable=SC2029 # the caller builds the remote command
    ssh "${ssh_options[@]}" "${ssh_user}@${host}" "$@"
}

# c. Redis on its own VM.
echo "Installing Redis on ${redis_private_ip}..."
on_host "${redis_public_ip}" 'sudo dnf install -y -q redis'
set +x
redis_password=$(openssl rand -hex 24)
# Later directives override the packaged bind 127.0.0.1.
printf 'bind 0.0.0.0\nrequirepass %s\n' "${redis_password}" \
    | on_host "${redis_public_ip}" 'sudo tee -a /etc/redis/redis.conf >/dev/null'
$WAS_TRACING && set -x
on_host "${redis_public_ip}" 'sudo systemctl enable --now redis'

read -r _ node1_public_ip _ <<< "${nodes[0]}"
# shellcheck disable=SC2016 # expanded on the node
redis_ping='read -r pw; exec 3<>"/dev/tcp/$1/6379"; printf "AUTH %s\r\nPING\r\n" "${pw}" >&3; timeout 10 head -n 2 <&3'
redis_ready=false
for attempt in $(seq 1 12); do
    set +x
    reply=$(printf '%s\n' "${redis_password}" \
        | on_host "${node1_public_ip}" "bash -c $(printf '%q' "${redis_ping}") _ ${redis_private_ip}" 2>&1 || true)
    $WAS_TRACING && set -x
    # +OK first: a Redis without requirepass would answer PING too.
    if [[ "${reply}" == "+OK"*"+PONG"* ]]; then
        redis_ready=true
        break
    fi
    echo "Waiting for Redis PING from node 1 (${attempt}/12)."
    sleep 5
done
if [[ "${redis_ready}" != true ]]; then
    echo "Redis at ${redis_private_ip}:6379 did not answer an authenticated PING from node 1." >&2
    exit 1
fi
echo "Redis answers an authenticated PING from node 1."

# d. pg_trgm, which Quay needs and the RDS master user may create.
# shellcheck disable=SC2016 # expanded on the node
create_trgm='read -r PGPASSWORD; export PGPASSWORD; psql "host=$1 port=$2 dbname=$3 user=$4 sslmode=require" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"'
on_host "${node1_public_ip}" "bash -c $(printf '%q' "${create_trgm}") _ ${db_endpoint} ${db_port} ${db_name} ${db_user}" \
    < "${SHARED_DIR}/quay_standalone_db_password"

# e. Clair's own role and database on the same RDS instance. The master user
# must be a member of clair to create a database it owns (PostgreSQL 16+).
# Both passwords and the SQL that holds the new one go over stdin. The
# password and the PSK are hex: safe in SQL and sed, and valid base64 for
# auth.psk.key.
# shellcheck disable=SC2016 # expanded on the node
create_clair_db='read -r PGPASSWORD; export PGPASSWORD; psql "host=$1 port=$2 dbname=$3 user=$4 sslmode=require" -v ON_ERROR_STOP=1 -q -f -'
set +x
clair_db_password=$(openssl rand -hex 24)
clair_psk=$(openssl rand -hex 32)
publish quay_standalone_clair_db_password "${clair_db_password}" 0600
publish quay_standalone_clair_psk "${clair_psk}" 0600
{
    cat "${SHARED_DIR}/quay_standalone_db_password"
    printf '%s\n' \
        "SELECT 'CREATE ROLE clair' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'clair')" '\gexec' \
        "ALTER ROLE clair WITH LOGIN PASSWORD '${clair_db_password}';" \
        'GRANT clair TO CURRENT_USER;' \
        "SELECT 'CREATE DATABASE clair OWNER clair' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'clair')" '\gexec'
} | on_host "${node1_public_ip}" "bash -c $(printf '%q' "${create_clair_db}") _ ${db_endpoint} ${db_port} ${db_name} ${db_user}"

# f. One Clair config for both nodes, shaped like the sample in
# https://docs.redhat.com/en/documentation/red_hat_quay/3.18/html/vulnerability_reporting_with_clair_on_red_hat_quay/clair-standalone-configure
# The notifier has no delivery mechanism, so Clair disables it.
CLAIR_DB_PASSWORD="${clair_db_password}" CLAIR_PSK="${clair_psk}" \
jq -n --arg db_host "${db_endpoint}" --arg db_port "${db_port}" \
    '"host=\($db_host) port=\($db_port) dbname=clair user=clair password=\(env.CLAIR_DB_PASSWORD) sslmode=require" as $conn
    | {
        http_listen_addr: ":8081",
        introspection_addr: ":8089",
        log_level: "info",
        indexer: {connstring: $conn, scanlock_retry: 10, layer_scan_concurrency: 5, migrations: true},
        matcher: {connstring: $conn, max_conn_pool: 100, migrations: true},
        notifier: {connstring: $conn, delivery_interval: "1m", poll_interval: "5m", migrations: true},
        auth: {psk: {key: env.CLAIR_PSK, iss: ["quay"]}},
        metrics: {name: "prometheus"}
    }' > "${workdir}/clair-config.yaml"
unset clair_db_password
$WAS_TRACING && set -x

# The image runs as nobody, so the config is world-readable; only ec2-user,
# who has sudo anyway, logs in to the node. With FEATURE_PROXY_STORAGE, Clair
# fetches layers from https://<NLB>/_storage_proxy/, so it needs the job CA;
# SSL_CERT_DIR adds it and keeps the system roots the updaters use.
clair_dir=/etc/clair
start_clair() {
    local public_ip=$1

    on_host "${public_ip}" "sudo install -d -m 0755 ${clair_dir} ${clair_dir}/certs"
    on_host "${public_ip}" "sudo install -m 0644 /dev/stdin ${clair_dir}/config.yaml" \
        < "${workdir}/clair-config.yaml"
    on_host "${public_ip}" "sudo install -m 0644 /dev/stdin ${clair_dir}/certs/ca.crt" \
        < "${workdir}/ca.crt"
    on_host "${public_ip}" 'sudo install -D -m 0600 /dev/stdin /etc/quay-standalone/pull-auth.json' \
        < "${workdir}/pull-auth.json"
    on_host "${public_ip}" "sudo podman pull -q --authfile /etc/quay-standalone/pull-auth.json $(printf '%q' "${clair_image}"); \
        pulled=\$?; sudo rm -f /etc/quay-standalone/pull-auth.json; [ \$pulled -eq 0 ] \
        && sudo podman run -d --name clair -p 8081:8081 -p 8089:8089 \
            -e CLAIR_MODE=combo -e CLAIR_CONF=/clair/config.yaml \
            -e SSL_CERT_DIR=/clair/certs:/etc/pki/tls/certs \
            -v ${clair_dir}:/clair:Z $(printf '%q' "${clair_image}")"
}

# /readyz turns 200 once Clair has run its migrations; /healthz does not wait.
wait_clair_ready() {
    local name=$1 public_ip=$2 attempt

    for attempt in $(seq 1 90); do
        if on_host "${public_ip}" 'curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8089/readyz' 2>/dev/null; then
            echo "Clair on ${name} is ready."
            return 0
        fi
        if (( attempt % 6 == 0 )); then
            echo "Waiting for Clair /readyz on ${name} (${attempt}/90)."
        fi
        sleep 10
    done
    echo "Clair on ${name} did not report /readyz 200 within 15 minutes; see the gather step's podman logs." >&2
    on_host "${public_ip}" 'sudo podman ps -a' >&2 || true
    return 1
}

# wait_targets ARN COUNT NAME: waits for COUNT healthy targets in a target group.
wait_targets() {
    local arn=$1 count=$2 name=$3 healthy=0 attempt

    for attempt in $(seq 1 60); do
        healthy=$(aws --region "${region}" elbv2 describe-target-health --target-group-arn "${arn}" \
            --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
        if [[ "${healthy}" == "${count}" ]]; then
            return 0
        fi
        echo "Waiting for ${count} healthy ${name} targets (${healthy} healthy, ${attempt}/60)."
        sleep 10
    done
    echo "Only ${healthy} of ${count} ${name} targets became healthy." >&2
    aws --region "${region}" elbv2 describe-target-health --target-group-arn "${arn}" >&2 || true
    return 1
}

# Node 1 first, so it alone runs the migrations.
for index in 0 1; do
    read -r instance_id public_ip _ <<< "${nodes[${index}]}"
    echo "Starting Clair on node $((index + 1)) (${instance_id})..."
    start_clair "${public_ip}"
    wait_clair_ready "node $((index + 1)) (${instance_id})" "${public_ip}"
done
wait_targets "${clair_target_group_arn}" 2 "Clair NLB"
echo "Clair serves ${clair_endpoint} from nodes 1 and 2."

# g. One config bundle for all nodes. JSON is YAML, and jq keeps every value
# quoted; secrets reach jq through the environment, not its arguments. The
# default model cache keeps a security report for 300s, which would answer
# failover's security reads without asking Clair.
set +x
QUAY_S3_ACCESS_KEY=$(</var/run/quay-qe-aws-secret/access_key)
QUAY_S3_SECRET_KEY=$(</var/run/quay-qe-aws-secret/secret_key)
if ! AWS_ACCESS_KEY_ID="${QUAY_S3_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${QUAY_S3_SECRET_KEY}" \
    aws --region "${region}" s3api head-bucket --bucket "${bucket}"; then
    echo "The quay-tests/aws keys cannot access bucket ${bucket}; Quay S3Storage would fail." >&2
    exit 1
fi
QUAY_DB_PASSWORD=$(<"${SHARED_DIR}/quay_standalone_db_password") \
QUAY_REDIS_PASSWORD="${redis_password}" \
QUAY_SECRET_KEY=$(openssl rand -hex 32) \
QUAY_DATABASE_SECRET_KEY=$(openssl rand -hex 32) \
QUAY_S3_ACCESS_KEY="${QUAY_S3_ACCESS_KEY}" \
QUAY_S3_SECRET_KEY="${QUAY_S3_SECRET_KEY}" \
QUAY_CLAIR_PSK="${clair_psk}" \
jq -n \
    --arg hostname "${hostname}" \
    --arg db_host "${db_endpoint}" --arg db_port "${db_port}" \
    --arg db_name "${db_name}" --arg db_user "${db_user}" \
    --arg redis_host "${redis_private_ip}" \
    --arg bucket "${bucket}" --arg region "${region}" \
    --arg clair_endpoint "${clair_endpoint}" \
    '{host: $redis_host, port: 6379, password: env.QUAY_REDIS_PASSWORD} as $redis
    | {
        SETUP_COMPLETE: true,
        SERVER_HOSTNAME: $hostname,
        PREFERRED_URL_SCHEME: "https",
        DB_URI: "postgresql://\($db_user):\(env.QUAY_DB_PASSWORD)@\($db_host):\($db_port)/\($db_name)",
        SECRET_KEY: env.QUAY_SECRET_KEY,
        DATABASE_SECRET_KEY: env.QUAY_DATABASE_SECRET_KEY,
        BUILDLOGS_REDIS: $redis,
        USER_EVENTS_REDIS: $redis,
        PULL_METRICS_REDIS: ($redis + {db: 1}),
        DISTRIBUTED_STORAGE_CONFIG: {default: ["S3Storage", {
            s3_bucket: $bucket,
            storage_path: "/quay",
            s3_access_key: env.QUAY_S3_ACCESS_KEY,
            s3_secret_key: env.QUAY_S3_SECRET_KEY,
            host: "s3.\($region).amazonaws.com",
            s3_region: $region
        }]},
        DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: ["default"],
        DISTRIBUTED_STORAGE_PREFERENCE: ["default"],
        USERFILES_LOCATION: "default",
        USERFILES_PATH: "userfiles/",
        AUTHENTICATION_TYPE: "Database",
        SUPER_USERS: ["quay", "admin"],
        GLOBAL_READONLY_SUPER_USERS: ["readonly"],
        FEATURE_USER_INITIALIZE: true,
        FEATURE_UI_V2: true,
        FEATURE_MAILING: false,
        FEATURE_OTEL_TRACING: false,
        CREATE_PRIVATE_REPO_ON_PUSH: true,
        CREATE_NAMESPACE_ON_PUSH: true,
        FEATURE_EXTENDED_REPOSITORY_NAMES: true,
        FEATURE_QUOTA_MANAGEMENT: true,
        FEATURE_AUTO_PRUNE: true,
        FEATURE_PROXY_CACHE: true,
        PERMANENTLY_DELETE_TAGS: true,
        RESET_CHILD_MANIFEST_EXPIRATION: true,
        FEATURE_PROXY_STORAGE: true,
        FEATURE_SUPERUSER_CONFIGDUMP: true,
        FEATURE_SUPERUSERS_FULL_ACCESS: true,
        FEATURE_UI_MODELCARD: true,
        FEATURE_ANONYMOUS_ACCESS: true,
        BROWSER_API_CALLS_XHR_ONLY: false,
        FEATURE_USERNAME_CONFIRMATION: false,
        FEATURE_LISTEN_IP_VERSION: "IPv4",
        REPO_MIRROR_ROLLBACK: false,
        AUTOPRUNE_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1,
        FEATURE_IMAGE_EXPIRY_TRIGGER: true,
        NOTIFICATION_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1,
        DEFAULT_TAG_EXPIRATION: "2w",
        TAG_EXPIRATION_OPTIONS: ["2w", "4w", "8w", "1d"],
        REDIS_FLUSH_INTERVAL_SECONDS: 30,
        FEATURE_IMAGE_PULL_STATS: true,
        FEATURE_ORG_MIRROR: true,
        FEATURE_IMMUTABLE_TAGS: true,
        FEATURE_PROGRAMMATIC_BOOTSTRAP: false,
        FEATURE_USER_METADATA: true,
        FEATURE_SPARSE_INDEX: true,
        FEATURE_QUOTA_NOTIFICATIONS: true,
        FEATURE_EDIT_QUOTA: true,
        FEATURE_CHANGE_TAG_EXPIRATION: true,
        LOG_ARCHIVE_LOCATION: "default",
        ACTION_LOG_ARCHIVE_LOCATION: "default",
        SESSION_TIMEOUT: "2h",
        DEFAULT_UI: "react",
        FEATURE_BUILD_SUPPORT: false,
        FEATURE_SECURITY_SCANNER: true,
        SECURITY_SCANNER_V4_ENDPOINT: $clair_endpoint,
        SECURITY_SCANNER_V4_PSK: env.QUAY_CLAIR_PSK,
        SECURITY_SCANNER_INDEXING_INTERVAL: 30,
        DATA_MODEL_CACHE_CONFIG: {engine: "inmemory", security_report_cache_ttl: "1s"}
    }' > "${workdir}/config.yaml"
unset QUAY_S3_ACCESS_KEY QUAY_S3_SECRET_KEY redis_password clair_psk
$WAS_TRACING && set -x

# h. Same bundle, certificate and key on every node, readable by the Quay
# container's UID 1001 only. Node 1 starts first so it alone runs migrations.
config_dir=/etc/quay-standalone/config
start_node() {
    local public_ip=$1 file

    on_host "${public_ip}" "sudo install -d -m 0700 -o 1001 -g 0 ${config_dir}"
    for file in config.yaml ssl.cert ssl.key extra_ca_cert_quay_standalone.crt; do
        on_host "${public_ip}" "sudo install -m 0600 -o 1001 -g 0 /dev/stdin ${config_dir}/${file}" \
            < "${workdir}/${file}"
    done
    on_host "${public_ip}" 'sudo install -m 0600 /dev/stdin /etc/quay-standalone/pull-auth.json' \
        < "${workdir}/pull-auth.json"
    on_host "${public_ip}" "sudo podman pull -q --authfile /etc/quay-standalone/pull-auth.json $(printf '%q' "${app_image}"); \
        pulled=\$?; sudo rm -f /etc/quay-standalone/pull-auth.json; [ \$pulled -eq 0 ] \
        && sudo podman run -d --name quay -p 8443:8443 -v ${config_dir}:/conf/stack:Z $(printf '%q' "${app_image}")"
}

wait_node_healthy() {
    local name=$1 public_ip=$2 code attempt

    for attempt in $(seq 1 90); do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
            --cacert "${workdir}/ca.crt" --resolve "${hostname}:8443:${public_ip}" \
            "https://${hostname}:8443/health/instance" 2>/dev/null || true)
        if [[ "${code}" == 200 ]]; then
            echo "${name} is healthy."
            return 0
        fi
        if (( attempt % 6 == 0 )); then
            echo "Waiting for ${name} /health/instance (HTTP ${code}, ${attempt}/90)."
        fi
        sleep 10
    done
    echo "${name} did not report /health/instance 200 within 15 minutes; see the gather step's podman logs." >&2
    on_host "${public_ip}" 'sudo podman ps -a' >&2 || true
    return 1
}

for index in 0 1 2; do
    read -r instance_id public_ip _ <<< "${nodes[${index}]}"
    echo "Starting Quay on node $((index + 1)) (${instance_id})..."
    start_node "${public_ip}"
    if [[ "${index}" -eq 0 ]]; then
        wait_node_healthy "node 1 (${instance_id})" "${public_ip}"
    fi
done
for index in 1 2; do
    read -r instance_id public_ip _ <<< "${nodes[${index}]}"
    wait_node_healthy "node $((index + 1)) (${instance_id})" "${public_ip}"
done

wait_targets "${target_group_arn}" 3 NLB

# i. The first user, through the NLB.
set +x
http_code=$(QUAY_USERNAME=$(</var/run/quay-qe-quay-secret/username) \
    QUAY_PASSWORD=$(</var/run/quay-qe-quay-secret/password) \
    QUAY_EMAIL=$(</var/run/quay-qe-quay-secret/email) \
    jq -n '{username: env.QUAY_USERNAME, password: env.QUAY_PASSWORD, email: env.QUAY_EMAIL, access_token: true}' \
    | curl -sS -o "${workdir}/initialize.json" -w '%{http_code}' --max-time 60 \
        --cacert "${workdir}/ca.crt" -X POST -H 'Content-Type: application/json' --data-binary @- \
        "https://${hostname}/api/v1/user/initialize" || true)
if [[ "${http_code}" != 200 ]]; then
    echo "POST /api/v1/user/initialize returned HTTP ${http_code}: $(jq -r '.message // empty' "${workdir}/initialize.json" 2>/dev/null || true)" >&2
    exit 1
fi
token=$(jq -er '.access_token | strings | select(length > 0)' "${workdir}/initialize.json")
publish quay_oauth2_token "${token}" 0600
unset token
$WAS_TRACING && set -x

publish quayroute "https://${hostname}"
echo "Quay standalone HA is serving https://${hostname} from 3 nodes."
