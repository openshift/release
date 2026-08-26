#!/usr/bin/env python3
"""Verify that every commit in a pull request is signed and verified by GitHub.

Queries the GitHub REST API for the PR's commits and checks each commit's
verification status (https://docs.github.com/rest/pulls/pulls#list-commits-on-a-pull-request).
Exits non-zero if any commit is unsigned, listing the offending commits and
guidance for the author. Outside a presubmit context (no PULL_NUMBER), the
check is a no-op.

See DPTP-4919: OCP is migrating repos that promote into the product to
require signed commits.
"""

import json
import os
import sys
import urllib.error
import urllib.request

API_BASE = os.environ.get("GITHUB_API_BASE", "https://api.github.com")
PER_PAGE = 100
SIGNING_DOCS = "https://docs.github.com/authentication/managing-commit-signature-verification/signing-commits"


def github_request(url, token):
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def list_pr_commits(owner, repo, number, token):
    commits = []
    page = 1
    while True:
        url = f"{API_BASE}/repos/{owner}/{repo}/pulls/{number}/commits?per_page={PER_PAGE}&page={page}"
        batch = github_request(url, token)
        commits.extend(batch)
        if len(batch) < PER_PAGE:
            return commits
        page += 1


def main():
    number = os.environ.get("PULL_NUMBER")
    if not number:
        print("PULL_NUMBER is not set; not a presubmit context, nothing to verify.")
        return 0

    owner = os.environ["REPO_OWNER"]
    repo = os.environ["REPO_NAME"]

    token = ""
    token_path = os.environ.get("GITHUB_TOKEN_PATH", "")
    if token_path and os.path.exists(token_path):
        with open(token_path, encoding="utf-8") as f:
            token = f.read().strip()
    else:
        print("warning: no GitHub token available, using unauthenticated requests")

    try:
        commits = list_pr_commits(owner, repo, number, token)
    except urllib.error.HTTPError as e:
        print(f"error: GitHub API request failed: {e.code} {e.reason}")
        return 1

    report = []
    unsigned = []
    for commit in commits:
        sha = commit["sha"]
        verification = commit["commit"].get("verification", {})
        verified = verification.get("verified", False)
        reason = verification.get("reason", "unknown")
        report.append({"sha": sha, "verified": verified, "reason": reason})
        marker = "ok" if verified else "UNSIGNED"
        print(f"{marker:>8}  {sha}  ({reason})")
        if not verified:
            unsigned.append(sha)

    artifact_dir = os.environ.get("ARTIFACT_DIR")
    if artifact_dir:
        with open(os.path.join(artifact_dir, "commit_report.json"), "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)

    if unsigned:
        print()
        print(f"{len(unsigned)} of {len(commits)} commits in this pull request are not signed with a")
        print("signature GitHub can verify. Sign your commits and force-push the branch:")
        print(f"  {SIGNING_DOCS}")
        print("An existing branch can be re-signed in place with:")
        print("  git rebase --exec 'git commit --amend --no-edit -S' main")
        return 1

    print(f"\nAll {len(commits)} commits are signed and verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
