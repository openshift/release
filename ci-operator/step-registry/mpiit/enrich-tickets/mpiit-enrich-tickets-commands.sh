#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset -a jiraConfigCmd=(
    firewatch jira-config-gen
    --token-path "${FIREWATCH_JIRA_API_TOKEN_PATH}"
    --server-url "${FIREWATCH_JIRA_SERVER}"
)

if [ -f "${FIREWATCH_JIRA_EMAIL_PATH}" ]; then
    set +x
    jiraConfigCmd+=(--email "$(cat "${FIREWATCH_JIRA_EMAIL_PATH}")")
    set -x
fi

"${jiraConfigCmd[@]}"

python3 << 'ENRICH_TICKETS'
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import urllib.error

import jira as jira_lib
import junitparser
from google.cloud import storage

OPERATOR_RE = re.compile(r'[\w.-]+-operator\b', re.IGNORECASE)
LOCATION_RE = re.compile(r'[\w/.-]+\.go:\d+', re.IGNORECASE)
OPERATOR_CAP = 5
COMPONENT_CAP = 3
LOCATION_CAP = 3
EXCERPT_MAX = 500
SENSITIVE_RE = re.compile(
    r'(?:password|passwd|token|secret|key|credential|auth(?:orization)?)[=:\s]+\S+',
    re.IGNORECASE,
)
ALLOWED_CHAI_DOMAINS = (".redhat.com", ".redhat.net")


def load_jira_config(path="/tmp/jira.config"):
    with open(path) as f:
        return json.load(f)


def connect_jira(config):
    kwargs = {
        "server": config["url"],
        "options": {"rest_api_version": "3"},
    }
    if config.get("email"):
        kwargs["basic_auth"] = (config["email"], config["token"])
    else:
        kwargs["token_auth"] = config["token"]
    return jira_lib.JIRA(**kwargs)


def find_firewatch_tickets(jira_conn, job_name, build_id, search_window_minutes, target_override=False):
    if target_override:
        jql = (
            f'labels = "{job_name}" '
            f'AND labels = "firewatch" '
            f'AND issuetype = Bug '
            f'ORDER BY created DESC'
        )
    else:
        jql = (
            f'labels = "{job_name}" '
            f'AND labels = "firewatch" '
            f'AND created >= "-{search_window_minutes}m" '
            f'AND issuetype = Bug '
            f'ORDER BY created DESC'
        )
    print(f"JQL: {jql}")
    issues = jira_conn.search_issues(jql, maxResults=20)
    print(f"Found {len(issues)} recent firewatch ticket(s)")

    if not build_id or not issues:
        return issues

    matched = []
    for issue in issues:
        desc = getattr(issue.fields, "description", None) or ""
        if isinstance(desc, dict):
            desc = json.dumps(desc)
        if build_id in str(desc):
            matched.append(issue)

    if matched:
        print(f"Narrowed to {len(matched)} ticket(s) matching build {build_id}")
        return matched

    print(f"No tickets contained build {build_id}; using all {len(issues)} candidate(s)")
    return issues


def get_step_from_labels(issue):
    labels = issue.fields.labels or []
    skip = {"firewatch", "pod_failure", "test_failure"}
    job_name = os.environ.get("JOB_NAME", "")
    for label in labels:
        if label in skip or label == job_name:
            continue
        if label.startswith("slack-") or label.startswith("operator:") or label.startswith("component:"):
            continue
        if not label.startswith("periodic-") and not label.startswith("pull-"):
            return label
    return None


def download_junit_from_gcs(job_name, build_id, gcs_bucket):
    client = storage.Client.create_anonymous_client()
    bucket = client.bucket(gcs_bucket)

    prefix = f"logs/{job_name}/{build_id}/artifacts/"

    print(f"Scanning GCS prefix: gs://{gcs_bucket}/{prefix}")

    junit_files = {}
    blobs = bucket.list_blobs(prefix=prefix)
    for blob in blobs:
        if blob.name.endswith(".xml") and "junit" in blob.name.lower():
            path_parts = blob.name.replace(prefix, "").split("/")
            if len(path_parts) >= 3:
                step_name = path_parts[1]
            elif len(path_parts) == 2:
                step_name = path_parts[0]
            else:
                step_name = "unknown"
            content = blob.download_as_text()
            junit_files.setdefault(step_name, []).append(content)

    print(f"Downloaded {sum(len(v) for v in junit_files.values())} JUnit file(s) across {len(junit_files)} step(s)")
    return junit_files


