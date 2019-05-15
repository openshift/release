#!/usr/bin/env python3

import os
import re
import sys
import yaml


JOBS_DIR = 'ci-operator/jobs'


def main():
    failed = False
    for root, _, files in os.walk(JOBS_DIR):
        for filename in files:
            if filename.endswith(".yml"):
                print(f"[ERROR] Only .yaml extensions are allowed, not .yml as in {root}/{filename}")
                failed = True
            if not filename.endswith('.yaml'):
                continue
            if os.path.basename(filename) == "infra-periodics.yaml":
                continue
            path = os.path.join(root, filename)
            for file_check in [validate_filename, validate_file_structure]:
                if not file_check(path):
                    failed = True
                else:
                    with open(path) as f:
                        data = yaml.load(f)
                        for content_check in [validate_job_repo, validate_names, validate_sharding, validate_ci_op_args, validate_pod_name, validate_resources]:
                            if not content_check(path, data):
                                failed = True

    if failed:
        sys.exit(1)

def parse_org_repo(path):
    return os.path.basename(os.path.dirname(os.path.dirname(path))), os.path.basename(os.path.dirname(path))

def validate_filename(path):
    org_dir, repo_dir = parse_org_repo(path)
    base = os.path.basename(path)
    if not base.startswith("{}-{}-".format(org_dir, repo_dir)):
        print("[ERROR] {}: expected filename to start with {}-{}".format(path, org_dir, repo_dir))
        return False

    job_type = base[base.rfind("-")+1:-len(".yaml")]
    if job_type not in ["periodics", "postsubmits", "presubmits"]:
        print("[ERROR] {}: expected filename to end with a job type".format(path))
        return False

    if job_type == "periodics":
        branch = base[len("{}-{}-".format(org_dir, repo_dir)):-len("-{}.yaml".format(job_type))]
        if branch == "":
            if base != "{}-{}-{}.yaml".format(org_dir, repo_dir, job_type):
                print("[ERROR] {}: Invalid formatting in filename: expected filename format $org-$repo-periodics.yaml".format(path))
                return False
    else:
        branch = base[len("{}-{}-".format(org_dir, repo_dir)):-len("-{}.yaml".format(job_type))]
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

def validate_job_repo(path, data):
    org, repo = parse_org_repo(path)
    if "presubmits" in data:
        for org_repo in data["presubmits"]:
            if org_repo != "{}/{}".format(org, repo):
                print("[ERROR] {}: file defines jobs for {}, but is only allowed to contain jobs for {}/{}".format(path, org_repo, org, repo))
                return False
    if "postsubmits" in data:
        for org_repo in data["postsubmits"]:
            if org_repo != "{}/{}".format(org, repo):
                print("[ERROR] {}: file defines jobs for {}, but is only allowed to contain jobs for {}/{}".format(path, org_repo, org, repo))
                return False

    return True

def validate_names(path, data):
    out = True
    for job_type in data:
        if job_type == "periodics":
            continue

        for repo in data[job_type]:
            for job in data[job_type][repo]:
                if job["agent"] != "kubernetes":
                    continue

                if not "command" in job["spec"]["containers"][0].keys():
                    continue

                if job["spec"]["containers"][0]["command"][0] != "ci-operator":
                    continue

                targets = []
                for arg in job["spec"]["containers"][0].get("args", []) + job["spec"]["containers"][0]["command"]:
                    if arg.startswith("--target="):
                        targets.append(arg[len("--target="):].strip("[]"))

                if not targets:
                    print("[WARNING] {}: ci-operator job {} should call a target".format(path, job["name"]))
                    continue

                filtered_targets = [target for target in targets if target not in ["release:latest"]]
                if len(filtered_targets) != 1:
                    print("[WARNING] {}: ci-operator job {} should call no more than one target, calls {}".format(path, job["name"], targets))
                    continue

                branch = "master"
                if "branches" in job:
                    for branch_name in job["branches"]:
                        if "_" in branch_name:
                            print("[ERROR] {}: job {} branches with underscores are not allowed: {}".format(path, job["name"], branch_name))
                    branch = make_regex_filename_label(job["branches"][0])

                prefix = "pull"
                if job_type == "postsubmits":
                    prefix = "branch"

                variant = job.get("labels", {}).get("ci-operator.openshift.io/variant", "")
                target = filtered_targets[0]
                if variant:
                    target = variant + "-" + target

                valid_name = "{}-ci-{}-{}-{}".format(prefix, repo.replace("/", "-"), branch, target)
                if job["name"] != valid_name:
                    print("[ERROR] {}: ci-operator job {} should be named {}".format(path, job["name"], valid_name))
                    out = False

                if job_type == "presubmits":
                    valid_context = "ci/prow/{}".format(target)
                    if job["context"] != valid_context:
                        print("[ERROR] {}: ci-operator job {} should have context {}".format(path, job["name"], valid_context))
                        out = False

                    valid_rerun_command = "/test {}".format(target)
                    if job["rerun_command"] != valid_rerun_command:
                        print("[ERROR] {}: ci-operator job {} should have rerun_command {}".format(path, job["name"], valid_rerun_command))
                        out = False

                    valid_trigger = r"(?m)^/test (?:.*? )?{}(?: .*?)?$".format(target)
                    if job["trigger"] != valid_trigger:
                        print("[ERROR] {}: ci-operator job {} should have trigger {}".format(path, job["name"], valid_trigger))
                        out = False

    return out

