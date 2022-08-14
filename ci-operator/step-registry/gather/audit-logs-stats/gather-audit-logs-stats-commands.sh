#!/bin/bash

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering audit logs."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

paths=(openshift-apiserver kube-apiserver)
for path in "${paths[@]}" ; do
  oc adm node-logs --role=master --path="$path" | \
  grep -v ".terminating" | \
  grep -v ".lock" |\
	grep -v "\termination.log$" |\
	grep "audit" |\
	sed "s|^|$path |" | sed "s/ /#/g" > /tmp/paths
done
for line in $(cat /tmp/paths) ; do
	p=$(echo $line | cut -d'#' -f1)
	n=$(echo $line | cut -d'#' -f2)
	a=$(echo $line | cut -d'#' -f3)
	oc adm node-logs $n --path=$p/$a | jq -c 'select(.verb) | select(.verb=="watch") | select(.user) | select(.user.username) | select(.user.username | endswith("operator")) | select(.stage) | select(.stage=="ResponseComplete") | select(.auditID) | select(.responseStatus) | select(.responseStatus.code) | select(.responseStatus.code==200) | select(.stageTimestamp)'
done | uniq -u | jq -r '.user.username + " " + .stageTimestamp' | python -c '
import fileinput;
from datetime import datetime, timedelta;
import json;
format = "%Y-%m-%dT%H:%M:%S.%fZ"
operatorTS = {}
for line in fileinput.input():
	line = line.strip()
	operator = line.split(" ")[0].split(":")[3]
	ts = line.split(" ")[1]
	out = datetime.strptime(ts, format).replace(second=0, microsecond=0)
	try:
		operatorTS[operator]
	except KeyError:
		operatorTS[operator] = {}
	try:
	 	operatorTS[operator][out] += 1
	except KeyError:
		operatorTS[operator][out] = 1

operatorWatchRequestMaximums = {}
for operator in sorted(operatorTS.keys()):
	keys = sorted(operatorTS[operator].keys())
	keylen = len(keys)
	idx = 0
	idxj = 0
	max = 0
	# find all 60min long buckets and get the total watch request count
	while idx < keylen:
		start = keys[idx]
		end = keys[idx] + timedelta(minutes=60)
		# find ts for the next 60min long bucket
		while idxj+1 < keylen and keys[idxj] < end:
			idxj +=1
		i = idx
		# sum all watch request counts in the current 60min bucket
		sum = 0
		while i <= idxj:
			sum += operatorTS[operator][keys[i]]
			i += 1
		if sum > max:
			max = sum
		# skip all remaining buckets with lenght < 60 minutes
		if keys[idxj]-start < timedelta(minutes=60):
			break
		idx += 1
	operatorWatchRequestMaximums[operator] = max
print(json.dumps(operatorWatchRequestMaximums))' > "${ARTIFACT_DIR}/audit-logs-operator-watch-requests-max-per-60min.json"
