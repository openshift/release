#!/usr/bin/env bash
function delete_bootstrap_resources() {
  #we need to look for the message: INFO It is now safe to remove the bootstrap resources" from opesnhift-install wait-for boostrap-complete
  echo "destroying bootstrap resources"
  gather_bootstrap_logs
  mv ${TMP_SHARED}/BOOTSTRAP_FIP ${TMP_SHARED}/BOOTSTRAP_FIP_logs_collected
  ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-bootstrap.yaml"
  openstack image delete $GLANCE_SHIM_IMAGE_ID
} #-sr


#This should be split into it's own step.
function gather_bootstrap_logs() {
    if [ -f "${TMP_SHARED}/BOOTSTRAP_FIP" ] ; then
        echo Gathering bootstrap logs
        B_FIP=$(cat ${TMP_SHARED}/BOOTSTRAP_FIP)
        ssh -i ${SSH_PRIVATE_KEY_PATH} -o "StrictHostKeyChecking no" core@${B_FIP} 'journalctl -b  -u release-image.service -u bootkube.service > bootstrap.log; tar -czf bootstrap.log.tgz bootstrap.log' || true
        scp -i ${SSH_PRIVATE_KEY_PATH} -o "StrictHostKeyChecking no" core@${B_FIP}:~/bootstrap.log.tgz ${ARTIFACT_DIR}/bootstrap/bootstrap.log.tgz || true
    else
      echo Bootstrap fip no longer available. Unable to collect bootstrap logs
    fi
}

delete_bootstrap_resources