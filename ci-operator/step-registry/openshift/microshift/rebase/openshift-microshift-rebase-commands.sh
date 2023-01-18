#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Print context
echo "Environment:"
printenv

# Copy pull secret into place
cp /secrets/ci-pull-secret/.dockercfg "$HOME/.pull-secret.json" || {
    echo "ERROR: Could not copy registry secret file"
}

# Determine pull specs for release images
release_amd64="$(oc get configmap/release-release-images-latest -o yaml \
    | yq '.data."release-images-latest.yaml"' \
    | jq -r '.metadata.name')"
release_arm64="$(oc get configmap/release-release-images-arm64-latest -o yaml \
    | yq '.data."release-images-arm64-latest.yaml"' \
    | jq -r '.metadata.name')"

pullspec_release_amd64="registry.ci.openshift.org/ocp/release:${release_amd64}"
pullspec_release_arm64="registry.ci.openshift.org/ocp-arm64/release-arm64:${release_arm64}"

echo "Pull spec for amd64 release image: ${pullspec_release_amd64}"
echo "Pull spec for arm64 release image: ${pullspec_release_arm64}"

oc get configmap/release-release-images-latest -o yaml
oc get configmap/release-release-images-arm64-latest -o yaml

exit 0

cat <<EOF > ./scripts/auto-rebase/rebase.py
#!/usr/bin/env python

import os
import sys
import logging
import subprocess
from collections import namedtuple

from git import Repo, PushInfo  # GitPython
from github import GithubIntegration, Github  # pygithub
from pathlib import Path

APP_ID_ENV = "APP_ID"
KEY_ENV = "KEY"
ORG_ENV = "ORG"
REPO_ENV = "REPO"
AMD64_RELEASE_ENV = "AMD64_RELEASE"
ARM64_RELEASE_ENV = "ARM64_RELEASE"
JOB_NAME_ENV = "JOB_NAME"
BUILD_ID_ENV = "BUILD_ID"
DRY_RUN_ENV = "DRY_RUN"

BOT_REMOTE_NAME = "bot-creds"
REMOTE_ORIGIN = "origin"

# List of reviewers to always requestes review from
REVIEWERS = ["pmtk", "ggiguash"]

# If True, then just log action such as branch push and PR or comment creation
REMOTE_DRY_RUN = False

_extra_msgs = []

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')


RebaseScriptResult = namedtuple("RebaseScriptResult", ["success", "output"])


def try_get_env(var_name, die=True):
    val = os.getenv(var_name)
    if val is None or val == "":
        if die:
            logging.error(f"Could not get environment variable '{var_name}'")
            sys.exit(f"Could not get environment variable '{var_name}'")
        else:
            logging.info(f"Could not get environment variable '{var_name}' - ignoring")
            return ""
    return val


def run_rebase_sh(release_amd64, release_arm64):
    script_dir = os.path.abspath(os.path.dirname(__file__))
    args = [f"{script_dir}/rebase.sh", "to", release_amd64, release_arm64]
    logging.info(f"Running: '{' '.join(args)}'")
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    logging.info(f"Return code: {result.returncode}. Output:\n" +
                 "==================================================\n" +
                 f"{result.stdout}" +
                 "==================================================\n")
    logging.info(f"Script returned code: {result.returncode}")
    return RebaseScriptResult(success=result.returncode == 0, output=result.stdout)


def commit_str(commit):
    return f"{commit.hexsha[:8]} - {commit.summary}"


def get_installation_access_token(app_id, key_path, org, repo):
    integration = GithubIntegration(app_id, Path(key_path).read_text())
    app_installation = integration.get_installation(org, repo)
    if app_installation == None:
        sys.exit(f"Failed to get app_installation for {org}/{repo}. Response: {app_installation.raw_data}")
    return integration.get_access_token(app_installation.id).token


