#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
MIN_PERCENTAGE=${MIN_PERCENTAGE:-15}

message() {
	echo 'Quotas are low on '"$CLOUD_NAME"'.\n```'
	cat "${ARTIFACT_DIR}/output.txt"
	echo '```'
}

notify_low_quota() {
	declare -r code="$?"

	if [ $code -eq 11 ]; then
		declare payload
		payload='{"text":"'"$(message)"'"}'

		curl -X POST \
			-H 'Content-type: application/json' \
			--data "$payload" \
			"$(</var/run/slack-hooks/shiftstack-bot)"

		return 0
	fi
	return $code
}

./borderline.sh --min-percentage "${MIN_PERCENTAGE}" \
	> "${ARTIFACT_DIR}/output.txt" \
	|| notify_low_quota
