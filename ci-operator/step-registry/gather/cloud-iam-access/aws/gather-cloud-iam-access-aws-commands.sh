#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
#set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# attemps to collect events only if job is running with custom IAM User
if [ "${AWS_INSTALL_USE_CUSTOM_IDENTITY-}" != "yes" ];
then
	echo "Skipping step as custom IAM identity is not enabled. AWS_INSTALL_USE_CUSTOM_IDENTITY=[${AWS_INSTALL_USE_CUSTOM_IDENTITY-}]"
	exit 0
fi

# Check if custom user name has been set, otherwise fail.
if [ ! -f "${SHARED_DIR}/aws_user_names" ];
then
	echo "Flag AWS_INSTALL_USE_CUSTOM_IDENTITY is enabled but no custom user name has been found. Check if step aws-provision-iam-user has been succeeded."
	exit 1
fi

# Check if the control file with timestamp of user creation has been created, otherwise fail.
if [ ! -f "${SHARED_DIR}/time_iam_created" ];
then
	echo "Unable to find timestamp that custom IAM user has been created. Check if step aws-provision-iam-user has been succeeded."
	exit 1
fi

if [ -z "${CLUSTER_NAME-}" ];
then
	export CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name" 2>/dev/null || true)
	if [ -z "${CLUSTER_NAME}" ];
	then
		export CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
		if [ -z "${CLUSTER_NAME}" ];
		then
			echo "Unable to find CLUSTER_NAME from: 1) control file \${SHARED_DIR}/cluster_name, 2) global variables NAMESPACE-UNIQUE_HASH=[${NAMESPACE}-${UNIQUE_HASH}]"
			exit 1
		else
			echo "Setting CLUSTER_NAME from global variables NAMESPACE-UNIQUE_HASH=[${NAMESPACE}-${UNIQUE_HASH}]"
		fi
	else
		echo "Setting CLUSTER_NAME from control file \${SHARED_DIR}/cluster_name"
	fi
fi

if [ -z "${LEASED_RESOURCE-}" ];
then
	export LEASED_RESOURCE=$(<"${SHARED_DIR}"/LEASED_RESOURCE || true)
	if [ -z "${LEASED_RESOURCE}" ];
	then
		echo "Unable to locate LEASED_RESOURCE"
		exit 1
	fi
fi


function log_msg() {
	echo -e "$(date -u --rfc-3339=seconds)> $*"
}

#
# Globals
#
EVENT_WORKDIR=/tmp/iam-events-"${CLUSTER_NAME}"
EVENTS_PATH_RAW=${EVENT_WORKDIR}/objects
EVENTS_PATH_PARSED=${EVENT_WORKDIR}/parsed
CREDS_REQ_PATH=${EVENT_WORKDIR}/credrequests
CREDS_REQ_PATH_RAW=${EVENT_WORKDIR}/credrequests-raw

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

DATETIME_FORMAT="%Y-%m-%dT%H:%M:%SZ"
DATETIME_NOW="$(date -u +"${DATETIME_FORMAT}")"
GATHER_EVENT_START_TIME="$(<"${SHARED_DIR}"/time_iam_created)"
GATHER_EVENT_END_TIME=${GATHER_EVENT_END_TIME:-${DATETIME_NOW}}
# Collect items no more than 30' than the end.
GATHER_EVENT_END_LIMIT_TIME="$(date -ud "${GATHER_EVENT_END_TIME} +30 minutes" +"${DATETIME_FORMAT}")"

ACCOUNT_ID="$(aws sts get-caller-identity | jq -r .Account)"

#FILE_PREFIX="${ACCOUNT_ID}_CloudTrail_${JOB_REGION}"
OBJECTS_PREFIX="AWSLogs/${ACCOUNT_ID}/CloudTrail/${LEASED_RESOURCE}"
OBJECTS_PREFIX_START="${OBJECTS_PREFIX}/$(date -ud "${GATHER_EVENT_START_TIME}" +%Y/%m)"

#
# Init event discovery
#
log_msg "Starting event gathering with timestamps: "
echo "start=[${GATHER_EVENT_START_TIME}] end=[${GATHER_EVENT_END_TIME}] limit=[${GATHER_EVENT_END_LIMIT_TIME}]"

mkdir -pv "${EVENTS_PATH_RAW}" || true
# Time control. (change only when you are observed fatest data available on s3)
GATHER_THRESHOLD=0
GATHER_COUNT=0
RETRY_LIMIT=15

