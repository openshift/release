#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

set_proxy

run_command "oc annotate ingress.config cluster ingress.operator.openshift.io/default-enable-http2=true --overwrite"

echo "Wait for the custom ingresscontroller to be ready"
run_command "oc wait co ingress --for='condition=Progressing=True' --timeout=30s"

# Check cluster operator ingress back to normal
timeout 120s bash <<EOT
until
  oc wait co ingress --for='condition=Available=True' --timeout=10s && \
  oc wait co ingress --for='condition=Progressing=False' --timeout=10s && \
  oc wait co ingress --for='condition=Degraded=False' --timeout=10s;
do
  sleep 10 && echo "Cluster Operator ingress Degraded=True,Progressing=True,or Available=False";
done
EOT

