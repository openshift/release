#!/usr/bin/env python
import os.path

from datetime import datetime
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.auth.transport.requests import Request

# If modifying these scopes, delete the file token.json.
SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]

# The ID and range of a sample spreadsheet.
SAMPLE_SPREADSHEET_ID = "1j8TjMfyCfEt8OzTgvrAG3tuC6WMweBh5ElzWu6oAvUw"
SAMPLE_RANGE_NAME = "CI!A2:E6"

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

def create_sheet(sheet_title, spreadsheet_id):
  global creds
  try:
    build("sheets", "v4", credentials=creds).spreadsheets().batchUpdate(
      spreadsheetId=spreadsheet_id,
      body={"requests": [{"addSheet": {"properties": {"title": sheet_title, "index": 2}}}]}
    ).execute()
  except (HttpError, Exception) as e:
    raise Exception(f"Error occurred while creating sheet: {e}")

def fetch_spreadsheet_data():
  global creds
  try:
    service = build("sheets", "v4", credentials=creds)
    sheet = service.spreadsheets()
    result = sheet.values().get(spreadsheetId=SAMPLE_SPREADSHEET_ID, range=SAMPLE_RANGE_NAME).execute()
    values = result.get("values", [])

    if not values:
      print("No data found.")
      return
    print("Name, Major:")
    for row in values:
      for item in row:
        print(item, end=" ")
      print()
  except HttpError as err:
    print(f"An error occurred: {err}")
  except Exception as e:
    print(f"Unexpected error: {e}")


def main():
  init()
  fetch_spreadsheet_data()
  sheet_title = f"{os.getenv('HOSTEDCLUSTER_PLATFORM')}-{datetime.now().strftime('%Y-%m-%d')}"
  create_sheet(sheet_title, SAMPLE_SPREADSHEET_ID)


if __name__ == "__main__":
    main()