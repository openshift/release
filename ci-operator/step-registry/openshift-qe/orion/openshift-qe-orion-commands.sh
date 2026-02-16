#!/bin/bash
set -x

if [ ${RUN_ORION} == false ]; then
  exit 0
fi

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

if [[ $TAG == "latest" ]]; then
    LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/orion/releases/latest" | jq -r '.tag_name');
else
    LATEST_TAG=$TAG
fi
git clone --branch $LATEST_TAG $ORION_REPO --depth 1
pushd orion

# Invoked from orion repo by the openshift-ci bot
if [[ -n "${PULL_NUMBER-}" ]] && [[ "${REPO_NAME}" == "orion" ]]; then
  echo "Invoked from orion repo by the openshift-ci bot, switching to PR#${PULL_NUMBER}"
  git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
  git switch ${PULL_NUMBER}
fi

pip install -r requirements.txt

case "$ES_TYPE" in
  qe)
    ES_PASSWORD=$(<"/secret/qe/password")
    ES_USERNAME=$(<"/secret/qe/username")
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    ;;
  quay-qe)
    ES_PASSWORD=$(<"/secret/quay-qe/password")
    ES_USERNAME=$(<"/secret/quay-qe/username")
    ES_HOST=$(<"/secret/quay-qe/hostname")
    ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"
    ;;
  stackrox)
    ES_SECRETS_PATH='/secret_stackrox'
    ES_PASSWORD=$(<"${ES_SECRETS_PATH}/password")
    ES_USERNAME=$(<"${ES_SECRETS_PATH}/username")
    if [ -e "${ES_SECRETS_PATH}/host" ]; then
        ES_HOST=$(<"${ES_SECRETS_PATH}/host")
    fi
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
    ;;
  *)
    ES_PASSWORD=$(<"/secret/internal/password")
    ES_USERNAME=$(<"/secret/internal/username")
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@opensearch.app.intlab.redhat.com"
    ;;
esac

export ES_SERVER

pip install .

# Print Orion version
orion_version=$(orion --version 2>&1)
orion_version_exit=$?
if [ "$orion_version_exit" -ne 0 ]; then
  echo "orion version prior to v0.1.7"
else
  echo "Orion version: $orion_version"
fi

EXTRA_FLAGS="${ORION_EXTRA_FLAGS:-} --lookback ${LOOKBACK}d --hunter-analyze"

if [ ${OUTPUT_FORMAT} == "JUNIT" ]; then
    EXTRA_FLAGS+=" --output-format junit --save-output-path=junit.xml"
elif [ "${OUTPUT_FORMAT}" == "JSON" ]; then
    EXTRA_FLAGS+=" --output-format json"
elif [ "${OUTPUT_FORMAT}" == "TEXT" ]; then
    EXTRA_FLAGS+=" --output-format text"
else
    echo "Unsupported format: ${OUTPUT_FORMAT}"
    exit 1
fi

