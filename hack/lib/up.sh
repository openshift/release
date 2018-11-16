#!/bin/sh

set -euo pipefail

base=$( dirname "${BASH_SOURCE[0]}")
out=/tmp/admin.kubeconfig

if ! which oc &>/dev/null; then
  echo "error: You must have oc built on your path" 1>&2
  exit 1
fi

if ! oc whoami --show-server | grep api.ci; then
  echo "error: You must have KUBECONFIG pointed to api.ci" 1>&2
  exit 1
fi

if ! which mkpj &>/dev/null; then
  echo "error: You must have mkpj built on your path" 1>&2
  exit 1
fi
type="${1:-aws-4.0}"
launcher="${2:-release-launch-aws}"
pod="${PJ:-}"

prowconfig="-config-path ${base}/../../cluster/ci/config/prow/config.yaml -job-config-path ${base}/../../ci-operator/jobs"

if [[ -z "${pod}" ]]; then
  pod=$( mkpj $prowconfig -job "release-openshift-origin-installer-launch-${type}" | oc create -n ci -f - -o 'jsonpath={.metadata.name}' )
  if [[ -z "${pod}" ]]; then
    echo "error: Unable to find pod name" 1>&2
    exit 1
  fi
fi

echo "Waiting for pod $pod"
while true; do
  if ! phase=$( oc get pj -n ci ${pod} -o 'jsonpath={.status.state}' ); then
    echo "error: Job has completed" 1>&2
    exit 1
  fi
  if [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]]; then
    echo "error: Job has exited" 1>&2
    exit 1
  fi
  if ns=$( oc logs -n ci -c test "${pod}" 2>/dev/null | sed -nE 's/.*Using namespace ([[:alnum:]-]+).*/\1/p' ); then
    break
  fi
  oc get pods -n ci $pod --template '{{.status.phase}}{{"\n"}}' || true
  sleep 5
done

echo "Waiting for pod $launcher in namespace $ns"
while true; do
  if oc get pods -n $ns $launcher &>/dev/null; then
    break
  fi
  sleep 5
done

echo "Waiting for credentials"
while true; do
  if contents=$( oc exec -c setup -n $ns $launcher -- cat /tmp/artifacts/installer/auth/kubeconfig 2>/dev/null ); then
    break
  fi
  if contents=$( oc exec -c test -n $ns $launcher -- cat /tmp/artifacts/installer/auth/kubeconfig 2>/dev/null ); then
    break
  fi
  oc get pods --no-headers -n $ns $launcher -o 'jsonpath={.status.phase}'
  echo 
  sleep 15
done

echo "${contents}" > $out
if ! KUBECONFIG=$out oc get pods 2>/dev/null; then
    echo "error: Unable to access cluster, check contents of $out" 1>&2
    exit 1
fi
echo
echo "You are now connected to cluster $( KUBECONFIG=$out oc whoami --show-server ) as $( KUBECONFIG=$out oc whoami )."
echo
echo "  export KUBECONFIG=${out}"
echo