#!/usr/bin/python

from __future__ import print_function
import sys
import tempfile
from subprocess import call

from kubernetes import client, config
from kubernetes.client.rest import ApiException
import jobs_common

def main(argv):
    if len(argv)==0:
        print('No arguments passed. Please specify a namespace, name, and value of ci.openshift.io/jenkins-job annotation')
    elif len(argv)==3:
        process_config(argv[0], argv[1], argv[2])

def process_config(namespace, name, annotation_value=None):
    if annotation_value != "true":
        print("configmap {}/{} is not applicable to Jenkins".format(namespace, name))
        return

    config.load_incluster_config()
    core_instance = client.CoreV1Api()

    try:
        config_map = core_instance.read_namespaced_config_map(name, namespace)
    except ApiException as e:
        print("Exception when calling CoreV1Api->read_namespaced_configmap: {}\n".format(e))
        exit(1)

    if len(config_map.data) != 1:
        print("Invalid config map {}/{}: more than one data key present\n".format(namespace, name))

    if 'job.yml' not in config_map.data:
        print("Invalid config map {}/{}: no 'job.yml' key present\n".format(namespace, name))

    with tempfile.NamedTemporaryFile(suffix='.yml', delete=False) as job_file:
        job_file.write(config_map.data['job.yml'])
        job_file.close()
        call(["jenkins-jobs", "update", job_file.name])

    jobs_common.add_to_known_names(namespace, name)

if __name__ == "__main__":
    main(sys.argv[1:])
