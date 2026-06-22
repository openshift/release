#!/usr/bin/env python3
import sys
import os
import argparse
import csv
from pathlib import Path
from google.oauth2 import service_account
from googleapiclient.discovery import build

SCOPES = ['https://www.googleapis.com/auth/spreadsheets']

DEFAULT_AMD64_SHEET_ID = "1hDOqRCRZ0Q-hro1RF29sAtChjSN3hUMLDobHxiulVWE"
DEFAULT_ARM64_SHEET_ID = "1r4cCmJ83OIkdlzgmJ2fy2nWgA6wtzFxydfArb5mpKjg"

def get_credentials_from_env():
    """Reads the service account key path from the standard GOOGLE_APPLICATION_CREDENTIALS environment variable."""
    env_var = "GOOGLE_APPLICATION_CREDENTIALS"
    path_str = os.environ.get(env_var)

    if not path_str or not Path(path_str).exists():
        print(f"\n❌ Error: Valid key path missing in env '{env_var}'!", file=sys.stderr)
        sys.exit(1)

    print(f"🔑 Service Account credentials found: {Path(path_str).name}")
    try:
        return service_account.Credentials.from_service_account_file(path_str, scopes=SCOPES)
    except Exception:
        print(f"❌ Error: Failed to parse credentials file.")
        sys.exit(1)

def get_sheet_id_mapping(service, spreadsheet_id):
    """Fetches spreadsheet metadata to build a runtime title-to-id dictionary map once."""
    try:
        meta = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
        return {s['properties']['title']: s['properties']['sheetId'] for s in meta.get('sheets', [])}
    except Exception:
        print(f"❌ Error: Failed to fetch spreadsheet metadata.")
        sys.exit(1)

def apply_borders_and_clear(service, spreadsheet_id, sheet_id, total_rows, max_cols):
    """Clears old formatting/cells and draws clean grid borders using a compact batch request."""
    style = {"style": "SOLID", "color": {"red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 1.0}}
    box_range = {"sheetId": sheet_id, "startRowIndex": 1, "endRowIndex": 1 + total_rows, "startColumnIndex": 0, "endColumnIndex": max_cols}

    body = {
        "requests": [
            # Clears values and formatting starting from Row 2 down
            {"updateCells": {"range": {"sheetId": sheet_id, "startRowIndex": 1}, "fields": "userEnteredValue,userEnteredFormat"}},
            # Draws structural grid borders over the new dataset dimensions
            {"updateBorders": {"range": box_range, "top": style, "bottom": style, "left": style, "right": style, "innerHorizontal": style, "innerVertical": style}}
        ]
    }
    service.spreadsheets().batchUpdate(spreadsheetId=spreadsheet_id, body=body).execute()

def process_tsv_file(service, spreadsheet_id, sheet_id_map, tsv_file_path):
    """Reads TSV, clears old context, updates new cells, and applies borders cleanly."""
    tab_title = tsv_file_path.stem

    if tab_title not in sheet_id_map:
        print(f"❌ {tab_title} skip as the sheet not found")
        return

    rows_to_upload = []
    max_cols = 0
    with open(tsv_file_path, "r", encoding="utf-8", errors="ignore") as f:
        for row in csv.reader(f, delimiter="\t"):
            rows_to_upload.append(row)
            max_cols = max(max_cols, len(row))

    if not rows_to_upload:
        print(f"⚠️ Skipping empty file: {tsv_file_path.name}")
        return

    # 1. Reset cell data space and draw fresh bounding box borders
    apply_borders_and_clear(service, spreadsheet_id, sheet_id_map[tab_title], len(rows_to_upload), max_cols)

    # 2. Paste standard structural matrix arrays into cell blocks starting at position A2
    service.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=f"'{tab_title}'!A2",
        valueInputOption='USER_ENTERED',
        body={'values': rows_to_upload}
    ).execute()

    print(f"🚀 Successfully synced {len(rows_to_upload)} rows into tab '{tab_title}'")

def main():
    parser = argparse.ArgumentParser(description="Paste TSV data directly into existing Google Sheets tabs.")
    parser.add_argument("-s", "--sheet-id", default=None, help="The Google Spreadsheet ID (Overrides default architecture ID)")
    parser.add_argument("-d", "--dir", default="./processed_jobs", help="Root directory where TSV folders are located (Default: processed_jobs)")
    parser.add_argument("-a", "--arch", choices=["amd64", "arm64"], help="Filter architecture folder & set default sheet ID")

    args = parser.parse_args()

    sheet_id = args.sheet_id
    if not sheet_id:
        if args.arch == "amd64":
            sheet_id = DEFAULT_AMD64_SHEET_ID
        elif args.arch == "arm64":
            sheet_id = DEFAULT_ARM64_SHEET_ID
        else:
            print("\n❌ Error: Please specify a --sheet-id (-s) OR provide an explicit architecture via --arch (-a) to use defaults!", file=sys.stderr)
            sys.exit(1)

    service = build('sheets', 'v4', credentials=get_credentials_from_env())

    root_dir = Path(args.dir)
    if not root_dir.exists():
        print(f"❌ Error: Directory '{root_dir}' does not exist.", file=sys.stderr)
        sys.exit(1)

    tsv_files = sorted(list(root_dir.rglob("*.tsv")))
    if args.arch:
        tsv_files = [f for f in tsv_files if args.arch in f.parts]

    if not tsv_files:
        print(f"🔍 No matching .tsv files found to process in directory: '{args.dir}'")
        return

    print(f"📝 Found {len(tsv_files)} TSV file(s) to process.\n")

    sheet_id_map = get_sheet_id_mapping(service, sheet_id)

    for tsv_path in tsv_files:
        try:
            process_tsv_file(service, sheet_id, sheet_id_map, tsv_path)
        except Exception as e:
            print(f"❌ Critical error processing {tsv_path.name}: {e}\n", file=sys.stderr)

if __name__ == "__main__":
    main()