def extract_failure_metadata(junit_xml_content):
    failures = []
    try:
        xml = junitparser.JUnitXml.fromstring(junit_xml_content)
    except Exception:
        return failures

    for item in xml:
        cases = [item] if isinstance(item, junitparser.TestCase) else item
        for case in cases:
            if not hasattr(case, "result") or not case.result:
                continue
            for result in case.result:
                if not isinstance(result, (junitparser.Failure, junitparser.Error)):
                    continue

                message = getattr(result, "message", "") or ""
                body = result.text or ""
                search_text = f"{case.classname or ''} {case.name or ''} {message} {body}"

                excerpt = (message + "\n" + body).strip()[:EXCERPT_MAX]

                operators = sorted({m.group(0).lower() for m in OPERATOR_RE.finditer(search_text)})[:OPERATOR_CAP]

                components = set()
                classname = case.classname or ""
                name = case.name or ""
                if classname:
                    parts = classname.rsplit(".", 1)
                    comp = parts[-1] if len(parts) > 1 else parts[0]
                    comp = re.sub(r'^Test', '', comp)
                    comp = re.sub(r'[^a-zA-Z0-9_-]', '', comp).lower()
                    if comp:
                        components.add(comp)
                elif name:
                    comp = name.split("/")[0]
                    comp = re.sub(r'^Test', '', comp)
                    comp = re.sub(r'[^a-zA-Z0-9_-]', '', comp).lower()
                    if comp:
                        components.add(comp)
                component_list = sorted(components)[:COMPONENT_CAP]

                locations = sorted({m.group(0) for m in LOCATION_RE.finditer(search_text)})[:LOCATION_CAP]

                failures.append({
                    "test_name": name,
                    "excerpt": excerpt,
                    "operators": operators,
                    "components": component_list,
                    "locations": locations,
                })
    return failures


def is_approved_chai_url(url):
    try:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https":
            return False
        hostname = parsed.hostname or ""
        return any(hostname.endswith(d) for d in ALLOWED_CHAI_DOMAINS)
    except Exception:
        return False


def redact_sensitive_values(text):
    return SENSITIVE_RE.sub("[REDACTED]", text)


