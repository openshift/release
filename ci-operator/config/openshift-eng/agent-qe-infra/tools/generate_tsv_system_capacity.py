#!/usr/bin/env python3
import argparse, re
from pathlib import Path
from collections import defaultdict

YEAR, MONTH, PAD_MONTH = 2026, 6, "06"
RE_VERSION = re.compile(r"[45]\.[0-9]+")
RE_DIGIT = re.compile(r"\D+")

def get_unique_files(input_paths: list) -> list:
    """Collects target files from directory and file inputs."""
    unique_files = {}
    for path_str in input_paths:
        path = Path(path_str)
        if not path.exists():
            continue

        items_to_check = path.iterdir() if path.is_dir() else [path]

        for item in items_to_check:
            if item.is_file():
                unique_files[item.resolve()] = item

    return list(unique_files.values())

def determine_architecture(filename_lower: str, job_name_lower: str) -> str:
    """Explicit architecture detection logic based on name matching priority."""
    if "arm" in filename_lower or "arm" in job_name_lower:
        return "arm64"
    if "amd" in filename_lower or "amd" in job_name_lower:
        return "amd64"
    return "multi"

def process_file(file_path: Path) -> list:
    """Parses a test configuration file to extract scheduled jobs."""
    v_match = RE_VERSION.search(file_path.stem)
    version_prefix = v_match.group(0) if v_match else ""

    base_stem = file_path.name
    for ext in ['.tsv', '.yaml', '.yml']:
        if base_stem.endswith(ext): base_stem = base_stem[:-len(ext)]

    clean_name = f"{version_prefix}__{base_stem.partition('__')[-1] if '__' in base_stem else base_stem}"
    records, job, cron, aux = [], "", "", False
    masters = workers = additional_workers = 0

    def save_record():
        if job:
            if not re.match(r'^(metal|baremetal)', job) or any(x in job for x in ["360", "999", "metal-ds"]):
                return
        parts = cron.split()
        if job and cron and aux and len(parts) >= 3:
            total_sys = masters + workers + additional_workers
            sys_out = total_sys if total_sys > 0 else 4

            for d in parts[2].split(","):
                if d.isdigit():
                    records.append(
                        f"{job}\t\"{cron}\"\t{parts[0]}\t{parts[1]}\t"
                        f"{YEAR}-{PAD_MONTH}-{int(d):02d}\t\"\"\t{sys_out}\t\"\"\t{clean_name}"
                    )

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in map(str.strip, f):
            if not line: continue
            if "cron:" in line: cron = line.partition("cron:")[-1].strip()
            elif "masters:" in line: masters = int(RE_DIGIT.sub("", line) or 0)
            elif "workers:" in line: workers = int(RE_DIGIT.sub("", line) or 0)
            elif "ADDITIONAL_WORKERS:" in line: additional_workers = int(RE_DIGIT.sub("", line) or 0)
            elif "AUX_HOST:" in line: aux = True
            elif line.startswith("tests:") or line.startswith("- as:"):
                save_record()
                job = line.partition("- as:")[-1].strip() if "- as:" in line else ""
                cron, aux, masters, workers, additional_workers = "", False, 0, 0, 0
        save_record()
    return records

def main():
    parser = argparse.ArgumentParser(description="Process test configuration files to extract schedule details into architectural TSV subfolders.")
    parser.add_argument("-i", "--input", nargs="+", default=["../../agent-qe-infra", "../../../openshift/openshift-tests-private"], help="One or more input directories (Default: agent-qe-infra, openshift-tests-private)")
    parser.add_argument("-o", "--output", default="./processed_jobs", help="Directory where .tsv files will be saved (Default: processed_jobs)")
    parser.add_argument("-a", "--arch", nargs="+", choices=["amd64", "arm64"], help="Filter architectures.")

    args = parser.parse_args()
    allowed_archs = args.arch if args.arch else ["arm64", "amd64"]
    grouped = defaultdict(lambda: defaultdict(list))

    files = get_unique_files(args.input)

    for file_path in sorted(files, key=lambda f: f.name):
        records = process_file(file_path)
        if not records: continue

        v_match = RE_VERSION.search(file_path.name)
        version = v_match.group(0) if v_match else "unknown"
        f_lower = file_path.name.lower()

        for row in records:
            j_lower = row.split("\t")[0].lower()
            arch = determine_architecture(f_lower, j_lower)

            if arch and arch not in allowed_archs: continue

            target_dir = Path(args.output) / arch if arch else Path(args.output)
            grouped[target_dir][version].append(row)

    for target_dir, version_dict in grouped.items():
        target_dir.mkdir(parents=True, exist_ok=True)
        for version, rows in sorted(version_dict.items()):
            out_file = target_dir / f"{version} Jobs.tsv"
            out_file.write_text("\n".join(rows) + "\n", encoding="utf-8")
            print(f"Created Merged TSV: {out_file} ({len(rows)} lines)")

if __name__ == "__main__":
    main()
