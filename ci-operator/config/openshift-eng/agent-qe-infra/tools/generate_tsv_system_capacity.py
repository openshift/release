#!/usr/bin/env python3
import argparse, re, calendar
import shutil
from pathlib import Path
from collections import defaultdict

YEAR, MONTH, PAD_MONTH = 2026, 6, "06"
RE_VERSION = re.compile(r"[45]\.[0-9]+")
RE_DIGIT = re.compile(r"\D+")
AUX = "openshift-qe-metal-ci"

OWNERS = {
    "agent-qe": "ABI",
    "perfscale": "Perfscale",
    "eco": "Telco",
    "tests-private": "Metal",
    "insights": "Insights",
    "lvm": "LVM",
    "verification": "QE"
}
SCRIPT_DIR = Path(__file__).resolve().parent

def get_unique_files(input_paths: list) -> list:
    """Collects target files recursively from directory and file inputs."""
    unique_files = {}
    for path_str in input_paths:
        path = Path(path_str)
        if not path.exists():
            continue

        if path.is_dir():
            # Recursively find all yaml files inside any nested sub-directory
            for ext in ["*.yaml", "*.yml"]:
                for item in path.rglob(ext):
                    if item.is_file():
                        unique_files[item.resolve()] = item
        else:
            if path.is_file():
                unique_files[path.resolve()] = path

    return list(unique_files.values())


def process_file(file_path: Path, custom_owners_str: str = "") -> list:
    """Parses a test configuration file to extract scheduled jobs."""

    # Determine team/category string based on substrings in the file name
    team_suffix = "UNKNOWN"
    file_name_lower = file_path.name.lower()

    # Initialize lookup mapping with the static defaults
    active_owners = OWNERS.copy()

    # Merge custom mappings from CLI argument string if provided
    if custom_owners_str:
        for pair in custom_owners_str.split(","):
            if ":" in pair:
                k, v = pair.split(":", 1)
                active_owners[k.strip().lower()] = v.strip()

    # Search file name against combined dictionary
    for key, val in active_owners.items():
        if key in file_name_lower:
            team_suffix = val
            break

    records, job, cron, aux = [], "", "", False
    aux_val = ""
    masters = workers = additional_workers = 0
    architecture = "multi"

    def save_record():
        if job:
            if any(x in job for x in ["360", "999", "metal-ds"]) or not AUX in aux_val:
                return
        parts = cron.split()
        if job and cron and aux and len(parts) >= 5:

            total_sys = masters + workers + additional_workers
            sys_out = total_sys if total_sys > 0 else 4

            days_to_process = []
            dom_field = parts[2]
            dow_field = parts[4]

            # Check static Day of Month integers first
            if dom_field.isdigit() or "," in dom_field:
                for d in dom_field.split(","):
                    if d.isdigit():
                        days_to_process.append(int(d))

            # Fallback to Day of Week calculation ONLY if Day of Month is a wildcard '*'
            elif dom_field == "*" and dow_field != "*":
                target_wday_tokens = [int(w) if w.isdigit() else w for w in dow_field.split(",")]
                target_wdays = []
                for w in target_wday_tokens:
                    if isinstance(w, int):
                        target_wdays.append(6 if w in [0, 7] else w - 1)

                num_days = calendar.monthrange(YEAR, MONTH)[1]
                for day in range(1, num_days + 1):
                    wday = calendar.weekday(YEAR, MONTH, day)
                    if wday in target_wdays:
                        days_to_process.append(day)

            # Safe fallback: if both are wildcards, generate for every single day of the month
            if not days_to_process:
                num_days = calendar.monthrange(YEAR, MONTH)[1]
                days_to_process = list(range(1, num_days + 1))

            for day_num in days_to_process:
                records.append((architecture.lower(),
                    f"{job}\t\"{cron}\"\t{parts[0]}\t{parts[1]}\t"
                    f"{YEAR}-{PAD_MONTH}-{int(day_num):02d}\t\"\"\t{sys_out}\t{team_suffix}\t{file_path.name}"
                ))

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in map(str.strip, f):
            if not line: continue
            if "cron:" in line: cron = line.partition("cron:")[-1].strip()
            elif "masters:" in line: masters = int(RE_DIGIT.sub("", line) or 0)
            elif "workers:" in line: workers = int(RE_DIGIT.sub("", line) or 0)
            elif "ADDITIONAL_WORKERS:" in line: additional_workers = int(RE_DIGIT.sub("", line) or 0)
            elif "AUX_HOST:" in line:
                aux = True
                aux_val = line.partition("AUX_HOST:")[-1].strip().strip('"').strip("'")
            elif "architecture:" in line: architecture = line.partition("architecture:")[-1].strip().strip('"').strip("'").lower()
            elif line.startswith("tests:") or line.startswith("- as:"):
                save_record()
                job = line.partition("- as:")[-1].strip() if "- as:" in line else ""
                cron, aux, aux_val, masters, workers, additional_workers = "", False, "", 0, 0, 0
                architecture = "multi"

        save_record()
    return records

def main():
    parser = argparse.ArgumentParser(description="Process test configuration files to extract schedule details into architectural TSV subfolders.")
    parser.add_argument("-i", "--input", nargs="+", default=[str(SCRIPT_DIR / "../../../../config")], help="One or more input directories (Default: agent-qe-infra, openshift-tests-private)")
    parser.add_argument("-o", "--output", default="./processed_jobs", help="Directory where .tsv files will be saved (Default: processed_jobs)")
    parser.add_argument("-a", "--arch", nargs="+", choices=["amd64", "arm64", "multi"], help="Filter architectures.")
    parser.add_argument("-j", "--job-owners", default="", help="Comma-separated key:value pairs to append/override owners (e.g. storage:Storage)")

    args = parser.parse_args()
    allowed_archs = args.arch if args.arch else ["arm64", "amd64", "multi"]
    grouped = defaultdict(lambda: defaultdict(list))

    files = get_unique_files(args.input)

    for file_path in sorted(files, key=lambda f: f.name):
        records = process_file(file_path, args.job_owners)
        if not records: continue

        v_match = RE_VERSION.search(file_path.name)
        version = v_match.group(0) if v_match else "Main"

        for arch, row in records:
            if arch not in ("amd64", "arm64"):
                arch = "multi"

            if arch not in allowed_archs:
                continue

            target_dir = Path(args.output) / arch
            grouped[target_dir][version].append(row)

    for target_dir, version_dict in grouped.items():
        target_dir.mkdir(parents=True, exist_ok=True)
        for version, rows in sorted(version_dict.items()):
            out_file = target_dir / f"{version} Jobs.tsv"
            out_file.write_text("\n".join(rows) + "\n", encoding="utf-8")
            print(f"Created Merged TSV: {out_file} ({len(rows)} lines)")

    # ZIP file creation
    output_path = Path(args.output)

    if output_path.exists():
        for arch_dir in output_path.iterdir():
            if arch_dir.is_dir() and arch_dir.name in ["amd64", "arm64"]:
                zip_base = output_path / arch_dir.name

                zip_path = shutil.make_archive(
                base_name=str(zip_base),
                format="zip",
                root_dir=str(arch_dir),
                )

                print(f"Successfully compiled individual architecture target: {zip_path}")
                shutil.rmtree(arch_dir)

if __name__ == "__main__":
    main()
