#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

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

cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion "cat ~/bm/kubeconfig" > /tmp/kubeconfig
  # Setup socks proxy
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion -fNT -D 12345
  export KUBECONFIG=/tmp/kubeconfig
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig=/tmp/kubeconfig config set-cluster bm --proxy-url=socks5://localhost:12345
  cd /tmp
fi
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

# Clone the e2e repo
REPO_URL=${E2E_REPOSITORY:-"https://github.com/cloud-bulldozer/e2e-benchmarking"};
LATEST_TAG=$(curl -s "https://api.github.com/repos/${REPO_URL#https://github.com}/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL e2e-benchmarking $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/ingress-perf

# ES Configuration
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ES_INDEX="ingress-performance"

rm -f ${SHARED_DIR}/index.json

# Start the Workload
./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/index_data.json ${SHARED_DIR}/index_data.json

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi