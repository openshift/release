#!/bin/bash

datasource_name=$1
prometheus_namespace=$2

usage() {
echo "
USAGE
    setup-grafana.sh pro-ocp openshift-metrics true

    args:
      datasource_name: grafana datasource name
      prometheus_namespace: existing prometheus name e.g openshift-metrics

    note:
      the project must have view permissions for kube-system
"
exit 1
}

[[ -n ${datasource_name} ]] || usage

oc new-project grafana
oc process -f grafana-ocp.yaml |oc create -f -
oc rollout status deployment/grafana-ocp
oc adm policy add-role-to-user view -z grafana-ocp -n kube-system

payload="$( mktemp )"
cat <<EOF >"${payload}"
{
	"name": "${datasource_name}",
	"type": "prometheus",
	"typeLogoUrl": "",
	"access": "proxy",
	"url": "https://$( oc get route prometheus -n "${prometheus_namespace}" -o jsonpath='{.spec.host}' )",
	"basicAuth": false,
	"withCredentials": false,
	"jsonData": {
		"tlsSkipVerify":true,
		"token":"$( oc sa get-token grafana-ocp )"
	}
}
EOF

grafana_host="https://$( oc get route grafana-ocp -o jsonpath='{.spec.host}' )"
curl -H "Content-Type: application/json" -u admin:admin "${grafana_host}/api/datasources" -X POST -d "@${payload}"

# TODO:// use the origin file, one the PR will merge openshift/origin#17114?.
dashboard_file="./openshift-cluster-monitoring.json"
sed -i.bak "s/\${DS_PR}/${datasource_name}/" "${dashboard_file}"
curl -H "Content-Type: application/json" -u admin:admin "${grafana_host}/api/dashboards/db" -X POST -d "@${dashboard_file}"
mv "${dashboard_file}.bak" "${dashboard_file}"


exit 0
