#!/bin/sh

DS_NAME=$1
DASH_FILE="./openshift-cluster-monitoring.json"

oc create namespace grafana
# deploy the grafana pod
oc new-app -f grafana-ocp.yaml

pod_state=""
while [ "$pod_state" != "Running" ]
do
        pod_state=`oc get pod |grep grafana |awk '{print $3}'`
        sleep 1
done

TOKEN=`./oc sa get-token default`
#TODO:// replace those hardcoded values, the clinet which runs it must have permissions.
ROUTE=`oc get route |grep grafana |awk '{print $2}'`
PRO_SERVER=`oc get route --all-namespaces |grep prometheus |awk '{print $3}'`
JSON="{\"name\":\""$DS_NAME"\",\"type\":\"prometheus\",\"typeLogoUrl\":\"\",\"access\":\"proxy\",\"url\":\"https://"$PRO_SERVER"\",\"basicAuth\":false,\"withCredentials\":false,\"jsonData\":{\"tlsSkipVerify\":true,\"token\":\"$TOKEN\"}}"

# Add DS.
curl -H "Content-Type: application/json" -u admin:admin $ROUTE/api/datasources -X POST -d $JSON

# Replace values for DS.
sed -i 's/${DS_PR}/'$DS_NAME'/' $DASH_FILE

# Create new dashboard.
curl -H "Content-Type: application/json" -u admin:admin $ROUTE/api/dashboards/db -X POST -d @$DASH_FILE

# Tear down.
sed -i 's/'$DS_NAME'/${DS_PR}/' $DASH_FILE

exit 0