RETRY_INTERVAL_SEC=60
while true; do
	GATHER_THRESHOLD=$((GATHER_THRESHOLD+1))
	GATHER_COUNT=$((GATHER_COUNT+1))

	# Force timeout. It must be aligned with step timeout (do we need this?)
	if [ "${GATHER_COUNT}" -ge 30 ]; then
		log_msg "ERROR no more events after timeout, starting processor"
		exit 1
	fi
	# RETRY_LIMIT ensures stop after no event was found in RETRY_LIMIT*RETRY_INTERVAL_SEC.
	# CloudTrail process the audit logs in batch in background, saving in chunks of files
	# of 5 minutes on a S3 Bucket. Each chunk can have api calls of 10 minutes or more before
	# the data is available.
	if [ "${GATHER_THRESHOLD}" -gt ${RETRY_LIMIT} ]; then
		log_msg "WARN no more events after timeout, starting processor"
		break
	fi

	log_msg "Collecting archives between ${GATHER_EVENT_START_TIME} and ${GATHER_EVENT_END_LIMIT_TIME} for cluster ${CLUSTER_NAME}"
	aws s3api list-objects-v2 \
		--bucket "${AWS_TRAIL_BUCKET_NAME}" \
		--prefix "${OBJECTS_PREFIX_START}" \
		--query 'Contents[?LastModified >= `'"${GATHER_EVENT_START_TIME}"'` && LastModified <= `'"${GATHER_EVENT_END_LIMIT_TIME}"'`]' \
		> "${EVENTS_PATH_RAW}"-metadata

	found=$(jq -r '.|length' "${EVENTS_PATH_RAW}"-metadata)
	if [[ ${found} -eq 0 ]]; then
		log_msg "Found 0 event, waiting ${RETRY_INTERVAL_SEC}s for next iteration [${GATHER_THRESHOLD}/${RETRY_LIMIT}]";
		sleep ${RETRY_INTERVAL_SEC};
		continue
	fi
	log_msg "Found [$(jq -r '.|length' "${EVENTS_PATH_RAW}"-metadata)] archive files with events"
	skips=0
	for obKey in $(jq -r .[].Key "${EVENTS_PATH_RAW}"-metadata); do
		objName=$(basename "${obKey}")
		# syncronize only if event archive wasn't downloaded yet
		if [[ ! -f ${EVENTS_PATH_RAW}/${objName} ]]; then
			echo "Downloading archive ${objName//${ACCOUNT_ID}/XXXXXXXXXXXX}"
			aws s3 cp s3://"${AWS_TRAIL_BUCKET_NAME}"/"${obKey}" "${EVENTS_PATH_RAW}"/ >/dev/null
		else
			skips=$((skips+1))
		fi
	done
	if [ $skips -gt 0 ]; then log_msg "Skipped $skips files"; fi

	log_msg "Checking timestamp of the first record"
	LOG_INITIAL_EVENT=$(zcat "${EVENTS_PATH_RAW}"/* | jq -r '.Records[].eventTime'| sort -n | head -n1 || true)

	log_msg "Checking timestamp of the last record"
	LOG_LATEST_EVENT=$(zcat "${EVENTS_PATH_RAW}"/* | jq -r '.Records[].eventTime'| sort -n | tail -n1 || true)

	log_msg "Checking total events"
	LOG_COUNT_EVENTS=$(zcat "${EVENTS_PATH_RAW}"/* | jq -r .Records[].eventTime | wc -l || true)

	log_msg "Found events: initial=[${LOG_INITIAL_EVENT}] final=[${LOG_LATEST_EVENT}] count=[${LOG_COUNT_EVENTS}] files=[${found}]"

	# General flow
	# t0: create custom IAM user
	# t1: regular job flow (install, run e2e, destroy)
	# t2: delete user
	# t3: gather started
	# We want the events between t0-t2, Although CloudTrail would take 10-12 minutes to deliver the events
	# to AWS S3 Bucket. We need to make sure we'll not lost events, so we want to collect up to 15 minutes after the
	# t2 (it may not incurr more costs as:
	#  A) infra is already deleted;
	#  B) S3 API prevents to retrieve objects (only metadata);
	#  C) downloaded objects will be skipped.

	# Skip increment when latest event isn't is the final timestamp
	if [ "$(date -ud "${LOG_LATEST_EVENT}" +%s)" -le "$(date -ud "${GATHER_EVENT_END_TIME}" +%s)" ];
	then
		log_msg "Latest[${LOG_LATEST_EVENT}] event is older than the desired[${GATHER_EVENT_END_TIME}]"
		GATHER_THRESHOLD=0
	elif [ "$(date -ud "${LOG_LATEST_EVENT}" +%s)" -gt "$(date -ud "${GATHER_EVENT_END_TIME}" +%s)" ];
	then
		log_msg "Found event(s) with timestamp newer than desired: [${LOG_LATEST_EVENT}], unblocking threshold [${GATHER_THRESHOLD}/${RETRY_LIMIT}]"
	else
		log_msg "No event found. Retrieving later until timeout."
	fi
	# Is there a condition to leave the loop safety - without losing data?

	log_msg "Pausing ${RETRY_INTERVAL_SEC} seconds before checking latest events. [${GATHER_COUNT}/${GATHER_THRESHOLD}/${RETRY_LIMIT}]"
	sleep ${RETRY_INTERVAL_SEC}
done

# TODO/Q: should we need to check if there are 0 events when expected to have, then fail?


#
# Download cci (cloud credentials insights)
#
# TODO(mtulio): define where to save that cross-component tool to parse IAM events.
# This script must not be savend in component repo as it is intented to be used by
# CI.
CCI=/tmp/cci
log_msg "Downloading cci (cloud credential insights) utility"
curl -s https://raw.githubusercontent.com/mtulio/mtulio.labs/refs/heads/exp-ocp-cred-informer/labs/ocp-identity/cloud-credentials-insights/cci.py > ${CCI}
chmod +x ${CCI}

# Dependencies required for CCI.
pip3 install pyyaml

#
# Extracting events
#
log_msg "\nChecking the size of discovered events / raw data"
du -sh "${EVENTS_PATH_RAW}"

log_msg "Extracting insights from events"

#INSTALLER_USER_NAME="${CLUSTER_NAME}"-installer 
#INSTALLER_USER_NAME="${CLUSTER_NAME}"-minimal-perm 
#INSTALLER_USER_NAME=origin-ci-robot-provision
INSTALLER_USER_NAME=$(head -n1 "${SHARED_DIR}/aws_user_names")

mkdir -v "${EVENTS_PATH_PARSED}" || true
${CCI} --command extract \
	--events-path "${EVENTS_PATH_RAW}" \
	--output "${EVENTS_PATH_PARSED}" \
    --filters principal-prefix="${CLUSTER_NAME}" \
	--installer-user-name="${INSTALLER_USER_NAME}"

#
# Extract credentials requests
#
log_msg "Attempting to extract credential requests from RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:-}"

mkdir -v "${CREDS_REQ_PATH}" || true
mkdir -v "${CREDS_REQ_PATH_RAW}" || true

function extract_credrequests() {
	pushd "${CREDS_REQ_PATH_RAW}"
	cp "${CLUSTER_PROFILE_DIR}"/pull-secret pull-secret
	#cp $PULL_SECRET_FILE pull-secret
	oc registry login --to pull-secret
	oc adm release extract --registry-config pull-secret \
		--credentials-requests --cloud=aws \
		--to="${CREDS_REQ_PATH}" \
		--from="${RELEASE_IMAGE_LATEST}"
	popd
	CCI_EXTRA_ARGS+="--credentials-requests-path=${CREDS_REQ_PATH} "
}
extract_credrequests || true

#
# Parse events considering requested permissions by CredentialsRequests manifests
#
log_msg "Creating report based in events and credential requests..."

# TODO: check if we can cover this file more generically.
INSTALLER_REQUEST_FILE=${SHARED_DIR}/aws-permissions-policy-creds.json
if [[ ! -f "${INSTALLER_REQUEST_FILE}" ]];
then
	echo "{}" | jq . > "${INSTALLER_REQUEST_FILE}"
fi

${CCI} --command compare \
	--events-path "${EVENTS_PATH_PARSED}"/events.json \
	--output="${EVENTS_PATH_PARSED}" \
	--installer-user-name="${INSTALLER_USER_NAME}" \
	--installer-user-policy="${INSTALLER_REQUEST_FILE}" \
	--filters cluster-name="${CLUSTER_NAME}" \
	${CCI_EXTRA_ARGS-}

log_msg "Copying results to artifacts directory"
cp -v "${EVENTS_PATH_PARSED}"/* "${ARTIFACT_DIR}"/
