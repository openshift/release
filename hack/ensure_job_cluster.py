#!/usr/bin/env python3
"""This script ensures the cluster of prowjobs is defined as expected.
e.g., python ./hack/ensure_job_cluster.py
"""

import argparse
import logging
import os
import yaml

DEFAULT_CLUSTER = "api.ci"
BUILD01_CLUSTER = "ci/api-build01-ci-devcluster-openshift-com:6443"
JOB_MAP = {
    "pull-ci-openshift-release-master-build01-dry": DEFAULT_CLUSTER,
    "pull-ci-openshift-release-master-core-dry": DEFAULT_CLUSTER,
    "pull-ci-openshift-release-master-services-dry": DEFAULT_CLUSTER,
    "periodic-acme-cert-issuer-for-build01": DEFAULT_CLUSTER,
    "periodic-build01-upgrade": BUILD01_CLUSTER,
}


def get_desired_cluster(file_path, job):
    """get the desired cluster for a given job defined in file_path."""
    if job.get("agent", "") != "kubernetes":
        return DEFAULT_CLUSTER
    if job["name"] in JOB_MAP:
        return JOB_MAP[job["name"]]
    if job["name"].endswith("-build01") or migrated(file_path):
        return BUILD01_CLUSTER
    return DEFAULT_CLUSTER


def identify_jobs_to_update(file_path, jobs):
    """identify jobs to update."""
    name_map = {}
    for job in jobs:
        cluster = get_desired_cluster(file_path, job)
        if cluster != job.get("cluster", ""):
            name_map[job["name"]] = cluster
    return name_map


def get_updated_jobs(jobs, name_map):
    """get updated jobs."""
    new_jobs = []
    for job in jobs:
        if job["name"] in name_map.keys():
            job["cluster"] = name_map[job["name"]]
        new_jobs.append(job)
    return new_jobs


def migrated(file_path):
    """check if the jobs defined in file_path are migrated."""
    # we do not migrate the periodis in release repo
    # due to https://github.com/openshift/release/pull/7178
    if file_path.endswith('periodics.yaml') and 'openshift/release/' in file_path:
        return False
    return False

def ensure(job_dir, overwrite):
    """ensure prow jobs' cluster."""
    for dirpath, _, filenames in os.walk(job_dir):
        for filename in filenames:
            if filename.endswith('.yaml'):
                file_path = os.path.join(dirpath, filename)
                with open(file_path) as file:
                    data = yaml.safe_load(file)
                    for job_type in ["presubmits", "postsubmits"]:
                        for repo in data.get(job_type, {}):
                            name_map = identify_jobs_to_update(file_path, data[job_type][repo])
                            if name_map and not overwrite:
                                raise Exception('those jobs in {} have to run on the cluster {}'\
                                    .format(file_path, name_map))
                            data[job_type][repo] = get_updated_jobs(data[job_type][repo], name_map)
                    name_map = identify_jobs_to_update(file_path, data.get("periodics", []))
                    if name_map and not overwrite:
                        raise Exception('those jobs in {} have to run on the cluster {}'\
                            .format(file_path, name_map))
                    data["periodics"] = get_updated_jobs(data.get("periodics", []), name_map)
                if overwrite:
                    with open(file_path, 'w') as file:
                        yaml.dump(data, file)


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s:%(levelname)s:%(message)s"
    )


def main():
    """main function."""
    logging.info("checking jobs ...")
    parser = argparse.ArgumentParser(description='Ensure prow jobs\' cluster.')
    parser.add_argument('-d', '--job-dir', default='./ci-operator/jobs',
                        help="the path to the job directory")
    parser.add_argument('-w', '--overwrite', default=False, help="overwrite jobs' cluster if True")
    args = parser.parse_args()
    ensure(args.job_dir, args.overwrite)
    if not args.overwrite:
        logging.info("every job is running on the expected cluster")


if __name__ == "__main__":
    main()
