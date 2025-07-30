#!/usr/bin/env python
import os.path

from dataclasses import dataclass
from datetime import datetime
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.auth.transport.requests import Request

# If modifying these scopes, delete the file token.json.
SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
SAMPLE_SPREADSHEET_ID = "1j8TjMfyCfEt8OzTgvrAG3tuC6WMweBh5ElzWu6oAvUw"

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
    if not os.path.exists("/secret/ga-gsheet/token.json"):
        raise FileNotFoundError("The token.json file does not exist. Please authorize first.")

    creds = Credentials.from_authorized_user_file("/secret/ga-gsheet/token.json", SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            raise ValueError("The token.json is invalid or expired. Please reauthorize.")


def create_sheet(sheet_title):
    global creds
    try:
        copy_response = build("sheets", "v4", credentials=creds).spreadsheets().sheets().copyTo(
            spreadsheetId=SAMPLE_SPREADSHEET_ID,
            sheetId=772427170,
            body={"destinationSpreadsheetId": SAMPLE_SPREADSHEET_ID}
        ).execute()
        new_sheet_id = copy_response["sheetId"]
        build("sheets", "v4", credentials=creds).spreadsheets().batchUpdate(
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
        raise Exception(f"Error occurred while creating sheet: {e}")

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
    sheet_title = f"{os.getenv('HOSTEDCLUSTER_PLATFORM')}-{datetime.now().strftime('%Y-%m-%d')}"
    create_sheet(sheet_title)

    joblist = JobList(fields=["HUB", "MCE", "HostedCluster", "Platform", "Job", "Job ID", "Status: \U0001F534 install failed \U0001F7E1 case failed \U0001F7E2 all pass \U0001F535 need to check"])
    job_list_path = os.path.join(os.environ.get("SHARED_DIR"), "job_list")
    with open(job_list_path, 'r') as file:
        for line in file:
            print(line, end=" ")
            job_data = {key.strip(): value.strip() for key, value in (part.split("=") for part in line.strip().split(", "))}
            status = "\U0001F7E2" if job_data.get("JOB_STATUS") == "SUCCESS" else "\U0001F535"
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