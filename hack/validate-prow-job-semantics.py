#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import yaml


JOBS_DIR = 'ci-operator/jobs'


def main():
    failed = False
    for root, dirs, files in os.walk(JOBS_DIR):
        for filename in files:
            if not filename.endswith('.yaml'):
                continue
            if os.path.basename(filename) == "infra-periodics.yaml":
                continue
            for check in [validate_filename, validate_file_structure, validate_job_repo, validate_names, validate_sharding]:
                if not check(os.path.join(root, filename)):
                    failed = True

    if failed:
        sys.exit(1)

def parse_org_repo(path):
    return os.path.basename(os.path.dirname(os.path.dirname(path))), os.path.basename(os.path.dirname(path))

def validate_filename(path):
    errors = []

    org_dir, repo_dir = parse_org_repo(path)
    base = os.path.basename(path)
    if not base.startswith("{}-{}-".format(org_dir,repo_dir)):
        print("[ERROR] {}: expected filename to start with {}-{}".format(path,org_dir,repo_dir))
        return False

    job_type = base[base.rfind("-")+1:-len(".yaml")]
    if job_type not in ["periodics", "postsubmits", "presubmits"]:
        print("[ERROR] {}: expected filename to end with a job type".format(path))
        return False

    if job_type == "periodics":
        if base != "{}-{}-{}.yaml".format(org_dir,repo_dir,job_type):
            print("[ERROR] {}: Invalid formatting in filename: expected filename format $org-$repo-periodics.yaml".format(path))
            return False
    else:
        branch = base[len("{}-{}-".format(org_dir,repo_dir)):-len("-{}.yaml".format(job_type))]
        if branch == "":
            print("[ERROR] {}: Invalid formatting in filename: expected filename format org-repo-branch-(pre|post)submits.yaml".format(path))
            return False

    return True

def validate_file_structure(path):
    with open(path) as f:
        data = yaml.load(f)
        if len(data) != 1:
            print("[ERROR] {}: file contains more than one type of job".format(path))
            return False
        if next(iter(data.keys())) == 'periodics':
            return True
        data = next(iter(data.values()))
        if len(data) != 1:
            print("[ERROR] {}: file contains jobs for more than one repo".format(path))
            return False

    return True

def validate_job_repo(path):
    org, repo = parse_org_repo(path)
    with open(path) as f:
        data = yaml.load(f)
        if "presubmits" in data:
            for org_repo in data["presubmits"]:
                if org_repo != "{}/{}".format(org,repo):
                    print("[ERROR] {}: file defines jobs for {}, but is only allowed to contain jobs for {}/{}".format(org_repo, org, repo))
                    return False
        if "postsubmits" in data:
            for org_repo in data["postsubmits"]:
                if org_repo != "{}/{}".format(org,repo):
                    print("[ERROR] {}: file defines jobs for {}, but is only allowed to contain jobs for {}/{}".format(org_repo, org, repo))
                    return False

    return True

def validate_names(path):
    out = True
    with open(path) as f:
        data = yaml.load(f)
        for job_type in data:
            if job_type == "periodics":
                continue

            for repo in data[job_type]:
                for job in data[job_type][repo]:
                    if job["agent"] != "kubernetes":
                        continue

                    if job["spec"]["containers"][0]["command"][0] != "ci-operator":
                        continue

                    target = "all"
                    for arg in job["spec"]["containers"][0].get("args", []) + job["spec"]["containers"][0]["command"]:
                        if arg.startswith("--target="):
                            target = arg[len("--target="):].strip("[]")
                            break

                    branch = "master"
                    if "branches" in job:
                        branch = job["branches"][0]

                    prefix = "pull"
                    if job_type == "postsubmits":
                        prefix = "branch"

                    name = "{}-ci-{}-{}-{}".format(prefix, repo.replace("/", "-"), branch, target)
                    if job["name"] != name:
                        print("[ERROR] {}: ci-operator job {} should have name {}".format(path, job["name"], name))
                        out = False

    return out

def validate_sharding(path):
    out = True
    with open(path) as f:
        data = yaml.load(f)
        for job_type in data:
            if job_type == "periodics":
                continue

            for repo in data[job_type]:
                for job in data[job_type][repo]:
                    if job["agent"] != "kubernetes":
                        continue

                    if job["spec"]["containers"][0]["command"][0] != "ci-operator":
                        continue

                    branch = "master"
                    if "branches" in job:
                        branch = job["branches"][0]

                    file_branch = os.path.basename(path)[len("{}-".format(repo.replace("/","-"))):-len("-{}.yaml".format(job_type))]
                    if file_branch != branch:
                        print("[ERROR] {}: job {} runs on branch {}, not {} so it should be in file {}".format(path, job["name"], branch, file_branch, path.replace(file_branch, branch)))
                        out = False

    return out

main()