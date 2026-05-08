#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if [ "${RUN_ORION}" == "false" ]; then
  exit 0
fi

if [[ -z "${WORKLOAD}" ]]; then
  echo "Error: WORKLOAD is required. Set WORKLOAD env var (e.g., WORKLOAD=nova)." >&2
  exit 1
fi

# SSH setup for VPN access
SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)

# ES from cluster profile
es_host=$(cat "${CLUSTER_PROFILE_DIR}/elastic_host")
es_port=$(cat ${CLUSTER_PROFILE_DIR}/config | jq ".elastic_port")

# Select Orion config based on WORKLOAD
ORION_CONFIG="examples/rhoso/rhoso-${WORKLOAD}.yaml"
echo "Using ORION_CONFIG: ${ORION_CONFIG}"

# Build extra flags locally before passing to remote
EXTRA_FLAGS="${ORION_EXTRA_FLAGS:-} --lookback ${LOOKBACK}d --hunter-analyze"

if [ "${OUTPUT_FORMAT}" == "JUNIT" ]; then
    EXTRA_FLAGS+=" --output-format junit --save-output-path=junit.xml"
elif [ "${OUTPUT_FORMAT}" == "JSON" ]; then
    EXTRA_FLAGS+=" --output-format json"
elif [ "${OUTPUT_FORMAT}" == "TEXT" ]; then
    EXTRA_FLAGS+=" --output-format text"
else
    echo "Unsupported format: ${OUTPUT_FORMAT}"
    exit 1
fi

if [ "${COLLAPSE}" == "true" ]; then
    EXTRA_FLAGS+=" --collapse"
fi

if [[ -n "${LOOKBACK_SIZE}" ]]; then
    EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

if [[ -n "${DISPLAY}" ]]; then
    EXTRA_FLAGS+=" --display ${DISPLAY}"
fi

# Build ORION_ENVS export block for remote script
REMOTE_ENVS=""
if [[ -n "${ORION_ENVS}" ]]; then
    ORION_ENVS_TRIMMED=$(echo "$ORION_ENVS" | xargs)
    IFS=',' read -r -a env_array <<< "$ORION_ENVS_TRIMMED"
    for env_pair in "${env_array[@]}"; do
      env_pair=$(echo "$env_pair" | xargs)
      REMOTE_ENVS+="export ${env_pair}; "
    done
fi

# Determine orion tag
if [[ ${TAG} == "latest" ]]; then
    LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/orion/releases/latest" | jq -r '.tag_name')
else
    LATEST_TAG=${TAG}
fi

FILENAME=$(basename ${ORION_CONFIG} | awk -F. '{print $1}')

# Handle ACK_FILE - download locally then transfer to jumphost
ACK_FLAG=""
if [[ -n "${ACK_FILE}" ]]; then
    ackFileName=""
    if [[ "${ACK_FILE}" =~ ^https?:// ]]; then
        ackFileName=$(basename ${ACK_FILE})
        if ! curl -fsSL "${ACK_FILE}" -o "/tmp/${ackFileName}" ; then
            echo "Error: Failed to download ${ACK_FILE}" >&2
            exit 1
        fi
    else
        ackFileName="${ACK_FILE}"
        curl -sL "https://raw.githubusercontent.com/cloud-bulldozer/orion/refs/heads/main/ack/${ACK_FILE}" -o "/tmp/${ackFileName}"
    fi
    scp -q ${SSH_ARGS} "/tmp/${ackFileName}" root@${jumphost}:/tmp/
    ACK_FLAG="--ack /tmp/${ackFileName}"
fi

# Create the script that will run on the jumphost
cat > /tmp/orion_rhoso_script.sh <<OUTEREOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

export ES_SERVER=http://${es_host}:${es_port}
export es_metadata_index=${ES_METADATA_INDEX}
export es_benchmark_index=${ES_BENCHMARK_INDEX}
export jobtype=periodic
${REMOTE_ENVS}

python3.11 --version
rm -rf /tmp/orion_workdir
mkdir -p /tmp/orion_workdir
cd /tmp/orion_workdir
python3.11 -m venv ./venv_rhoso
source ./venv_rhoso/bin/activate

git clone --branch ${LATEST_TAG} ${ORION_REPO} --depth 1
cd orion

pip install -r requirements.txt
pip install .

orion_version=\$(orion --version 2>&1) || echo 'orion version prior to v0.1.7'
echo "Orion version: \${orion_version}"

if [[ ! -f ${ORION_CONFIG} ]]; then
    echo "Error: Config file ${ORION_CONFIG} not found in orion repo." >&2
    exit 1
fi

set +e
orion --node-count ${IGNORE_JOB_ITERATIONS} --config ${ORION_CONFIG} ${EXTRA_FLAGS} ${ACK_FLAG} 2>&1 | tee /tmp/orion_workdir/${FILENAME}.txt
orion_exit_status=\$?
set -e

cp /tmp/orion_workdir/orion/*.csv /tmp/orion_workdir/orion/*.xml /tmp/orion_workdir/orion/*.json /tmp/orion_workdir/ 2>/dev/null || true

if [ \$orion_exit_status -eq 3 ]; then
  echo 'Orion returned exit code 3, which means there are no results to analyze.'
  echo 'Exiting zero since there were no regressions found.'
  exit 0
fi

exit \$orion_exit_status
OUTEREOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/orion_rhoso_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/orion_rhoso_script.sh'
orion_exit_status=$?

# Copy artifacts back from jumphost
scp -q ${SSH_ARGS} root@${jumphost}:/tmp/orion_workdir/${FILENAME}.txt ${ARTIFACT_DIR}/ 2>/dev/null || true
scp -q ${SSH_ARGS} root@${jumphost}:/tmp/orion_workdir/*.csv ${ARTIFACT_DIR}/ 2>/dev/null || true
scp -q ${SSH_ARGS} root@${jumphost}:/tmp/orion_workdir/*.xml ${ARTIFACT_DIR}/ 2>/dev/null || true
scp -q ${SSH_ARGS} root@${jumphost}:/tmp/orion_workdir/*.json ${ARTIFACT_DIR}/ 2>/dev/null || true

exit $orion_exit_status
