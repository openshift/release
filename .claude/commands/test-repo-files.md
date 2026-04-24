---
description: Validate that repo file URLs (mirror2 and CDN) resolve correctly after editing ocp-*.repo files
args: "[file-pattern]"
allowed-tools: Read, Bash, AskUserQuestion
---

# Test Repo Files

You are helping the user validate that `core-services/release-controller/_repos/ocp-*.repo` files have correct URLs after editing.

## Command Arguments

This command accepts an optional argument: `/test-repo-files [file-pattern]`
- If a pattern is provided (e.g., `4.22`, `ocp-4.22-rhel98`, `5.0`), find matching `.repo` files in `core-services/release-controller/_repos/`
  - A version like `4.22` matches all `ocp-4.22-*.repo` files
  - A more specific pattern like `ocp-4.22-rhel9` matches that specific file
- If no argument is provided, detect which `ocp-*.repo` files have been modified vs `main` branch using `git diff --name-only main -- core-services/release-controller/_repos/*.repo`
- If no files found either way, ask the user which files to test

## Steps to follow

For each repo file found, run these validation steps:

### Step 1: Validate mirror2 paths

Extract all `baseurl` lines pointing to `mirror2.openshift.com` from the repo file. For each URL:

```bash
curl -sk -o /dev/null -w "%{http_code}" "${url}/repodata/repomd.xml"
```

- **401** = PASS (auth required means the path exists on the server)
- **404** = FAIL (path does not exist)
- Any other code = WARN (unexpected, report to user)

### Step 2: Validate CDN paths

Extract all `baseurl` lines pointing to `cdn.redhat.com` from the repo file. For each URL, replace `cdn.redhat.com` with `rhsm-pulp.corp.redhat.com` and test:

```bash
url_to_test=$(echo "$url" | sed 's/cdn.redhat.com/rhsm-pulp.corp.redhat.com/')
curl -sk -o /dev/null -w "%{http_code}" "${url_to_test}/repodata/repomd.xml"
```

- **200** = PASS
- **404** = FAIL (path does not exist)
- Any other code = WARN (could mean VPN is not connected; tell the user that CDN validation requires Red Hat VPN)

### Step 3: dnf wrapper container test (optional)

This step requires:
- `podman` available and working
- A pre-built `dnf-wrapper-test` container image (built from the `ocp-build-data` repo, branch `openshift-<version>`, file `ci_images/dnf_wrapper_test.Dockerfile`)

Check if podman is available and if the `dnf-wrapper-test` image exists:
```bash
podman image exists dnf-wrapper-test
```

If either is unavailable, ask the user if they want to skip this step. If skipping, report "dnf wrapper: SKIPPED".

If running:
1. Pick a random available port (e.g., between 18080-18099)
2. Copy the repo file to a temp directory as `index.html`
3. Start a local HTTP server: `cd /tmp/repo-test-dir && python3 -m http.server <port> &>/dev/null &`
4. Wait 1 second for the server to start
5. Run the container:
   ```bash
   podman run --network=host -e CI_RPM_SVC=http://localhost:<port>/ --rm dnf-wrapper-test dnf search vim 2>&1
   ```
6. Check output for `Status code: 404` lines — any 404 means FAIL
7. Kill the HTTP server and clean up temp directory
8. Report results

### Output format

Present results in a clear summary per file:

```
=== ocp-4.22-rhel9.repo ===
mirror2 paths: 10/10 OK (all 401)
CDN paths:      8/8 OK (all 200)
dnf wrapper:   PASS (0 paths returned 404)
```

If any step has failures, list the failing URLs:
```
=== ocp-4.22-rhel9.repo ===
mirror2 paths: 8/10 FAIL
  FAIL (404): https://mirror2.openshift.com/enterprise/reposync/4.22/rhel-98-baseos-aarch64
  FAIL (404): https://mirror2.openshift.com/enterprise/reposync/4.22/rhel-98-baseos-ppc64le
CDN paths:      8/8 OK (all 200)
dnf wrapper:   FAIL (2 paths returned 404)
```

## Important notes

- CDN path validation requires being connected to the Red Hat VPN. If CDN checks fail with non-200/non-404 codes, remind the user to check their VPN connection.
- The dnf wrapper test runs the container with `--network=host` so it can reach the local HTTP server.
- Always clean up HTTP servers and temp directories after testing, even if errors occur.
- Run all mirror2 URL checks in a single loop for efficiency rather than one curl per tool call.