def make_regex_filename_label(name):
    name = re.sub(r"[^\w\-\.]+", "", name)
    name = name.strip("-._")
    return name

def validate_sharding(path, data):
    out = True
    for job_type in data:
        if job_type == "periodics":
            continue

        for repo in data[job_type]:
            for job in data[job_type][repo]:
                branch = "master"
                if "branches" in job:
                    branch = make_regex_filename_label(job["branches"][0])

                file_branch = os.path.basename(path)[len("{}-".format(repo.replace("/", "-"))):-len("-{}.yaml".format(job_type))]
                if file_branch != branch:
                    print("[ERROR] {}: job {} runs on branch {}, not {} so it should be in file {}".format(path, job["name"], branch, file_branch, path.replace(file_branch, branch)))
                    out = False

    return out

def validate_pod_name(path, data):
    out = True
    for job_type in data:
        if job_type == "periodics":
            continue

        for repo in data[job_type]:
            for job in data[job_type][repo]:
                if job["agent"] != "kubernetes":
                    continue

                if job["spec"]["containers"][0]["name"] != "":
                    print("[ERROR] {}: ci-operator job {} should not set a pod name".format(path, job["name"]))
                    out = False
                    continue

    return out

def validate_ci_op_args(path, data):
    out = True
    for job_type in data:
        if job_type == "periodics":
            continue

        for repo in data[job_type]:
            for job in data[job_type][repo]:
                if job["agent"] != "kubernetes":
                    continue

                if not "command" in job["spec"]["containers"][0].keys():
                    continue

                if job["spec"]["containers"][0]["command"][0] != "ci-operator":
                    continue

                for needed_arg in ["--give-pr-author-access-to-namespace=true", "--artifact-dir=$(ARTIFACTS)"]:
                    found = False
                    if "args" in job["spec"]["containers"][0]:
                        for arg in job["spec"]["containers"][0]["args"]:
                            if arg == needed_arg:
                                found = True

                    else:
                        for arg in job["spec"]["containers"][0]["command"][1:]:
                            if arg == needed_arg:
                                found = True

                    if not found:
                        print("[ERROR] {}: job {} needs to set the {} flag for ci-operator".format(path, job["name"], needed_arg))
                        out = False

    return out

def validate_image_pull(path, data):
    out = True
    for job_type in data:
        if job_type == "periodics":
            continue

        for repo in data[job_type]:
            for job in data[job_type][repo]:
                if job["agent"] != "kubernetes":
                    continue

                if job["spec"]["containers"][0]["imagePullPolicy"] != "Always":
                    print("[ERROR] {}: ci-operator job {} should set the pod's image pull policy to always".format(path, job["name"]))
                    out = False
                    continue

    return out

def validate_resources(path, data):
    out = True
    for job_type in data:
        if job_type == "periodics":
            continue

        for repo in data[job_type]:
            for job in data[job_type][repo]:
                if job["agent"] != "kubernetes":
                    continue

                if not "command" in job["spec"]["containers"][0].keys():
                    continue

                ci_op_job = job["spec"]["containers"][0]["command"][0] == "ci-operator"
                resources = job["spec"]["containers"][0].get("resources", {})
                bad_ci_op_resources = resources != {"requests": {"cpu": "10m"}}
                null_cpu_request = resources.get("requests", {}).get("cpu", "") == ""
                if ci_op_job and bad_ci_op_resources:
                    print("[ERROR] {}: ci-operator job {} should set the pod's CPU requests and limits to {}".format(path, job["name"], resources))
                    out = False
                    continue
                elif null_cpu_request:
                    print("[ERROR] {}: ci-operator job {} should set the pod's CPU requests".format(path, job["name"]))
                    out = False
                    continue

    return out

main()
