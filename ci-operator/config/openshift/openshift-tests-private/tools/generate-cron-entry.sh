#!/bin/bash

DEBUG='false'

function display_usage() {
	echo "This script generates a cron entry, based on provided test_name and yaml_file_name."
	echo "Usage: $0 <test_name> <yaml_file_name> [--force]"
	echo "  e.g, $0 aws-c2s-ipi-disconnected-private-f7 openshift-openshift-tests-private-release-4.13__amd64-nightly.yaml"
}

if [[ $# -lt 2 ]] ; then
	display_usage
	exit 1
fi
if [[ ($@ == "--help") || ($@ == "-h") ]] ; then
	display_usage
	exit 0
fi


TEST_NAME="$1"    # aws-c2s-ipi-disconnected-private-f7
YAML_FILE="$2"    # openshift-openshift-tests-private-release-4.13__amd64-nightly.yaml

if [[ "${TEST_NAME}" =~ (-disabled|-disasterrecovery|powervs-) ]] && [[ "$@" != *\ --force* ]]; then
    echo "The test config ${TEST_NAME} should not get changes in the cron entry as
      the schedule rotation scheme is different than the other tests.
      Use --force to skip this check."
    exit 0
fi

if [[ $DEBUG = "true" ]] ; then
	echo "TEST_NAME: $TEST_NAME"
	echo "YAML_FILE: $YAML_FILE"
fi
if ! [[ "$TEST_NAME" =~ (p[1-3])?-f[0-9]+ ]] ; then
	echo "test_name must match [a-z0-9-](-p[1-3])?-f[0-9]+(-.*)?"
	display_usage
	exit 2
fi

FN="$(echo $TEST_NAME | sed -E 's/.*-f([0-9]+)(.*)?/\1/')"
NUMBERS="$(echo $TEST_NAME $YAML_FILE | md5sum | tr [a-f] [1-6] | tr -d ' -')"
if [[ $DEBUG = "true" ]] ; then
	echo "FN: $FN"
	echo "NUMBERS: $NUMBERS"
fi


let MINUTE=10#${NUMBERS:0:2}%60
let HOUR=10#${NUMBERS:2:2}%24
let DAY_OF_MONTH=10#${NUMBERS:4:2}%30+1
let MONTH=10#${NUMBERS:6:2}%12+1
let DAY_OF_WEEK=10#${NUMBERS:8:1}%7

if [[ "${TEST_NAME}" =~ baremetal- ]] ; then
	# Raleigh working hours, 8~17 (in UTC, 13~22)
	WK_HOUR_BEGIN=13
	WK_HOUR_END=22
	if [[ $HOUR -lt $WK_HOUR_BEGIN ]] || [[ $HOUR -ge $WK_HOUR_END ]] ; then
		let HOUR=HOUR%$((WK_HOUR_END-WK_HOUR_BEGIN))+WK_HOUR_BEGIN
	fi
fi

if [[ $DEBUG = "true" ]] ; then
	echo "MINUTE: $MINUTE"
	echo "HOUR: $HOUR"
	echo "DAY_OF_MONTH: $DAY_OF_MONTH"
	echo "MONTH: $MONTH"
	echo "DAY_OF_WEEK: $DAY_OF_WEEK"
	echo
fi

echo -n "cron: "
case "$FN" in
	1)
		echo "$MINUTE $HOUR * * *"
		;;
	2|3|4|5|6|7|10|14|28|30)
		DAY_OF_MONTH_TMP=$DAY_OF_MONTH
		for ((i=1 ; i<31/FN; ++i)) ; do
			let TMP=(i*FN+DAY_OF_MONTH-1)%30+1
			DAY_OF_MONTH_TMP+=",$TMP"
		done
		DAY_OF_MONTH_FINAL=$(echo $DAY_OF_MONTH_TMP | sed 's/,/\n/g' | sort -n | paste -s -d ',' -)
		echo "$MINUTE $HOUR $DAY_OF_MONTH_FINAL * *"
		;;
	60|90|120|180|360)
		let MONTH_TMP=MONTH
		for ((i=1 ; i<365/FN; ++i)) ; do
			let TMP=(i*FN/30+MONTH-1)%12+1
			MONTH_TMP+=",$TMP"
		done
		MONTH_FINAL=$(echo $MONTH_TMP | sed 's/,/\n/g' | sort -n | paste -s -d ',' -)
		echo "$MINUTE $HOUR $DAY_OF_MONTH $MONTH_FINAL *"
		;;
	*)
		echo "to be implemented"
		;;
esac