def make_sure_rebase_script_created_new_commits_or_exit(git_repo, base_branch):
    if git_repo.active_branch.commit == git_repo.branches[base_branch].commit:
        logging.info(f"There's no new commit on branch {git_repo.active_branch} compared to '{base_branch}' "
                     "meaning that the rebase.sh script didn't create any commits and "
                     "MicroShift is already rebased on top of given release.\n"
                     f"Last commit: {commit_str(git_repo.active_branch.commit)}")
        sys.exit(0)


def get_remote_with_token(git_repo, token, org, repo):
    remote_url = f"https://x-access-token:{token}@github.com/{org}/{repo}"
    try:
        remote = git_repo.remote(BOT_REMOTE_NAME)
        remote.set_url(remote_url)
    except ValueError:
        git_repo.create_remote(BOT_REMOTE_NAME, remote_url)

    return git_repo.remote(BOT_REMOTE_NAME)


def try_get_rebase_branch_ref_from_remote(remote, branch_name):
    remote.fetch()
    matching_remote_refs = [ref for ref in remote.refs if BOT_REMOTE_NAME + "/" + branch_name == ref.name]

    if len(matching_remote_refs) == 0:
        logging.info(f"Branch '{branch_name}' does not exist on remote")
        return None

    if len(matching_remote_refs) > 1:
        matching_branches = ", ".join([r.name for r in matching_remote_refs])
        logging.warning(f"Found more than one branch matching '{branch_name}' on remote: {matching_branches}. Taking first one")
        _extra_msgs.append(f"Found more than one branch matching '{branch_name}' on remote: {matching_branches}.")
        return matching_remote_refs[0]

    if len(matching_remote_refs) == 1:
        logging.info(f"Branch '{branch_name}' already exists on remote")
        return matching_remote_refs[0]


def is_local_branch_based_on_newer_base_branch_commit(git_repo, base_branch_name, remote_branch_name, local_branch_name):
    """
    Compares local and remote rebase branches by looking at their start on base branch.
    Returns True if local branch is starts on newer commit and needs to be pushed to remote, otherwise False.
    """
    remote_merge_base = git_repo.merge_base(base_branch_name, remote_branch_name)
    local_merge_base = git_repo.merge_base(base_branch_name, local_branch_name)

    if remote_merge_base[0] == local_merge_base[0]:
        logging.info(f"Remote branch is up to date. Branch-off commit: {commit_str(remote_merge_base[0])}")
        return False
    else:
        logging.info(f"Remote branch is older - it needs updating. "
                     f"Remote branch is on top of {base_branch_name}'s commit: '{commit_str(remote_merge_base[0])}'. "
                     f"Local branch is on top of {base_branch_name}'s commit '{commit_str(local_merge_base[0])}'")
        return True


def try_get_pr(gh_repo, org, base_branch, branch_name):
    prs = gh_repo.get_pulls(base=base_branch, head=f"{org}:{branch_name}", state="all")

    if prs.totalCount == 0:
        logging.info(f"PR for branch {branch_name} does not exist yet on {gh_repo.full_name}")
        return None

    pr = None
    if prs.totalCount > 1:
        pr = prs[0]
        logging.warning(f"Found more than one PR for branch {branch_name} on {gh_repo.full_name} - this is unexpected, continuing with first one of: {[(x.state, x.html_url) for x in prs]}")

    if prs.totalCount == 1:
        pr = prs[0]
        logging.info(f"Found PR #{pr.number} for branch {branch_name} on {gh_repo.full_name}: {pr.html_url}")

    if pr.state == 'closed':
        logging.warning(f"PR #{pr.number} is not open - new PR will be created")
        if pr.is_merged():
            logging.warning(f"PR #{pr.number} for '{branch_name}' branch is already merged but rebase.sh produced results")
            _extra_msgs.append(f"PR #{pr.number} for '{branch_name}' was already merged but rebase.sh produced results")
        else:
            _extra_msgs.append(f"PR #{pr.number} for '{branch_name}' exists already but was closed")
        return None
    return pr


