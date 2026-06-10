#!/bin/bash

set -euo pipefail

echo "Checking GPG signature status for PR #350 in openshift/must-gather-operator..."

commits_json=$(curl -sS -f \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/openshift/must-gather-operator/pulls/350/commits?per_page=100")

python3 -c '
import json, sys

commits = json.loads(sys.stdin.read())
total = len(commits)
unsigned = 0

for c in commits:
    sha = c["sha"][:12]
    author = c["commit"]["author"]["name"]
    verified = c["commit"]["verification"]["verified"]
    if verified:
        print(f"  [SIGNED]   {sha} — {author}")
    else:
        reason = c["commit"]["verification"]["reason"]
        print(f"  [UNSIGNED] {sha} — {author} (reason: {reason})")
        unsigned += 1

print(f"\nTotal commits: {total}, Unsigned: {unsigned}")

if unsigned > 0:
    print(f"ERROR: {unsigned} commit(s) are not GPG-signed. All commits must be signed.")
    sys.exit(1)

print(f"All {total} commit(s) are GPG-signed.")
' <<< "${commits_json}"
