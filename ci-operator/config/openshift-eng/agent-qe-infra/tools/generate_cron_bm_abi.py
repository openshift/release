#!/usr/bin/env python3

import re
from pathlib import Path
from collections import defaultdict
import argparse

# Add as many YAML repositories as needed
DEFAULT_YAML_DIRS = [
    "../../agent-qe-infra",
    "../../../openshift/openshift-tests-private",
]

# Baseline global capacity thresholds
DEFAULT_SYSTEM_LIMIT = 36
S3_LIMIT = 20

SLOT_HOURS = {
    "S1": "2",
    "S2": "8",
    "S3": "14",
    "S4": "20"
}

def detect_arch_strict(job_name: str, file_path: str) -> str:
    context = f"{file_path}_{job_name}".lower()
    if "arm64" in context:
        return "arm64"
    if "amd64" in context:
        return "amd64"
    return "multi"

def is_arch_match(target_arch: str, current_arch: str) -> bool:
    """Helper to check if current arch matches target or belongs to multi arch."""
    if not target_arch:
        return True
    if target_arch == current_arch:
        return True
    if current_arch == "multi":
        return True
    return False

def extract_job_weight(block: str) -> int:
    total_systems = 0
    # Search for infrastructure allocations
    for metric in ["ADDITIONAL_WORKERS", "masters", "workers"]:
        match = re.search(rf"{metric}:\s*['\"]?(\d+)['\"]?", block)
        if match:
            total_systems += int(match.group(1))
    return total_systems if total_systems > 0 else 1

def main():
    parser = argparse.ArgumentParser(
        description="Initializing dynamically balanced architecture-aware YAML scheduler.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument(
        "--arch", choices=["amd64", "arm64", "multi"], default=None,
        help="Filter architecture folder during evaluation loop (amd64/arm64 will include multi)"
    )
    parser.add_argument(
        "--system-limit", type=int, default=DEFAULT_SYSTEM_LIMIT,
        help="Global maximum system allocation limit for scheduler slots"
    )
    parser.add_argument(
        "--yaml_dirs", nargs="*", default=DEFAULT_YAML_DIRS,
        help="Target directories containing task definition YAML files"
    )

    args = parser.parse_args()
    target_arch = args.arch
    yaml_dirs = args.yaml_dirs
    system_limit = args.system_limit

    print("Initializing dynamically balanced architecture-aware YAML scheduler...")
    print(f"Target directories: {yaml_dirs}")
    print(f"Architecture filter: {target_arch if target_arch else 'ALL'}")
    print(f"Active System Limit: {system_limit}")

    # Global tracking registers using composite key: (day_of_month, slot_name)
    global_capacity = defaultdict(int)
    job_cron_registry = defaultdict(set)
    job_weight_map = {}
    valid_paths = []

    # Pre-scan files to identify valid jobs and aggregate weights
    for dir_str in yaml_dirs:
        dir_path = Path(dir_str)
        if not dir_path.exists():
            continue
        valid_paths.append(dir_path)

        for yaml_file in dir_path.rglob("*.yaml"):
            try:
                content = yaml_file.read_text()
            except Exception:
                continue

            # Split up standard YAML task blocks
            blocks = re.split(r'(?=\s*-\s*as:)', content)
            for block in blocks:
                job_match = re.search(r'-\s*as:\s*(.*)', block)
                if not job_match:
                    continue

                job_name = job_match.group(1).strip()
                if not re.match(r'^(metal|baremetal)', job_name) or any(x in job_name for x in ["360", "999", "metal-ds"]):
                    continue

                current_arch = detect_arch_strict(job_name, str(yaml_file))
                if not is_arch_match(target_arch, current_arch):
                    continue

                job_weight_map[job_name] = extract_job_weight(block)

    if not job_weight_map:
        print("No matching jobs discovered based on constraints. Exiting.")
        return

    # Loop back through files to optimize matching cron expressions
    for dir_path in valid_paths:
        for yaml_file in dir_path.rglob("*.yaml"):
            try:
                lines = yaml_file.read_text().splitlines()
            except Exception:
                continue

            updated_lines = []
            current_job = None
            skip_cron = True
            file_modified = False

            for line in lines:
                # Track the YAML job block we are currently inside of
                job_match = re.match(r'^\s*- as:\s*(.*)', line)
                if job_match:
                    current_job = job_match.group(1).strip()
                    skip_cron = current_job not in job_weight_map

                    if not skip_cron and target_arch:
                        current_arch = detect_arch_strict(current_job, str(yaml_file))
                        if not is_arch_match(target_arch, current_arch):
                            skip_cron = True

                cron_match = re.match(r'^(\s*)cron:\s*(.*)$', line)
                if current_job and cron_match and not skip_cron:
                    indent = cron_match.group(1)
                    cron_str = cron_match.group(2).strip("'\"")
                    cron_parts = cron_str.split()

                    if len(cron_parts) >= 5:
                        weight = job_weight_map[current_job]
                        original_day = cron_parts[2]

                        chosen_slot = None
                        chosen_day = None
                        chosen_cron = None

                        # Shift the execution day smoothly across the month if slot limits are hit
                        for day_offset in range(31):
                            if original_day in ["*", "?", "*/1"]:
                                target_day = "*"
                            elif original_day.isdigit():
                                calculated_day = int(original_day) + day_offset
                                target_day = str(calculated_day if calculated_day <= 28 else (calculated_day % 28) + 1)
                            else:
                                target_day = original_day

                            # Prioritize empty structural resource slots first
                            slots = sorted(["S1", "S2", "S4"], key=lambda s: global_capacity[(target_day, s)])
                            slots.append("S3")

                            for slot in slots:
                                max_capacity = S3_LIMIT if slot == "S3" else system_limit
                                if global_capacity[(target_day, slot)] + weight <= max_capacity:
                                    test_cron = f"2 {SLOT_HOURS[slot]} {target_day} {' '.join(cron_parts[3:])}"

                                    if test_cron not in job_cron_registry[current_job]:
                                        chosen_slot = slot
                                        chosen_day = target_day
                                        chosen_cron = test_cron
                                        break
                            if chosen_slot:
                                break

                        # Fallback plan if entire grid layout is maxed out
                        if not chosen_slot:
                            chosen_slot, chosen_day = "S1", original_day
                            chosen_cron = f"2 {SLOT_HOURS['S1']} {original_day} {' '.join(cron_parts[3:])}"

                        # Save registration metrics to balancing memory matrix
                        global_capacity[(chosen_day, chosen_slot)] += weight
                        job_cron_registry[current_job].add(chosen_cron)

                        new_line = f"{indent}cron: {chosen_cron}"
                        if new_line != line:
                            line = new_line
                            file_modified = True

                updated_lines.append(line)

            if file_modified:
                try:
                    yaml_file.write_text("\n".join(updated_lines) + "\n")
                except Exception as e:
                    print(f"Error updating file {yaml_file}: {e}")

if __name__ == "__main__":
    main()