def generate_pr_description(branch_name, amd_tag, arm_tag, prow_job_url, rebase_script_succeded):
    base = (f"amd64: {amd_tag}\n"
            f"arm64: {arm_tag}\n"
            f"prow job: {prow_job_url}\n"
            "\n"
            "/label tide/merge-method-squash\n")
    return (base if rebase_script_succeded
            else "# rebase.sh failed - check committed rebase_sh.log\n\n" + base)


def create_pr(gh_repo, base_branch, branch_name, title, desc):
    if REMOTE_DRY_RUN:
        logging.info(f"[DRY RUN] Create PR: branch='{branch_name}', title='{title}', desc='{desc}'")
        logging.info(f"[DRY RUN] Requesting review from {REVIEWERS}")
        return

    pr = gh_repo.create_pull(title=title, body=desc, base=base_branch, head=branch_name, maintainer_can_modify=True)
    logging.info(f"Created pull request: {pr.html_url}")
    pr.create_review_request(reviews=REVIEWERS)
    logging.info(f"Requested review from {REVIEWERS}")
    return pr


def update_pr(pr, title, desc):
    if REMOTE_DRY_RUN:
        logging.info(f"[DRY RUN] Update PR #{pr.number}: {title}\n{desc}")
        return

    pr.edit(title=title, body=desc)
    pr.update()  # arm64 release or prow job url might've changed
    logging.info(f"Updated PR #{pr.number}: {title}\n{desc}")


def post_comment(pr, comment=""):
    if len(_extra_msgs) != 0:
        if comment != "":
            comment += "\n\n"
        comment += "Extra messages:\n - " + "\n - ".join(_extra_msgs)

    if REMOTE_DRY_RUN:
        logging.info(f"[DRY RUN] Post a comment on PR: {comment}")
        return

    if comment.strip() != "":
        issue = pr.as_issue()
        issue.create_comment(comment)


def push_branch_or_die(remote, branch_name):
    if REMOTE_DRY_RUN:
        logging.info(f"[DRY RUN] git push --force {branch_name}")
        return

    # TODO add retries
    push_result = remote.push(branch_name, force=True)

    if len(push_result) != 1:
        sys.exit(f"Unexpected amount ({len(push_result)}) of items in push_result: {push_result}")
    if push_result[0].flags & PushInfo.ERROR:
        sys.exit(f"Pushing branch failed: {push_result[0].summary}")
    if push_result[0].flags & PushInfo.FORCED_UPDATE:
        logging.info(f"Branch '{branch_name}' existed and was updated (force push)")


def get_release_tag(release):
    parts = release.split(":")
    if len(parts) == 2:
        return parts[1]
    else:
        logging.error(f"Couldn't find tag in '{release}' - using it as is as branch name")
        _extra_msgs.append(f"Couldn't find tag in '{release}' - using it as is as branch name")
        return release


def try_create_prow_job_url():
    job_name = try_get_env(JOB_NAME_ENV, False)
    build_id = try_get_env(BUILD_ID_ENV, False)
    if job_name != "" and build_id != "":
        url = f"https://prow.ci.openshift.org/view/gs/origin-ci-test/logs/{job_name}/{build_id}"
        logging.info(f"Inferred probable prow job url: {url}")
        return url
    else:
        logging.warning(f"Couldn't infer prow job url. Env vars: '{JOB_NAME_ENV}'='{job_name}', '{BUILD_ID_ENV}'='{build_id}'")
        _extra_msgs.append(f"Couldn't infer prow job url. Env vars: '{JOB_NAME_ENV}'='{job_name}', '{BUILD_ID_ENV}'='{build_id}'")
        return "-"


def create_pr_title(branch_name, successful_rebase):
    return branch_name if successful_rebase else f"**FAILURE** {branch_name}"


