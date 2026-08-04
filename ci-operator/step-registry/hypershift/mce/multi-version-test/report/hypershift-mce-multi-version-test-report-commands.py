#!/usr/bin/env python
import json
import os.path
import re
import urllib.request

from dataclasses import dataclass
from datetime import datetime
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.auth.transport.requests import Request

SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
SAMPLE_SPREADSHEET_ID = "1g4EFkOrcr6D4WJKo4O8bmOK7txA4ZRTfqFazHtCoM3E"
# Sheet/tab ID of the template tab that will be copied to create a new tab and
# filled with the job data
# The tab id is available in the URL of the template tab after "gid="
TEMPLATE_TAB_ID = "1597804194"
TOKEN_PATH = "/secret/ga-gsheet/googlesheet-api-token"
GCSWEB_BASE = "https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
TEST_STEPS = [
    "conformance-tests", "csi-conformance-tests",
    "hypershift-aws-run-e2e-external", "hypershift-aws-run-e2e-nested",
    "hypershift-aws-run-reqserving-e2e",
    "hypershift-azure-run-e2e", "hypershift-azure-run-e2e-self-managed",
    "hypershift-gcp-run-e2e",
    "hypershift-openstack-e2e-execute",
    "openstack-test-dpdk", "openstack-test-sriov",
    "run-e2e", "run-e2e-local", "run-e2e-external", "tests",
]

@dataclass
class Job:
    hub_version: str
    mce_version: str
    guest_version: str
    platform: str
    job: str
    job_url: str
    status: str

class JobList:
    def __init__(self, fields):
        self.fields = fields
        self.joblist_data = []

    def add_row(self, job: Job):
        self.joblist_data.append(list(job.__dict__.values()))

    def to_values(self):
        return [self.fields] + self.joblist_data

    def range(self):
        return f"A1:H{len(self.joblist_data) + 1}"


def init():
    global creds
    if not os.path.exists(TOKEN_PATH):
        raise FileNotFoundError("The token file does not exist. Please authorize first.")

    creds = service_account.Credentials.from_service_account_file(TOKEN_PATH, scopes=SCOPES)

def create_sheet(sheet_title):
    global creds
    new_sheet_id = None
    try:
        service = build("sheets", "v4", credentials=creds)
        copy_response = service.spreadsheets().sheets().copyTo(
            spreadsheetId=SAMPLE_SPREADSHEET_ID,
            sheetId=TEMPLATE_TAB_ID,
            body={"destinationSpreadsheetId": SAMPLE_SPREADSHEET_ID}
        ).execute()
        new_sheet_id = copy_response["sheetId"]
        service.spreadsheets().batchUpdate(
            spreadsheetId=SAMPLE_SPREADSHEET_ID, body={
            "requests": [
                {
                    "updateSheetProperties": {
                        "properties": {"sheetId": new_sheet_id, "title": sheet_title, "index": 2 },
                        "fields": "title,index"
                    }
                }
            ]
        }
        ).execute()
    except (HttpError, Exception) as e:
        if new_sheet_id is not None:
            try:
                service.spreadsheets().batchUpdate(
                    spreadsheetId=SAMPLE_SPREADSHEET_ID, body={
                    "requests": [{"deleteSheet": {"sheetId": new_sheet_id}}]
                }).execute()
            except Exception:
                print(f"Failed to clean up orphaned sheet {new_sheet_id}")
        raise Exception(f"Error occurred while creating sheet: {e}")

def determine_status(job_status, job_url, job_name):
    """Determine emoji status by checking GCS for test step artifacts.

    - SUCCESS → 🟢
    - FAILURE + test step finished.json exists → 🟡 (tests ran and failed)
    - Everything else → 🔴 (install failed, trigger failed, etc.)
    """
    if job_status == "SUCCESS":
        return "\U0001F7E2" # 🟢 all pass
    if job_status != "FAILURE" or not job_url:
        return "\U0001F534" # 🔴 install failed, trigger failed, etc.

    # Extract job name and build ID from Prow deck URL
    # e.g. https://prow.ci.openshift.org/view/gs/test-platform-results/logs/<job-name>/<build-id>
    url_match = re.search(r'/logs/([^/]+)/(\d+)', job_url)
    if not url_match:
        return "\U0001F534"
    prow_job_name = url_match.group(1)
    build_id = url_match.group(2)

    # Derive test target from job name
    # e.g. periodic-ci-openshift-hypershift-release-4.22-periodics-mce-e2e-aws-critical → e2e-aws-critical
    target_match = re.match(r'periodic-ci-openshift-hypershift-release-[\d.]+-periodics(?:-mce)?-(.+)', prow_job_name)
    if not target_match:
        return "\U0001F534" # 🔴 install failed, trigger failed, etc.
    test_target = target_match.group(1)

    artifacts_base = f"{GCSWEB_BASE}/logs/{prow_job_name}/{build_id}/artifacts/{test_target}"
    for step in TEST_STEPS:
        url = f"{artifacts_base}/{step}/finished.json"
        try:
            resp = urllib.request.urlopen(url, timeout=10)
            data = json.loads(resp.read())
            # There can be passed=true or passed=false in the finished.json file.
            # The presence of "passed" indicates that the test step finished.
            if "passed" in data:
                return "\U0001F7E1" # 🟡 case failed
        except Exception:
            continue
    return "\U0001F534" # 🔴 install failed, trigger failed, etc.


def writing_to_sheet(sheet_name, obj):
  global creds
  try:
    service = build("sheets", "v4", credentials=creds)
    service.spreadsheets().values().update(
      spreadsheetId=SAMPLE_SPREADSHEET_ID,
      range=f"{sheet_name}!{obj.range()}",
      valueInputOption="USER_ENTERED",
      body={"majorDimension": "ROWS","values": obj.to_values()}
    ).execute()
  except Exception as e:
    print(f"Failed to write to sheet {sheet_name}: {e}")

def main():
    init()
    sheet_title = f"{os.getenv('HOSTEDCLUSTER_PLATFORM')}-{datetime.now().strftime('%Y-%m-%d-%H%M')}"
    create_sheet(sheet_title)

    joblist = JobList(fields=["HUB", "MCE", "HostedCluster", "Platform", "Job", "Job URL", "Status: \U0001F534 install failed \U0001F7E1 case failed \U0001F7E2 all pass \U0001F535 need to check"])
    job_list_path = os.path.join(os.environ.get("SHARED_DIR"), "job_list")
    with open(job_list_path, 'r') as file:
        for line in file:
            print(line, end=" ")
            job_data = {key.strip(): value.strip() for key, value in (part.split("=") for part in line.strip().split(", "))}
            status = determine_status(job_data.get("JOB_STATUS", ""), job_data.get("JOB_URL", ""), job_data.get("JOB", ""))
            joblist.add_row(Job(
                hub_version=job_data.get("HUB", ""),
                mce_version=job_data.get("MCE", ""),
                guest_version=job_data.get("HostedCluster", ""),
                platform=job_data.get("PLATFORM", ""),
                job=job_data.get("JOB", ""),
                job_url=job_data.get("JOB_URL", ""),
                status=status
            ))
    writing_to_sheet(sheet_title, joblist)

if __name__ == "__main__":
    main()