#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

installer_artifact_dir=${ARTIFACT_DIR}/installer

echo "Using tmpfs hack for job $JOB_NAME"

TF_LOG=debug openshift-install --dir="${installer_artifact_dir}" create ignition-configs --log-level=debug
python -c \
    'import json, sys; j = json.load(sys.stdin); j[u"systemd"] = {}; j[u"systemd"][u"units"] = [{u"contents": "[Unit]\nDescription=Mount etcd as a ramdisk\nBefore=local-fs.target\n[Mount]\n What=none\nWhere=/var/lib/etcd\nType=tmpfs\nOptions=size=2G\n[Install]\nWantedBy=local-fs.target", u"enabled": True, u"name":u"var-lib-etcd.mount"}]; json.dump(j, sys.stdout)' \
    <"${installer_artifact_dir}"/master.ign \
    >"${installer_artifact_dir}"/master.ign.out
mv "${installer_artifact_dir}"/master.ign.out "${installer_artifact_dir}"/master.ign