def get_expected_branch_name(amd, arm):
    amd_tag, arm_tag = get_release_tag(amd), get_release_tag(arm)
    import re
    rx = "(?P<version_stream>.+)-(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})"
    match_amd, match_arm = re.match(rx, amd_tag), re.match(rx, arm_tag)
    return f"rebase-{match_amd['version_stream']}+amd64-{match_amd['date']}+arm64-{match_arm['date']}"


def main():
    app_id = try_get_env(APP_ID_ENV)
    key_path = try_get_env(KEY_ENV)
    org = try_get_env(ORG_ENV)
    repo = try_get_env(REPO_ENV)
    release_amd = try_get_env(AMD64_RELEASE_ENV)
    release_arm = try_get_env(ARM64_RELEASE_ENV)

    global REMOTE_DRY_RUN
    REMOTE_DRY_RUN = False if try_get_env(DRY_RUN_ENV, die=False) == "" else True
    if REMOTE_DRY_RUN:
        logging.info("Dry run mode")

    token = get_installation_access_token(app_id, key_path, org, repo)
    gh_repo = Github(token).get_repo(f"{org}/{repo}")
    git_repo = Repo('.')
    base_branch = git_repo.active_branch.name

    rebase_result = run_rebase_sh(release_amd, release_arm)
    if rebase_result.success:
        # TODO How can we inform team that rebase job ran successfully just there was nothing new?
        make_sure_rebase_script_created_new_commits_or_exit(git_repo, base_branch)
    else:
        logging.warning("Rebase script failed - everything will be committed")
        with open('rebase_sh.log', 'w') as writer:
            writer.write(rebase_result.output)
        if git_repo.active_branch.name == base_branch:
            # rebase.sh didn't reached the step that would create a branch
            # so script needs to create it
            branch = git_repo.create_head(get_expected_branch_name(release_amd, release_arm))
            branch.checkout()
        git_repo.git.add(A=True)
        git_repo.index.commit("rebase.sh failure artifacts")

    rebase_branch_name = git_repo.active_branch.name
    git_remote = get_remote_with_token(git_repo, token, org, repo)
    remote_branch = try_get_rebase_branch_ref_from_remote(git_remote, rebase_branch_name)  # {BOT_REMOTE_NAME}/{rebase_branch_name}

    rbranch_does_not_exists = remote_branch == None
    rbranch_exists_and_needs_update = (
        remote_branch != None and
        is_local_branch_based_on_newer_base_branch_commit(git_repo, base_branch, remote_branch.name, rebase_branch_name)
    )
    if rbranch_does_not_exists or rbranch_exists_and_needs_update:
        push_branch_or_die(git_remote, rebase_branch_name)

    prow_job_url = try_create_prow_job_url()
    pr_title = create_pr_title(rebase_branch_name, rebase_result.success)
    desc = generate_pr_description(rebase_branch_name, get_release_tag(release_amd), get_release_tag(release_arm), prow_job_url, rebase_result.success)

    pr = try_get_pr(gh_repo, org, base_branch, rebase_branch_name)
    if pr == None:
        pr = create_pr(gh_repo, base_branch, rebase_branch_name, pr_title, desc)
        post_comment(pr)
    else:
        update_pr(pr, pr_title, desc)
        post_comment(pr, f"Rebase job updated the branch\n{desc}")

    sys.exit(0 if rebase_result.success else 1)


if __name__ == "__main__":
    main()



EOF

chmod +x ./scripts/auto-rebase/rebase.py
git add ./scripts/auto-rebase/rebase.py && git commit -m 'rebase.py test'

set +e
APP_ID=$(cat /secrets/pr-creds/app_id) \
KEY=/secrets/pr-creds/key.pem \
ORG=openshift \
REPO=microshift \
AMD64_RELEASE=${pullspec_release_amd64} \
ARM64_RELEASE=${pullspec_release_arm64} \
DRY_RUN=1 \
./scripts/auto-rebase/rebase.py

stat=$?
echo "rebase.py exit code: ${stat}"

git status || true
git branch || true
git --no-pager log --decorate=short --pretty=oneline -n20 || true
git diff main || true

exit "${stat}"