if [[ -n "$ORION_CONFIG" ]]; then
    if [[ "$ORION_CONFIG" =~ ^https?:// ]]; then
        fileBasename="$(basename ${ORION_CONFIG})"
        if curl -fsSL "$ORION_CONFIG" -o "$ARTIFACT_DIR/$fileBasename"; then
            ORION_CONFIG="$ARTIFACT_DIR/$fileBasename"
        else
            echo "Error: Failed to download $ORION_CONFIG" >&2
            exit 1
        fi
    fi
fi

if [[ -n "$ACK_FILE" ]]; then
    if [[ "$ACK_FILE" =~ ^https?:// ]]; then
        ackFilePath="$ARTIFACT_DIR/$(basename ${ACK_FILE})"
        if ! curl -fsSL "$ACK_FILE" -o "$ackFilePath" ; then
            echo "Error: Failed to download $ACK_FILE" >&2
            exit 1
        fi
    else
        # Download the latest ACK file
        ackFilePath="$ARTIFACT_DIR/$ACK_FILE"
        curl -sL https://raw.githubusercontent.com/cloud-bulldozer/orion/refs/heads/main/ack/${VERSION}_${ACK_FILE} -o "$ackFilePath"
    fi
    EXTRA_FLAGS+=" --ack $ackFilePath"
fi

if [ ${COLLAPSE} == "true" ]; then
    EXTRA_FLAGS+=" --collapse"
fi

if [[ -n "${ORION_ENVS}" ]]; then
    ORION_ENVS=$(echo "$ORION_ENVS" | xargs)
    IFS=',' read -r -a env_array <<< "$ORION_ENVS"
    for env_pair in "${env_array[@]}"; do
      env_pair=$(echo "$env_pair" | xargs)
      env_key=$(echo "$env_pair" | cut -d'=' -f1)
      env_value=$(echo "$env_pair" | cut -d'=' -f2-)
      export "$env_key"="$env_value"
    done
fi

if [[ -n "${LOOKBACK_SIZE}" ]]; then
    EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

if [[ -n "${LOOKBACK_SIZE}" ]]; then
    EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

if [[ -n "${DISPLAY}" ]]; then
    EXTRA_FLAGS+=" --display ${DISPLAY}"
fi

if [[ -n "${CHANGE_POINT_REPOS}" ]]; then
    EXTRA_FLAGS+=" --github-repos ${CHANGE_POINT_REPOS}"
fi

set +e
set -o pipefail
FILENAME=$(basename ${ORION_CONFIG} | awk -F. '{print $1}')
export es_metadata_index=${ES_METADATA_INDEX} es_benchmark_index=${ES_BENCHMARK_INDEX} VERSION=${VERSION} jobtype="periodic" 
orion --node-count ${IGNORE_JOB_ITERATIONS} --config ${ORION_CONFIG} ${EXTRA_FLAGS} | tee ${ARTIFACT_DIR}/${FILENAME}.txt
orion_exit_status=$?
set -e

cp *.csv *.xml *.json *.txt "${ARTIFACT_DIR}/" 2>/dev/null || true

if [[ -n "${CHANGE_POINT_REPOS}" ]]; then
    GCS_BUCKET="gs://test-platform-results"
    GCS_PATH=""

    # Determine the path to prowjob.json based on prow ENV variables
    case "${JOB_TYPE:-}" in
        presubmit)
        if [[ -n "${ORG_REPO:-}" && -n "${PULL_NUMBER:-}" && -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" ]]; then
            GCS_PATH="pr-logs/pull/${ORG_REPO}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/prowjob.json"
        fi
        ;;
        periodic)
        if [[ -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" ]]; then
            GCS_PATH="logs/${JOB_NAME}/${BUILD_ID}/prowjob.json"
        fi
        ;;
        *)
        exit 0
        ;;
    esac

    [[ -z "$GCS_PATH" ]] && exit 0

    echo "Fetching prowjob.json from $GCS_BUCKET/$GCS_PATH"
    gsutil -m cp -r "${GCS_BUCKET}/${GCS_PATH}" .

    # Extract trigger repos from prowjob.json
    repos=$(jq -r '
        if (.spec.extra_refs // []) | length > 0 then
            .spec.extra_refs[] | "\(.org)/\(.repo)"
        elif (.spec.refs // null) != null then
            "\(.spec.refs.org)/\(.spec.refs.repo)"
        else
            empty
        end
        ' prowjob.json)

    OWNERS_FILE=owners.txt
    : > "$OWNERS_FILE"

    # Iterate over each url to fetch OWNERS
    for repo in $repos; do
        org="${repo%%/*}"
        name="${repo##*/}"

        url="https://raw.githubusercontent.com/openshift/release/master/ci-operator/jobs/${org}/${name}/OWNERS"

        echo "Fetching OWNERS for $repo"

        curl -fsSL "$url" \
            | yq -r '.approvers[], .reviewers[]' \
            >> "$OWNERS_FILE" \
            || echo "OWNERS not found for $repo"
    done

    # dedupe at the end
    sort -u "$OWNERS_FILE" -o "$OWNERS_FILE"

    # Load owners list as a JSON array (skip blank lines)
    OWNERS_JSON=$(jq -R -s -c 'split("\n") | map(select(length > 0))' owners.txt)

    # Check if owners.json is loaded correctly
    echo "Owners loaded as JSON array: $OWNERS_JSON"

    # Loop over each junit*.json file in current directory
    for f in junit*.json; do
        # Skip if no matching files found
        [ -e "$f" ] || { echo "No junit*.json files found"; break; }

        echo "Processing file: $f"

        # Apply jq filter and overwrite the file safely
        jq --argjson owners "$OWNERS_JSON" '
        map(
            if .is_changepoint != true then
            .
            else
            .github_context.repositories |=
                with_entries(
                .value.commits.items |=
                    map(
                        select(
                            (.commit_author.email // "" | ascii_downcase | contains($owners[]))
                            or
                            (.commit_author.name // "" | ascii_downcase | contains($owners[]))
                        )
                    )
                | .value.commits.count = (.value.commits.items | length)
                )
            end
        )
        ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        echo "Updated $f"
    done
fi

if [ $orion_exit_status -eq 3 ]; then
  echo "Orion returned exit code 3, which means there are no results to analyze."
  echo "Exiting zero since there were no regressions found."
  exit 0
fi

exit $orion_exit_status
