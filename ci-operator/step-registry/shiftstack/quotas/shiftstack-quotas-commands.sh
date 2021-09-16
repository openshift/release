#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
MIN_PERCENTAGE=${MIN_PERCENTAGE:-15}

notify_low_quota() {
	declare -r code="$?"

	if [ $code -eq 11 ]; then
		declare -r message="Quotas are low on ${CLOUD_NAME}."
		declare -r payload='{"text":"'"$message"'"}'

		curl -X POST \
			-H 'Content-type: application/json' \
			--data "$payload" \
			"$(</var/run/slack-hooks/shiftstack-bot)"

		return 0
	fi
	return $code
}

./borderline.sh --min-percentage "${MIN_PERCENTAGE}" \
	|| notify_low_quota
