#!/bin/bash

shopt -s extglob

ocm_dir=$(mktemp -d -t ocm-XXXXX)
cd "$ocm_dir" || exit 1
export HOME="$ocm_dir"

logf() {
    local logfile="$1" ; shift
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$logfile"
}

log_file="${ARTIFACT_DIR}/deploy.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

# No deployment if CLUSTER_NAMES is "none".
log "Checking for CLUSTER_NAME=none flag."
if [[ "$CLUSTER_NAMES" == "none" ]]; then
    log "CLUSTER_NAME is set to none. Exiting."
    exit 0
fi

# Early validation of PIPELINE_STAGE
case "${PIPELINE_STAGE}" in
    dev)
        ;;
    integration)
        ;;
    *)
        log "ERROR Invalid PIPELINE_STAGE $PIPELINE_STAGE must be dev or integration."
        exit 1
        ;;
esac

if [[ "$SKIP_COMPONENT_INSTALL" == "false" ]]; then
    if [[ -z "$COMPONENT_IMAGE_REF" ]]; then
        log "ERROR COMPONENT_IMAGE_REF is empty"
        exit 1
    fi
    
    log "Using COMPONENT_IMAGE_REF: $COMPONENT_IMAGE_REF"
else
    log "Skipping component install."
fi

cp "$MAKEFILE" ./Makefile || {
    log "ERROR Could not find make file: $MAKEFILE"
    exit 1
}

log "Using MAKEFILE: $MAKEFILE"

# The actual clusters to deploy to.
clusters=()

# If CLUSTER_NAMES is set, convert it to an array.
if [[ -n "$CLUSTER_NAMES" ]]; then
    log "CLUSTER_NAMES is set: $CLUSTER_NAMES"
    IFS="," read -r -a clusters <<< "$CLUSTER_NAMES"
else
    log "CLUSTER_NAMES is not set. Using CLUSTER_CLAIM_FILE '$CLUSTER_CLAIM_FILE'"
    # If CLUSTER_NAMES is not provided, build it from the CLUSTER_CLAIM_FILE,
    # CLUSTER_INCLUSION_FILTER, and CLUSTER_EXCLUSION_FILTER variables.
    # variables.
    
    # strip suffix claims are in the form hub-1-abcde
    log "Strip suffix from cluster claim names."
    while IFS= read -r claim; do
        # strip off the -abcde suffix
        cluster=$( sed -e "s/-[[:alnum:]]\+$//" <<<"$claim" )
        echo "$cluster" >> deployments
    done < "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"

    # apply inclusion filter
    if [[ -n "$CLUSTER_INCLUSION_FILTER" ]]; then
        log "Applying CLUSTER_INCLUSION_FILTER /$CLUSTER_INCLUSION_FILTER/"
        grep "$CLUSTER_INCLUSION_FILTER" deployments > deployments.bak

        if [[ $(cat deployments.bak | wc -l) == 0 ]]; then
            log "ERROR No clusters left after applying inclusion filter."
            log "Inclusion filter: $CLUSTER_INCLUSION_FILTER"
            log "Original clusters:"
            cat deployments > >(tee -a "$log_file")
            exit 1
        fi

        mv deployments.bak deployments
    fi

    # apply exclusion filter
    if [[ -n "$CLUSTER_EXCLUSION_FILTER" ]]; then
        log "Applying CLUSTER_EXCLUSION_FILTER /$CLUSTER_INCLUSION_FILTER/"
        grep -v "$CLUSTER_EXCLUSION_FILTER" > deployments.bak

        if [[ $(cat deployments.bak | wc -l) == 0 ]]; then
            log "ERROR No clusters left after applying exclusion filter."
            log "Exclusion filter: $CLUSTER_EXCLUSION_FILTER"
            log "Original clusters:"
            cat deployments > >(tee -a "$log_file")
            exit 1
        fi

        mv deployments.bak deployments
    fi

    # read cluster names into array
    read -r -a clusters < deployments
fi

# Verify all clusters have kubeconfig files.
log "Verify that all clusters have kubeconfig files."
for cluster in "${clusters[@]}"; do
    kc_file="${SHARED_DIR}/${cluster}.kc"
    if [[ ! -f "$kc_file" ]]; then
        log "ERROR kubeconfig file not found for $cluster: $kc_file"
        log "Contents of shared directory ${SHARED_DIR}"
        ls "${SHARED_DIR}" > >(tee -a "$log_file")
        exit 1
    fi
done

