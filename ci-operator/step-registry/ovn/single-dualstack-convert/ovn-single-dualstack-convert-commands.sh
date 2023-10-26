#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail


# Check if the CONVERT_IPV4_TIMEOUT environment variable is set and is equal to "0s"
if [ -n "$CONVERT_IPV4_TIMEOUT" ] && [ "$CONVERT_IPV4_TIMEOUT" = "0s" ]; then
  unset CONVERT_IPV4_TIMEOUT
fi

co_timeout=${CONVERT_IPV4_TIMEOUT:-1200s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=AVAILABLE=True' --timeout=30s && \
  oc wait co --all --for='condition=PROGRESSING=False' --timeout=30s && \
  oc wait co --all --for='condition=DEGRADED=False' --timeout=30s;
do
  sleep 10
  echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT

if [ ${CONVERT_TO_IP_FAMILIES} = "ipv4" ]; then 
  oc patch network.config.openshift.io cluster --type=json --patch-file=/dev/stdin <<-EOFR
[
  {
    "op": "remove",
    "path": "/spec/clusterNetwork/1",
  },
  {
    "op": "remove",
    "path": "/spec/serviceNetwork/1",
  }
]
EOFR
elif [ ${CONVERT_TO_IP_FAMILIES} = "dualstack" ]; then
  oc patch network.config.openshift.io cluster --type=json --patch-file=/dev/stdin <<-EOFA
[
  {
    "op": "add",
    "path": "/spec/clusterNetwork/-",
    "value": {
      "cidr": "fd01::/48",
      "hostPrefix": 64
    }
  },
  {
    "op": "add",
    "path": "/spec/serviceNetwork/-",
    "value": "fd02::/112"
  }
]
EOFA
 
fi
mco_timeout=${CONVERT_IPV4_TIMEOUT:-180s}
oc wait mcp --all --for='condition=UPDATING=True' --timeout="$mco_timeout"

# Wait until MCO finishes its work or it reachs the 30mins timeout
mcp_timeout=${CONVERT_IPV4_TIMEOUT:-1800s}
timeout "$mcp_timeout" bash <<EOT
until
  oc wait mcp --all --for='condition=UPDATED=True' --timeout=30s && \
  oc wait mcp --all --for='condition=UPDATING=False' --timeout=30s && \
  oc wait mcp --all --for='condition=DEGRADED=False' --timeout=30s; 
do
  sleep 20
  echo "Some MachineConfigPool DEGRADED=True,UPDATING=True,or UPDATED=False";
done
EOT


co_timeout=${CONVERT_IPV4_TIMEOUT:-1200s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=AVAILABLE=True' --timeout=30s && \
  oc wait co --all --for='condition=PROGRESSING=False' --timeout=30s && \
  oc wait co --all --for='condition=DEGRADED=False' --timeout=30s;
do
  sleep 10
  echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT

oc get co

oc get controllerconfig machine-config-controller -o jsonpath='{.spec.ipFamilies}'

