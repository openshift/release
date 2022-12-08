#!/bin/bash

DEBUG='false'

function display_usage() {
	echo "This script generates a cron entry, based on provided test_name and yaml_file_name."
	echo "Usage: $0 test_name yaml_file_name"
	echo "  e.g, $0 aws-c2s-ipi-disconnected-private-p2-f7 openshift-openshift-tests-private-release-4.13__amd64-nightly.yaml"
}

if [[ $# -ne 2 ]] ; then
	display_usage
	exit 1
fi
if [[ ($@ == "--help") || ($@ == "-h") ]] ; then
	display_usage
	exit 0
fi


TEST_NAME="$1"    # aws-c2s-ipi-disconnected-private-p2-f7
YAML_FILE="$2"    # openshift-openshift-tests-private-release-4.13__amd64-nightly.yaml
if [[ $DEBUG = "true" ]] ; then
	echo "TEST_NAME: $TEST_NAME"
	echo "YAML_FILE: $YAML_FILE"
fi
if ! [[ "$TEST_NAME" =~ p[1-3]-f[0-9]+ ]] ; then
	echo "test_name must match [a-z0-9-]-p[1-3]-f[0-9]+(-.*)?"
	display_usage
	exit 2
fi

FN_TMP="${TEST_NAME#*-p[1-3]-f}"
FN="${FN_TMP%%-*}"
NUMBERS="$(echo $TEST_NAME $YAML_FILE | md5sum | tr -d [0a-z])"
if [[ $DEBUG = "true" ]] ; then
	echo "FN_TMP: $FN_TMP"
	echo "FN: $FN"
	echo "NUMBERS: $NUMBERS"
fi


let MINUTE=${NUMBERS:0:2}%60
let HOUR=${NUMBERS:2:2}%24
let DAY_OF_MONTH=${NUMBERS:4:2}%31+1
let MONTH=${NUMBERS:6:2}%12+1
let DAY_OF_WEEK=${NUMBERS:8:1}%7

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
	2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|30|31)
		DAY_OF_MONTH_FINAL=$DAY_OF_MONTH
		for ((i=1 ; i<31/FN; ++i)) ; do
			let DAY_OF_MONTH_TMP=(i*FN+DAY_OF_MONTH)%31+1
			DAY_OF_MONTH_FINAL+=",$DAY_OF_MONTH_TMP"
		done
		echo "$MINUTE $HOUR $DAY_OF_MONTH_FINAL * *"
		;;
	32|33|34|35|36|37|38|39|40|41|42|43|44|45|46|47|48|49|50|51|52|53|54|55|56|57|58|59|60)
		let MONTH_FINAL=$MONTH%2
		if [[ $MONTH_FINAL -eq 1 ]] ; then
			echo "$MINUTE $HOUR $DAY_OF_MONTH 1,3,5,7,9,11 *"
		else
			echo "$MINUTE $HOUR $DAY_OF_MONTH 2,4,6,8,10,12 *"
		fi
		;;
	*)
		echo "to be implemented"
		;;
esac