# Set up git credentials.
log "Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    log "ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
COMPONENT_REPO="github.com/${REPO_OWNER}/${REPO_NAME}"
{
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${PIPELINE_REPO}.git"
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${RELEASE_REPO}.git"
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${DEPLOY_REPO}.git"
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${COMPONENT_REPO}.git"
} >> ghcreds
git config --global credential.helper 'store --file=ghcreds' 

# Set up repo URLs.
pipeline_url="https://${PIPELINE_REPO}.git"
release_url="https://${RELEASE_REPO}.git"
deploy_url="https://${DEPLOY_REPO}.git"
component_url="https://${COMPONENT_REPO}.git"

# Get release branch. PULL_BASE_REF is a Prow variable as described here:
# https://github.com/kubernetes/test-infra/blob/master/prow/jobs.md#job-environment-variables
release=${ACM_RELEASE_VERSION:-"${PULL_BASE_REF}"}
log "INFO This PR's base branch is $release"

# See if we need to get release from the release repo.
if [[ "$release" == "main" || "$release" == "master" ]]; then
    log "INFO Current PR is against the $release branch."
    log "INFO Need to get current release version from release repo at $release_url"
    release_dir="${ocm_dir}/release"
    git clone "$release_url" "$release_dir" || {
        log "ERROR Could not clone release repo $release_url"
        exit 1
    }
    if [[ "${PRODUCT_PREFIX}" == "release" ]]; then
        release=$(cat "${release_dir}/CURRENT_RELEASE")
    else
        release="$(git -C ${release_dir} remote show origin | grep -o "${PRODUCT_PREFIX}-[0-9]\+\.[0-9]\+" | sort -V | tail -1)"
    fi
    log "INFO Branch from CURRENT_RELEASE is $release"
fi

# Validate release branch. We can only run on release-x.y branches.
if [[ ! "$release" =~ ^${PRODUCT_PREFIX}-[0-9]+\.[0-9]+$ ]]; then
    log "ERROR Branch ($release) is not a release branch."
    log "Base branch of PR must match ${PRODUCT_PREFIX}-x.y"
    exit 1
fi

