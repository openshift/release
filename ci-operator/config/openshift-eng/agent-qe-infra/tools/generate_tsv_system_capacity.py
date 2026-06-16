#!/usr/bin/env python3
import sys
import argparse
import re
from pathlib import Path

YEAR = 2026
MONTH = 6
PAD_MONTH = f"{MONTH:02d}"

RE_VERSION = re.compile(r"[45]\.[0-9]+")
RE_NON_DIGIT = re.compile(r"\D+")

def clean_name(base: str) -> str:
    versions = RE_VERSION.findall(base)
    version = versions[-1] if versions else ""
    suffix = base.partition("__")[-1] if "__" in base else base
    return f"{version}__{suffix}"

def process_file(file_path: Path, base_output_dir: Path):
    file_name_lower = file_path.name.lower()

    if "arm" in file_name_lower:
        output_dir = base_output_dir / "arm64"
    elif "amd" in file_name_lower:
        output_dir = base_output_dir / "amd64"
    elif "multi" in file_name_lower:
        output_dir = base_output_dir / "multi"
    else:
        output_dir = base_output_dir

    job = cron = ""
    aux = False
    masters = workers = add_workers = 0
    records = []
    clean = clean_name(file_path.stem)

    append_record = records.append
    strip_non_digits = RE_NON_DIGIT.sub

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if "cron:" in line:
                cron = line.partition("cron:")[-1].strip()

            elif "masters:" in line:
                val = strip_non_digits("", line)
                masters = int(val) if val else 0

            elif "workers:" in line:
                val = strip_non_digits("", line)
                workers = int(val) if val else 0

            elif "ADDITIONAL_WORKERS:" in line:
                val = strip_non_digits("", line)
                add_workers = int(val) if val else 0

            elif "AUX_HOST:" in line:
                aux = True

            elif line.startswith("tests:") or line.startswith("- as:"):
                if job and cron and aux:
                    parts = cron.split()
                    if len(parts) >= 3:
                        minute, hour, days_str = parts[0], parts[1], parts[2]
                        systems = masters + workers + add_workers

                        for d in days_str.split(","):
                            if d.isdigit():
                                append_record(
                                    f"{job}\t\"{cron}\"\t{minute}\t{hour}\t{YEAR}-{PAD_MONTH}-{int(d):02d}\t\"\"\t{systems}\t\"\"\t{clean}"
                                )

                job = line.partition("- as:")[-1].strip() if "- as:" in line else ""
                cron = ""
                aux = False
                masters = workers = add_workers = 0

        if job and cron and aux:
            parts = cron.split()
            if len(parts) >= 3:
                minute, hour, days_str = parts[0], parts[1], parts[2]
                systems = masters + workers + add_workers
                for d in days_str.split(","):
                    if d.isdigit():
                        append_record(
                            f"{job}\t\"{cron}\"\t{minute}\t{hour}\t{YEAR}-{PAD_MONTH}-{int(d):02d}\t\"\"\t{systems}\t\"\"\t{clean}"
                        )

    if not records:
        print(f"  -> No jobs found in {file_path.name}, skipping")
        return

    # Create the targeted architecture subfolder on-demand safely
    output_dir.mkdir(parents=True, exist_ok=True)
    out_file = output_dir / f"{file_path.name}.tsv"

    # Overwrites the target file path in the chosen subfolder
    with open(out_file, "w", encoding="utf-8") as out:
        out.write("\n".join(records) + "\n")

    print(f"  -> Created: {out_file}")

def main():
    parser = argparse.ArgumentParser(
        description="Process test configuration files to extract schedule details into architectural TSV subfolders."
    )
    parser.add_argument(
        "-i", "--input",
        default=".",
        help="Path to a single input file or directory containing config files (Default: current directory)"
    )
    parser.add_argument(
        "-o", "--output",
        default=".",
        help="Directory where .tsv files will be saved (Default: current directory)"
    )

    args = parser.parse_args()

    input_path = Path(args.input)
    base_output_dir = Path(args.output)

    if not input_path.exists():
        print(f"Error: Input path '{input_path}' does not exist.", file=sys.stderr)
        sys.exit(1)

    if input_path.is_file():
        print(f"Processing single file: {input_path.name}")
        process_file(input_path, base_output_dir)
    elif input_path.is_dir():
        for file in input_path.iterdir():
            if not file.is_file():
                continue
            print(f"Processing: {file.name}")
            process_file(file, base_output_dir)

    print("Done. All files are processed.")

if __name__ == "__main__":
    main()
