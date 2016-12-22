#!/bin/bash

set -euo pipefail

build=$1
data=$2
url=$3

startup="$( mktemp -d )/startup.sh"
cat << STARTUP > "${startup}"
#!/bin/bash
set -euo pipefail

cat << EOF > /etc/yum.repos.d/origin-override.repo
[origin-override]
baseurl = "${url}"
gpgcheck = 0
name = OpenShift Origin Release
enabled = 1
EOF
STARTUP

docker rm gce-pr &>/dev/null || true
docker create --name gce-pr -e STARTUP_SCRIPT_FILE=/usr/local/install/data/startup.sh openshift/origin-gce:latest ansible-gce -e "pull_identifier=pr${build}" "playbooks/provision.yaml" >/dev/null
docker cp "${data}" gce-pr:/usr/local/install
docker cp "${startup}" gce-pr:/usr/local/install/data/
rm "${startup}"
docker start -a gce-pr