# Trim "release-" prefix.
release=${release#${PRODUCT_PREFIX}-}

PIPELINE_STAGE=${PIPELINE_STAGE:-"dev"}

# Get pipeline branch.
pipeline_branch="${release}-${PIPELINE_STAGE}"

# Clone pipeline repo.
log "Cloning pipeline repo at branch $pipeline_branch"
pipeline_dir="${ocm_dir}/pipeline"
git clone -b "$pipeline_branch" "$pipeline_url" "$pipeline_dir" || {
    log "ERROR Could not clone branch $pipeline_branch from pipeline repo $pipeline_url"
    exit 1
}

# Get latest snapshot.
log "Getting latest snapshot for $pipeline_branch"
snapshot_dir="$pipeline_dir/snapshots"
cd "$snapshot_dir" || exit 1
manifest_file=$(find . -maxdepth 1 -name 'manifest-*' | sort | tail -n 1)
manifest_file="${manifest_file#./}"
if [[ -z "$manifest_file" ]]; then
    log "ERROR no manifest file found in pipeline/snapshots"
    log "Contents of pipeline/snapshots"
    ls "$snapshot_dir" > >(tee -a "$log_file")
    exit 1
fi

log "Using manifest file name: $manifest_file"

# Trim manifest file name
manifest=${manifest_file#manifest-}
manifest=${manifest%.json}

# Get timestamp from manifest name.
timestamp=$(sed -E 's/-[[:digit:].]+$//' <<< "$manifest")
log "Using timestamp: $timestamp"

# Get version from manifest file name.
version=$(sed -E 's/^[[:digit:]]{4}(-[[:digit:]]{2}){5}-//' <<< "$manifest")
log "Using version: $version"

# Get snapshot.
snapshot="${version}-SNAPSHOT-${timestamp}"
log "Using snapshot: $snapshot"

# Return to work directory.
cd "$ocm_dir" || exit 1

# See if COMPONENT_NAME was provided.
log "Checking COMPONENT_NAME"
if [[ "$SKIP_COMPONENT_INSTALL" == "false" ]]; then
    if [[ -z "$COMPONENT_NAME" ]]; then
        # It wasn't, so get it from the COMPONENT_NAME file in the COMPONENT_REPO
    
        # Clone the COMPONENT_REPO
        log ">>> COMPONENT_NAME not provided. Getting it from $COMPONENT_REPO"
        component_dir="${ocm_dir}/component"
        git clone -b "${PULL_BASE_REF}" "$component_url" "$component_dir" || {
            log "ERROR Could not clone branch ${PULL_BASE_REF} of component repo $component_url"
            exit 1
        }
    
        # Verify COMPONENT_NAME file exists
        component_name_file="${component_dir}/COMPONENT_NAME"
        if [[ ! -r "$component_name_file" ]]; then
            log "ERROR COMPONENT_NAME file does not exist in branch ${PULL_BASE_REF} of component repo $component_url"
            exit 1
        fi
    
        # Get COMPONENT_NAME
        COMPONENT_NAME=$(cat "$component_name_file")
        if [[ -z "$COMPONENT_NAME" ]]; then
            log "ERROR COMPONENT_NAME file was empty in branch ${PULL_BASE_REF} of component repo $component_url"
            exit 1
        fi
    fi
    
    log ">>> Using COMPONENT_NAME: $COMPONENT_NAME"
    # Verify COMPONENT_NAME is in the manifest file
    log ">>> Verifying COMPONENT_NAME is in the manifest file"
    image_name_query=".[] | select(.[\"image-name\"]==\"${COMPONENT_NAME}\")"
    IMAGE_NAME=$(jq -r "$image_name_query" "$snapshot_dir/$manifest_file" 2> >(tee -a "$log_file"))
    if [[ -z "$IMAGE_NAME" ]]; then
        log "ERROR Could not find image $COMPONENT_NAME in manifest $manifest_file"
        log "Contents of manifest $manifest_file"
        cat "$manifest_file" > >(tee -a "$log_file")
        exit 1
    fi
    IMAGE_NAME="$COMPONENT_NAME"
    log ">>> Using IMAGE_NAME: $IMAGE_NAME"
    IMAGE_QUERY="quay.io/stolostron/${IMAGE_NAME}@sha256:[[:alnum:]]+"
    log ">>> Using IMAGE_QUERY: $IMAGE_QUERY"
else
    log ">>> Skipping since we're not installing a component."
fi

# Set up Quay credentials.
log "Setting up Quay credentials."
if [[ ! -r "${QUAY_TOKEN_FILE}" ]]; then
    log "ERROR Quay token file missing or not readable: $QUAY_TOKEN_FILE"
    exit 1
fi
QUAY_TOKEN=$(cat "$QUAY_TOKEN_FILE")

# Set up additional deploy variables
NAMESPACE=open-cluster-management
CATALOG_NAMESPACE=openshift-marketplace
OPERATOR_DIR=acm-operator

# Function to deploy ACM to a cluster.
# The first parameter is the cluster name without the suffix.
deploy() {
    local _cluster="$1"
    local _log="${ARTIFACT_DIR}/deploy-${_cluster}.log"
    local _status="${ARTIFACT_DIR}/deploy-${_cluster}.status"
    local _kc="${SHARED_DIR}/${_cluster}.kc"

    # Cloning deploy repo
    logf "$_log" "Deploy $_cluster: Cloning deploy repo"
    echo "CLONE" > "${_status}"
    local _deploy_dir="${ocm_dir}/deploy-$_cluster"
    git clone "$deploy_url" "$_deploy_dir" > >(tee -a "$_log") 2>&1 || {
        logf "$_log" "ERROR Deploy $_cluster: Could not clone deploy repo"
        echo "ERROR CLONE" > "${_status}"
        return 1
    }

    echo "CHANGE_DIR" > "${_status}"
    cd "$_deploy_dir" || return 1

    # Save snapshot version
    logf "$_log" "Deploy $_cluster: Using snapshot $snapshot"
    echo "SNAPSHOT" > "${_status}"
    echo "$snapshot" > snapshot.ver

    # Test cluster connection
    logf "$_log" "Deploy $_cluster: Waiting up to 2 minutes to connect to cluster"
    echo "WAIT_CONNECT" > "${_status}"
    local _timeout=120 _elapsed='' _step=10
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        KUBECONFIG="$_kc" oc project > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: Connected to cluster after ${_elapsed}s"
            break
        }

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) connecting to cluster"
                echo "ERROR WAIT_CONNECT" > "${_status}"
                return 1
        fi

        logf "$_log" "WARN Deploy $_cluster: Could not connect to cluster. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Generate YAML files
    logf "$_log" "Deploy $_cluster: Waiting up to 2 minutes for start.sh to generate YAML files"
    echo "WAIT_YAML" > "${_status}"
    local _timeout=120 _elapsed='' _step=10
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        DEBUG="$ACM_DEPLOY_DEBUG" KUBECONFIG="$_kc" QUAY_TOKEN="$QUAY_TOKEN" ./start.sh --silent -t \
            > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: start.sh generated YAML files after ${_elapsed}s"
            break
        }

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting for start.sh to generate YAML files"
                echo "ERROR WAIT_YAML" > "${_status}"
                return 1
        fi

        logf "$_log" "WARN Deploy $_cluster: Could not create YAML files. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Create namespace
    logf "$_log" "Deploy $_cluster: Creating namespace $NAMESPACE"
    echo "NAMESPACE" > "${_status}"
    KUBECONFIG="$_kc" oc create ns $NAMESPACE \
        > >(tee -a "$_log") 2>&1 || {
        logf "$_log" "ERROR Deploy $_cluster: Error creating namespace $NAMESPACE"
        echo "ERROR NAMESPACE" > "${_status}"
        return 1
    }

    # Wait for namespace 
    logf "$_log" "Deploy $_cluster: Waiting up to 2 minutes for namespace $NAMESPACE"
    echo "WAIT_NAMESPACE" > "${_status}"
    local _timeout=120 _elapsed='' _step=10
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        # Check for namespace to be created.
        KUBECONFIG="$_kc" oc get ns $NAMESPACE -o name > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: Namespace $NAMESPACE created after ${_elapsed}s"
            break
        }

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting for namespace $NAMESPACE to be created."
                echo "ERROR WAIT_NAMESPACE" > "${_status}"
                return 1
        fi

        logf "$_log" "WARN Deploy $_cluster: Namespace not yet created. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Apply YAML files in prereqs directory
    logf "$_log" "Deploy $_cluster: Waiting up to 5 minutes to apply YAML files from prereqs directory"
    echo "WAIT_APPLY_PREREQS" > "${_status}"
    local _timeout=300 _elapsed='' _step=15
    local _mch_name='' _mch_status=''
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        KUBECONFIG="$_kc" oc -n $NAMESPACE apply --openapi-patch=true -k prereqs/ \
            > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: YAML files from prereqs directory applied to $NAMESPACE after ${_elapsed}s"
        }

        KUBECONFIG="$_kc" oc -n $CATALOG_NAMESPACE apply --openapi-patch=true -k prereqs/ \
            > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: YAML files from prereqs directory applied to $CATALOG_NAMESPACE after ${_elapsed}s"
            break
        }

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting to apply prereq YAML files"
                echo "ERROR WAIT_APPLY_PREREQS" > "${_status}"
                return 1
        fi

        logf "$_log" "WARN Deploy $_cluster: Unable to apply YAML files from prereqs directory. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Apply YAML files in multicluster hub operator directory
    logf "$_log" "Deploy $_cluster: Waiting up to 5 minutes to apply YAML files from MCH operator directory"
    echo "WAIT_APPLY_MCHO" > "${_status}"
    local _timeout=300 _elapsed='' _step=15
    local _mch_name='' _mch_status=''
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        KUBECONFIG="$_kc" oc -n $NAMESPACE apply -k "${OPERATOR_DIR}/" \
            > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: YAML files from MCH operator directory applied after ${_elapsed}s"
            break
        }

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting to apply MCH operator YAML files"
                echo "ERROR WAIT_APPLY_MCHO" > "${_status}"
                return 1
        fi

        logf "$_log" "WARN Deploy $_cluster: Unable to apply YAML files from MCH operator directory. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Wait for MCH pod
    logf "$_log" "Deploy $_cluster: Waiting up to 5 minutes for multiclusterhub-operator pod"
    echo "WAIT_MCHO" > "${_status}"
    local _timeout=300 _elapsed='' _step=15
    local _mcho_name='' _path='' _total='' _ready=''
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            logf "$_log" "INFO Deploy $_cluster: Setting elapsed time to 0"
            _elapsed=0
        else
            logf "$_log" "INFO Deploy $_cluster: Sleeping for $_step s"
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi
        logf "$_log" "INFO Deploy $_cluster: Elapsed time is ${_elapsed}/${_timeout}s"

        # Check timeout
        logf "$_log" "INFO Deploy $_cluster: Checking for timeout."
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting for multiclusterhub-operator pod"
                echo "ERROR WAIT_MCHO" > "${_status}"
                return 1
        fi

        # Get pod names
        logf "$_log" "INFO Deploy $_cluster: Getting pod names."
        KUBECONFIG="$_kc" oc -n $NAMESPACE get pods -o name > pod_names 2> >(tee -a "$_log") || {
            logf "$_log" "WARN Deploy $_cluster: Failed to get pod names. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }
        logf "$_log" "INFO Deploy $_cluster: Current pod names:"
        cat pod_names > >(tee -a "$_log") 2>&1

        # Check for multiclusterhub-operator pod name
        logf "$_log" "INFO Deploy $_cluster: Checking for multiclusterhub-operator pod."
        if ! grep -E --max-count=1 "^pod/multiclusterhub-operator(-[[:alnum:]]+)+$" pod_names > mcho_name 2> /dev/null ; then
            logf "$_log" "WARN Deploy $_cluster: multiclusterhub-operator pod not created yet. Will retry (${_elapsed}/${_timeout}s)"
            continue
        fi
        logf "$_log" "INFO Deploy $_cluster: MCHO pod name:"
        cat mcho_name > >(tee -a "$_log") 2>&1

        _mcho_name=$(cat mcho_name 2> /dev/null)
        logf "$_log" "INFO Deploy $_cluster: Found MCHO pod: '$_mcho_name'"

        # Get IDs of all containers in MCH pod.
        logf "$_log" "INFO Deploy $_cluster: Getting IDs of all containers in MCH-O pod $_mcho_name"
        _path='{range .status.containerStatuses[*]}{@.containerID}{"\n"}{end}'
        KUBECONFIG="$_kc" oc -n $NAMESPACE get "$_mcho_name" \
            -o jsonpath="$_path" > total_containers 2> >(tee -a "$_log") || {
            logf "$_log" "WARN Deploy $_cluster: Failed to get all container IDs. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        # Get IDs of all ready containers in MCH pod.
        logf "$_log" "INFO Deploy $_cluster: Getting IDs of all ready containers in MCH-O pod $_mcho_name"
        _path='{range .status.containerStatuses[?(@.ready==true)]}{@.containerID}{"\n"}{end}'
        KUBECONFIG="$_kc" oc -n $NAMESPACE get "$_mcho_name" \
            -o jsonpath="$_path" > ready_containers 2> >(tee -a "$_log") || {
            logf "$_log" "WARN Deploy $_cluster: Failed to get all ready container IDs. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        # Check if all containers are ready.
        logf "$_log" "INFO Deploy $_cluster: Checking if all containers are ready in MCH-O pod."
        _total=$(wc -l < total_containers) # redirect into wc so it doesn't print file name as well
        _ready=$(wc -l < ready_containers)
        if (( _total > 0 && _ready == _total )); then
            logf "$_log" "Deploy $_cluster: multiclusterhub-operator pod is ready after ${_elapsed}s"
            break
        fi

        logf "$_log" "WARN Deploy $_cluster: Not all containers ready ($_ready/$_total). Will retry (${_elapsed}/${_timeout}s)"
    done

    # Apply YAML files in DEPLOY_HUB_ADDITIONAL_YAML environment variable
    logf "$_log" "Deploy $_cluster: Checking DEPLOY_HUB_ADDITIONAL_YAML environment variable"
    echo "CHECK_ADDITIONAL_YAML" > "${_status}"
    if [[ -z "$DEPLOY_HUB_ADDITIONAL_YAML" ]]; then
        logf "$_log" "Deploy $_cluster: .... DEPLOY_HUB_ADDITIONAL_YAML is empty."
    else
        logf "$_log" "Deploy $_cluster: .... decoding DEPLOY_HUB_ADDITIONAL_YAML"
        echo "DECODE_ADDITIONAL_YAML" > "${_status}"
        cat <<<"$DEPLOY_HUB_ADDITIONAL_YAML" | base64 -d > additional.yaml 2> >(tee -a "$_log") || {
            logf "$_log" "ERROR Deploy $_cluster: Unable to decode contents of DEPLOY_HUB_ADDITIONAL_YAML variable"
            echo "ERROR DECODE_ADDITIONAL_YAML" > "${_status}"
            return 1
        }
        logf "$_log" "Deploy $_cluster: Wait up to 5 minutes to apply YAML files from DEPLOY_HUB_ADDITIONAL_YAML environment variable"
        echo "WAIT_APPLY_ADDITIONAL_YAML" > "${_status}"
        local _timeout=300 _elapsed='' _step=15
        local _mch_name='' _mch_status=''
        while true; do
            # Wait for _step seconds, except for first iteration.
            if [[ -z "$_elapsed" ]]; then
                _elapsed=0
            else
                sleep $_step
                _elapsed=$(( _elapsed + _step ))
            fi
    
            KUBECONFIG="$_kc" oc -n $NAMESPACE apply -f additional.yaml \
                > >(tee -a "$_log") 2>&1 && {
                logf "$_log" "Deploy $_cluster: Additional YAML files applied after ${_elapsed}s"
                break
            }
    
            # Check timeout
            if (( _elapsed > _timeout )); then
                    logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting to apply additional YAML files"
                    echo "ERROR WAIT_APPLY_ADDITIONAL_YAML" > "${_status}"
                    return 1
            fi
    
            logf "$_log" "WARN Deploy $_cluster: Unable to apply additional YAML files. Will retry (${_elapsed}/${_timeout}s)"
        done
    fi

    # Wait for ClusterServiceVersion
    logf "$_log" "Deploy $_cluster: Waiting up to 10 minutes for CSV"
    echo "WAIT_CSV_1" > "${_status}"
    local _timeout=600 _elapsed='' _step=15
    local _csv_name='' _csv_status=''
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting for CSV"
                echo "ERROR WAIT_CSV_1" > "${_status}"
                return 1
        fi

        # Get CSV name
        KUBECONFIG="$_kc" oc -n $NAMESPACE get csv -o name > csv_name 2> >(tee -a "$_log") || {
            logf "$_log" "WARN Deploy $_cluster: Error getting CSV name. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        # Check that CSV name isn't empty
        _csv_name=$(cat csv_name)
        if [[ -z "$_csv_name" ]]; then
            logf "$_log" "WARN Deploy $_cluster: CSV not created yet. Will retry (${_elapsed}/${_timeout}s)"
            continue
        fi

        # Get CSV status
        KUBECONFIG="$_kc" oc -n $NAMESPACE get "$_csv_name" \
            -o json > csv.json 2> >(tee -a "$_log") || {
            logf "$_log" "WARN Deploy $_cluster: Error getting CSV status. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        # Check CSV status
        _csv_status=$(jq -r .status.phase csv.json 2> >(tee -a "$_log"))
        case "$_csv_status" in
            Failed)
                logf "$_log" "ERROR Deploy $_cluster: Error CSV install failed after ${_elapsed}s"
                local _msg
                _msg=$(jq -r .status.message csv.json 2> >(tee -a "$_log"))
                logf "$_log" "ERROR Deploy $_cluster: Error message: $_msg"
                logf "$_log" "ERROR Deploy $_cluster: Full CSV"
                jq . csv.json > >(tee -a "$_log") 2>&1
                echo "ERROR WAIT_CSV_1" > "$_status"
                return 1
                ;;
            Succeeded)
                logf "$_log" "Deploy $_cluster: CSV is ready after ${_elapsed}s"
                break
                ;;
        esac

        logf "$_log" "WARN Deploy $_cluster: Current CSV status is $_csv_status. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Check if we're installing a dev component
    if [[ "$SKIP_COMPONENT_INSTALL" == "false" ]]; then
        # Update CSV
        logf "$_log" "Deploy $_cluster: Updating CSV"
        echo "UPDATE_CSV" > "${_status}"
        # Rewrite CSV. CSV contents are in csv.json
        sed -E "s,$IMAGE_QUERY,$COMPONENT_IMAGE_REF," csv.json > csv_update.json 2> >(tee -a "$_log")
        jq 'del(.metadata.uid) | del(.metadata.resourceVersion)' csv_update.json > csv_clean.json 2> >(tee -a "$_log")
        # Replace CSV on cluster
        KUBECONFIG="$_kc" oc -n $NAMESPACE replace -f csv_clean.json > >(tee -a "$_log") 2>&1 || {
            logf "$_log" "ERROR Deploy $_cluster: Failed to update CSV."
            logf "$_log" "ERROR Deploy $_cluster: New CSV contents"
            jq . csv_clean.json > >(tee -a "$_log") 2>&1
            echo "ERROR_UPDATE_CSV" > "$_status"
            return 1
        }
    
        # Wait for ClusterServiceVersion
        logf "$_log" "Deploy $_cluster: Waiting up to 10 minutes for CSV"
        echo "WAIT_CSV_2" > "${_status}"
        local _timeout=600 _elapsed=0 _step=15
        local _csv_name='' _csv_status=''
        while true; do
            # Wait for _step seconds, including first iteration
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
    
            # Check timeout
            if (( _elapsed > _timeout )); then
                    logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting for CSV"
                    echo "ERROR WAIT_CSV_2" > "${_status}"
                    return 1
            fi
    
            # Get CSV name
            KUBECONFIG="$_kc" oc -n $NAMESPACE get csv -o name > csv_name 2> >(tee -a "$_log") || {
                logf "$_log" "WARN Deploy $_cluster: Error getting CSV name. Will retry (${_elapsed}/${_timeout}s)"
                continue
            }
    
            # Check that CSV name isn't empty
            _csv_name=$(cat csv_name)
            if [[ -z "$_csv_name" ]]; then
                logf "$_log" "WARN Deploy $_cluster: CSV not created yet. Will retry (${_elapsed}/${_timeout}s)"
                continue
            fi
    
            # Get CSV status
            KUBECONFIG="$_kc" oc -n $NAMESPACE get "$_csv_name" \
                -o json > csv.json 2> >(tee -a "$_log") || {
                logf "$_log" "WARN Deploy $_cluster: Error getting CSV status. Will retry (${_elapsed}/${_timeout}s)"
                continue
            }
    
            # Check CSV status
            _csv_status=$(jq -r .status.phase csv.json 2> >(tee -a "$_log"))
            case "$_csv_status" in
                Failed)
                    logf "$_log" "ERROR Deploy $_cluster: Error CSV install failed after ${_elapsed}s"
                    local _msg
                    _msg=$(jq -r .status.message csv.json 2> >(tee -a "$_log"))
                    logf "$_log" "ERROR Deploy $_cluster: Error message: $_msg"
                    logf "$_log" "ERROR Deploy $_cluster: Full CSV"
                    jq . csv.json > >(tee -a "$_log") 2>&1
                    echo "ERROR WAIT_CSV_2" > "$_status"
                    return 1
                    ;;
                Succeeded)
                    logf "$_log" "Deploy $_cluster: CSV is ready after ${_elapsed}s"
                    break
                    ;;
            esac
    
            logf "$_log" "WARN Deploy $_cluster: Current CSV status is $_csv_status. Will retry (${_elapsed}/${_timeout}s)"
        done
    else
        logf "$_log" "Deploy $_cluster: Skipping updating CSV as we're not installing a dev component"
    fi

    # Apply YAML files in multicluster hub directory
    logf "$_log" "Deploy $_cluster: Wait up to 5 minutes to apply YAML files from MCH directory"
    echo "WAIT_APPLY_MCH" > "${_status}"
    local _timeout=300 _elapsed='' _step=15
    local _mch_name='' _mch_status=''
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        KUBECONFIG="$_kc" oc -n $NAMESPACE apply -k applied-mch/ \
            > >(tee -a "$_log") 2>&1 && {
            logf "$_log" "Deploy $_cluster: MCH YAML files applied after ${_elapsed}s"
            break
        }

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting to apply MCH YAML files"
                echo "ERROR WAIT_APPLY_MCH" > "${_status}"
                return 1
        fi

        logf "$_log" "WARN Deploy $_cluster: Unable to apply YAML files from MCH directory. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Wait for MultiClusterHub CR to be ready
    logf "$_log" "Deploy $_cluster: Waiting up to 15 minutes for MCH CR"
    echo "WAIT_MCH" > "${_status}"
    local _timeout=900 _elapsed='' _step=15
    local _mch_name='' _mch_status=''
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Timeout (${_timeout}s) waiting for MCH CR"
                echo "ERROR WAIT_MCH" > "${_status}"
                return 1
        fi

        # Get MCH name
        KUBECONFIG="$_kc" oc -n $NAMESPACE get multiclusterhub -o name 2> >(tee -a "$_log") > mch_name || {
            logf "$_log" "WARN Deploy $_cluster: Error getting MCH name. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        # Check that MCH name isn't empty
        _mch_name=$(cat mch_name)
        logf "$_log" "Deploy $_cluster: Found MCH name '$_mch_name'"
        if [[ -z "$_mch_name" ]]; then
            logf "$_log" "WARN Deploy $_cluster: MCH not created yet. Will retry (${_elapsed}/${_timeout}s)"
            continue
        fi

        # Get MCH status
        KUBECONFIG="$_kc" oc -n $NAMESPACE get "$_mch_name" \
            -o json 2> >(tee -a "$_log") > mch.json || {
            logf "$_log" "WARN Deploy $_cluster: Error getting MCH status. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        # Check MCH status
        jq -r '.status.phase' mch.json 2> >(tee -a "$_log") >/dev/null || {
            logf "$_log" "WARN Encountered unexpected error parsing MCH JSON. Will retry (${_elapsed}/${_timeout}s)"
            continue
        }

        _mch_status=$(jq -r '.status.phase' mch.json 2> >(tee -a "$_log"))
        if [[ "$_mch_status" == "Running" ]]; then
            logf "$_log" "Deploy $_cluster: MCH CR is ready after ${_elapsed}s"
            break
        fi

        logf "$_log" "WARN Deploy $_cluster: Current MCH status is $_mch_status. Will retry (${_elapsed}/${_timeout}s)"
    done

    # Done
    logf "$_log" "Deploy $_cluster: Deployment complete."
    echo "OK" > "${_status}"
    return 0
}

# Function to start an ACM deployment in parallel. The first argument is the
# timeout in seconds to wait. The second parameter is the name of the cluster.
#
# This function uses mostly shell built-ins to minimize forking processes.
# Based on this Stack Overflow comment:
# https://stackoverflow.com/a/50436152/1437822
#
deploy_with_timeout() {
    # Store the timeout and cluster name.
    local _timeout=$1
    local _cluster=$2
    local _step=5
    # Execute the command in the background.
    deploy "$_cluster" &
    # Store the PID of the command in the background.
    local _pid=$!
    # Start the elapsed count.
    local _elapsed=0
    # Check if the command is still running.
    # kill -0 $_pid returns
    #   exit code 0 if the command is running, but does not affect the command
    #   exit code 1 if the command is not running
    while kill -0 $_pid >/dev/null 2>&1 ; do
        # command is still running. wait _step seconds
        sleep $_step
        # increment elapsed time
        _elapsed=$(( _elapsed + _step ))
        # Check if timeout has been reached.
        if (( _elapsed >= _timeout )); then 
            log "Deploy $_cluster: Killing pid $_pid due to timeout (${_elapsed}/${_timeout}s)"
            # Update status
            echo "TIMEOUT at $(date --iso-8601=seconds)" > "${_cluster}.status"
            # Kill deployment
            kill $_pid >/dev/null 2>&1
            break
        fi
    done
    log "Deploy $_cluster: Deployment pid $_pid exited (${_elapsed}/${_timeout}s)"
}

# Function to gracefully terminate deployments if main script exits
_exit() {
    log "TERMINATE Main script caught an exit signal."
    log "Stopping all deployments."
    kill "$(pgrep -P $$)" >/dev/null 2>&1
}

# Array to store PIDs of deploy processes.
waitgroup=()

# Start a deployment for each cluster
for cluster in "${clusters[@]}"; do
    log "Deploy $cluster: Starting deployment."
    deploy_with_timeout "$DEPLOY_TIMEOUT" "$cluster" &
    pid=$!
    waitgroup+=("$pid")
    log "Deploy $cluster: Started with pid $pid"
done

# Enable trap on EXIT to stop deployments.
trap _exit EXIT

# Wait for deployments to finish.
wait "${waitgroup[@]}"

# Done waiting. Disable EXIT trap.
trap - EXIT

# Check status of all deployments.
log "Deployments done. Checking status."
err=0
for cluster in "${clusters[@]}"; do
    status="${ARTIFACT_DIR}/deploy-$cluster.status"
    if [[ ! -r "$status" ]]; then
        log "Cluster $cluster: ERROR No status file: $status"
        log "Cluster $cluster: See cluster deploy log file (deploy-$cluster.log) for more details."
        err=$(( err + 1 ))
        continue
    fi
    
    status=$(cat "$status")
    if [[ "$status" != OK ]]; then
        log "Cluster $cluster: ERROR Failed with status: $status"
        log "Cluster $cluster: See cluster deploy log file (deploy-$cluster.log) for more details."
        err=$(( err + 1 ))
    fi
done

# Throw error if any deployments failed.
if [[ $err -gt 0 ]]; then
    log "ERROR One or more failed deployments."
    exit 1
fi

log "Deployments complete."

donotuse() {
    # Do X
    logf "$_log" "Deploy $_cluster: Doing X"
    echo "X" > "${_status}"
    KUBECONFIG="$_kc" oc -n $NAMESPACE \
        > >(tee -a "$_log") 2>&1 || {
        logf "$_log" "ERROR Deploy $_cluster: Error doing X"
        echo "ERROR X" > "${_status}"
        return 1
    }

    # Wait for X
    logf "$_log" "Deploy $_cluster: Waiting up to N minutes for X"
    echo "WAIT_X" > "${_status}"
    local _timeout=600 _elapsed='' _step=15
    while true; do
        # Wait for _step seconds, except for first iteration.
        if [[ -z "$_elapsed" ]]; then
            _elapsed=0
        else
            sleep $_step
            _elapsed=$(( _elapsed + _step ))
        fi

        # Check timeout
        if (( _elapsed > _timeout )); then
                logf "$_log" "ERROR Deploy $_cluster: Error waiting for X"
                echo "ERROR WAIT_X" > "${_status}"
                return 1
        fi

        # Do X
        KUBECONFIG="$_kc" oc -n open-cluster-management 2> >(tee -a "$_log") && break

        logf "$_log" "WARN Deploy $_cluster: Failed to do X. Will retry."
    done
}