def call_chai(api_url, api_token, job_name, build_id, step_name, test_name, excerpt):
    if not api_url:
        return None

    if not is_approved_chai_url(api_url):
        print(f"WARN: CHAI_API_URL is not an approved internal endpoint; skipping", file=sys.stderr)
        return None

    safe_excerpt = redact_sensitive_values(excerpt)

    prompt = (
        f"Analyze this CI test failure and provide a brief root cause analysis.\n\n"
        f"Job: {job_name}\n"
        f"Build: {build_id}\n"
        f"Failed Step: {step_name}\n"
        f"Failed Test: {test_name}\n"
        f"Error Excerpt:\n{safe_excerpt}\n\n"
        f"Provide:\n"
        f"1. Likely root cause (1-2 sentences)\n"
        f"2. Whether this matches any known issues\n"
        f"3. Suggested next action"
    )

    payload = json.dumps({"question": prompt}).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_token}",
    }
    req = urllib.request.Request(api_url, data=payload, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            return result.get("answer") or result.get("text") or str(result)
    except (urllib.error.URLError, TimeoutError, Exception) as e:
        print(f"WARN: Chai API call failed: {e}", file=sys.stderr)
        return None


def build_enrichment_comment(step_name, failures, chai_analysis=None):
    lines = ["h3. Enrichment (automated)"]

    if chai_analysis:
        lines.append("")
        lines.append("h4. AI Root Cause Analysis")
        lines.append(f"{{noformat}}{chai_analysis}{{noformat}}")

    if not failures:
        lines.append("")
        lines.append("No JUnit failures found for this step in GCS artifacts.")
        return "\n".join(lines)

    lines.append("")
    lines.append(f"h4. Failure Details ({len(failures)} failure(s))")

    for i, f in enumerate(failures, 1):
        lines.append("")
        lines.append(f"*Failure {i}*: {f['test_name']}")
        if f["operators"]:
            lines.append(f"Operators: {', '.join(f['operators'])}")
        if f["components"]:
            lines.append(f"Components: {', '.join(f['components'])}")
        if f["locations"]:
            lines.append(f"Locations: {', '.join(f['locations'])}")
        if f["excerpt"]:
            lines.append(f"{{noformat}}{redact_sensitive_values(f['excerpt'])}{{noformat}}")

    return "\n".join(lines)


def collect_labels(failures):
    labels = set()
    for f in failures:
        for op in f["operators"]:
            labels.add(f"operator:{op}")
        for comp in f["components"]:
            labels.add(f"component:{comp}")
    return sorted(labels)


def enrich_ticket(jira_conn, issue, step_failures, chai_analysis=None):
    step_name = get_step_from_labels(issue)
    failures = step_failures.get(step_name, [])

    new_labels = collect_labels(failures)
    existing_labels = set(issue.fields.labels or [])
    labels_to_add = [l for l in new_labels if l not in existing_labels]

    comment_body = build_enrichment_comment(step_name, failures, chai_analysis)

    if labels_to_add:
        issue.update(fields={"labels": list(existing_labels | set(labels_to_add))})
        print(f"  Added {len(labels_to_add)} label(s): {labels_to_add}")

    jira_conn.add_comment(issue.key, comment_body)
    print(f"  Added enrichment comment to {issue.key}")


def main():
    target = os.environ.get("FIREWATCH_ENRICH_TARGET_JOB", "")
    target_override = bool(target)
    if target:
        parts = target.rsplit("/", 1)
        if len(parts) != 2 or not parts[0] or not parts[1]:
            print(f"ERROR: FIREWATCH_ENRICH_TARGET_JOB must be 'job-name/build-id', got: {target}", file=sys.stderr)
            sys.exit(1)
        job_name, build_id = parts
        print(f"Using target override: {job_name} / {build_id}")
    else:
        job_name = os.environ.get("JOB_NAME", "")
        build_id = os.environ.get("BUILD_ID", "")

    gcs_bucket = "test-platform-results"
    search_window = os.environ.get("FIREWATCH_ENRICH_SEARCH_WINDOW", "10")
    chai_api_url = os.environ.get("MPIIT__CHAI_API_URL", "")
    chai_api_token = os.environ.get("MPIIT__CHAI_API_TOKEN", "")

    if not job_name or not build_id:
        print("ERROR: JOB_NAME and BUILD_ID must be set", file=sys.stderr)
        sys.exit(1)

    print(f"Job: {job_name}")
    print(f"Build: {build_id}")
    print(f"Chai API: {'enabled' if chai_api_url else 'disabled'}")

    config = load_jira_config()
    jira_conn = connect_jira(config)
    print("Jira authentication successful")

    tickets = find_firewatch_tickets(
        jira_conn, job_name, build_id, search_window, target_override=target_override,
    )
    if not tickets:
        print("No recent firewatch tickets found; nothing to enrich.")
        return

    print(f"\nDownloading JUnit artifacts from GCS...")
    junit_by_step = download_junit_from_gcs(job_name, build_id, gcs_bucket)

    step_failures = {}
    for step_name, xml_contents in junit_by_step.items():
        all_failures = []
        for xml_content in xml_contents:
            all_failures.extend(extract_failure_metadata(xml_content))
        if all_failures:
            step_failures[step_name] = all_failures
    print(f"Extracted failures from {len(step_failures)} step(s)")

    failed_keys = []
    for issue in tickets:
        try:
            step_name = get_step_from_labels(issue)
            print(f"\nProcessing {issue.key} (step: {step_name})")

            chai_analysis = None
            failures = step_failures.get(step_name, [])
            if chai_api_url and failures:
                best_failure = failures[0]
                chai_analysis = call_chai(
                    chai_api_url, chai_api_token,
                    job_name, build_id, step_name,
                    best_failure["test_name"], best_failure["excerpt"],
                )
                if chai_analysis:
                    print(f"  Chai analysis received ({len(chai_analysis)} chars)")

            enrich_ticket(jira_conn, issue, step_failures, chai_analysis)
        except Exception as exc:
            print(f"  ERROR enriching {issue.key}: {exc}", file=sys.stderr)
            failed_keys.append(issue.key)

    enriched = len(tickets) - len(failed_keys)
    print(f"\nDone. Enriched {enriched}/{len(tickets)} ticket(s).")
    if failed_keys:
        print(f"Failed: {', '.join(failed_keys)}", file=sys.stderr)

main()
ENRICH_TICKETS
true
