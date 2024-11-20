#!/usr/bin/env python
import os
import sys
import logging
import time

from kubernetes import client, config
from kubernetes.client.rest import ApiException

try:
    from pylint.lint import Run

    file_path = os.path.realpath(__file__)
    Run([file_path], exit=False)
except ImportError:
    print("linter not available, run outside of CI")

# This step uses:
# https://github.com/openshift-splat-team/vsphere-ci-images
# https://github.com/openshift/release/pull/57722
# https://quay.io/repository/ocp-splat/vsphere-ci-python

logging.basicConfig(
    format='%(asctime)s %(levelname)s [%(filename)s:%(lineno)d] %(message)s',
    level=logging.INFO)
logger = logging.getLogger()

def main():
    cluster_profile_name = os.environ.get("CLUSTER_PROFILE_NAME")
    leased_resource = os.environ.get("LEASED_RESOURCE")
    kubeconfig = os.environ.get("KUBECONFIG")

    if kubeconfig is None:
        logger.critical("KUBECONFIG is undefined")
        sys.exit(1)
    if cluster_profile_name is None:
        logger.critical("CLUSTER_PROFILE_NAME is undefined")
        sys.exit(1)

    if leased_resource is None:
        logger.critical("failed to acquire lease")
        sys.exit(1)

    config.load_config()
    core = client.CoreV1Api()

    json_delete_patch = [{"op":"remove","path": "/metadata/finalizers"}]

    for pv in core.list_persistent_volume().items:
        try:
            logger.info(f"pv name {pv.metadata.name}")
            core.delete_persistent_volume(name=pv.metadata.name)
            time.sleep(5)
            core.patch_persistent_volume(pv.metadata.name, json_delete_patch)
        except ApiException as e:
            logger.error(e)


if __name__ == '__main__':
    main()
