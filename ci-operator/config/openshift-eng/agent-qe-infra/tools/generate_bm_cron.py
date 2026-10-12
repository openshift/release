#!/usr/bin/env python3

import re
import random
from pathlib import Path
from collections import defaultdict
import argparse


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_YAML_DIRS = [
    (SCRIPT_DIR / "../../../../config").resolve(),
]

# Baseline global capacity thresholds
DEFAULT_SYSTEM_LIMIT = 37
S3_LIMIT_RATIO = 0.40

# Defined target slots with their respective random hours and minutes
SLOT_HOURS_POOL = {
    "S1": [22, 23, 0],
    "S2": [4, 5, 6],
    "S3": [10, 11, 12],
    "S4": [16, 17, 18]
}
MINUTE_POOL = [9, 19, 29, 39, 49, 59]

def detect_arch_strict(block: str = "") -> str:
    """Detects architecture by checking YAML block configuration"""
    arch_match = re.search(r'^\s*architecture:\s*[\'"]?(\w+)[\'"]?', block, re.MULTILINE)
    return arch_match.group(1).strip().lower() if arch_match else "multi"

def is_arch_match(target_arch: str, current_arch: str) -> bool:
    """Helper to check if current arch matches target or belongs to multi arch."""
    return True if not target_arch or target_arch == current_arch or current_arch == "multi" else False

def extract_job_weight(block: str) -> int:
    total_systems = 0
    # Search for infrastructure allocations
    for metric in ["ADDITIONAL_WORKERS", "masters", "workers"]:
        match = re.search(rf"{metric}:\s*['\"]?(\d+)['\"]?", block)
        if match:
            total_systems += int(match.group(1))
    return total_systems if total_systems > 0 else 1

def generate_random_time_for_job(job_name: str, slot: str):
    """
    Generates a random minute and hour for a given job and slot.
    Seeding via job name ensures consistency across execution re-runs.
    """
    rng = random.Random(job_name)
    hour = rng.choice(SLOT_HOURS_POOL[slot])
    minute = rng.choice(MINUTE_POOL)
    return minute, hour

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
        "--yaml_dirs", nargs="*", default=[str(p) for p in DEFAULT_YAML_DIRS],
        help="Target directories containing task definition YAML files"
    )

    args = parser.parse_args()
    target_arch = args.arch
    yaml_dirs = args.yaml_dirs
    system_limit = args.system_limit
    s3_limit = int(system_limit * S3_LIMIT_RATIO)

    print("Initializing dynamically balanced architecture-aware YAML scheduler...")
    print(f"Target directories: {yaml_dirs}")
    print(f"Architecture filter: {target_arch if target_arch else 'ALL'}")
    print(f"Active System Limit: {system_limit}")
    print(f"Active S3 Limit (40%): {s3_limit}")

    # Global tracking registers using composite key: (day_of_month, slot_name)
    global_capacity = defaultdict(int)
    job_weight_map = {}
    valid_paths = [Path(d) for d in yaml_dirs if Path(d).exists()]

    # Pre-scan files to identify valid jobs and aggregate weights
    for dir_path in valid_paths:
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
                if any(x in job_name for x in ["360", "999", "metal-ds"]) or not re.search(r'^\s*AUX_HOST: openshift-qe-metal-ci\s*.*', block, re.MULTILINE):
                    continue

                current_arch = detect_arch_strict(block)
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
                content = yaml_file.read_text()
                lines = content.splitlines()
            except Exception:
                continue

            # Pre-parse blocks for line-by-line second pass matching
            blocks = re.split(r'(?=\s*-\s*as:)', content)
            block_map = {jm.group(1).strip(): b for b in blocks if (jm := re.search(r'-\s*as:\s*(.*)', b))}

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
                        job_block = block_map.get(current_job, "")
                        current_arch = detect_arch_strict(job_block)
                        skip_cron = not is_arch_match(target_arch, current_arch)

                cron_match = re.match(r'^(\s*)cron:\s*(.*)$', line)
                if current_job and cron_match and not skip_cron:
                    indent = cron_match.group(1)
                    cron_str = cron_match.group(2).strip("'\"")
                    cron_parts = cron_str.split()

                    if len(cron_parts) >= 5:
                        weight = job_weight_map[current_job]
                        original_days = cron_parts[2]

                        day_tokens = original_days.split(",")

                        chosen_slot = None
                        chosen_days_list = []

                        # Shift the execution day smoothly across the month if slot limits are hit
                        for day_offset in range(30):
                            prospective_days = []
                            for token in day_tokens:
                                if token in ["*", "?", "*/1"]:
                                    target_day = "*"
                                elif token.isdigit():
                                    base_day = int(token)
                                    if base_day > 30:
                                        base_day = 30
                                    calculated_day = base_day + day_offset
                                    target_day = str(((calculated_day - 1) % 30) + 1)
                                else:
                                    target_day = token
                                prospective_days.append(target_day)

                            # Sort slots using the sum of explicit day load AND wildcard "*" load combined
                            slots = sorted(
                                ["S1", "S2", "S3", "S4"],
                                key=lambda s: sum((global_capacity[(d, s)] + global_capacity[("*", s)]) for d in prospective_days) + (1 if s == "S3" else 0)
                            )

                            for slot in slots:
                                # Dynamically fetch capacity: S3 is strictly locked to 40% (s3_limit)
                                max_capacity = s3_limit if slot == "S3" else system_limit

                                # Verify capacity limits are respected across EVERY targeted execution day
                                fits_all_days = True
                                for d in prospective_days:
                                    # Include wildcard load inside the strict limit threshold validation pass
                                    if (global_capacity[(d, slot)] + global_capacity[("*", slot)] + weight) > max_capacity:
                                        fits_all_days = False
                                        break

                                if fits_all_days:
                                    chosen_slot = slot
                                    chosen_days_list = prospective_days
                                    break
                            if chosen_slot:
                                break

                        # Fallback safely to slot 1 if no optimized configuration satisfies limits
                        if not chosen_slot:
                            chosen_slot = "S1"
                            chosen_days_list = day_tokens

                        # Book capacity for EVERY individual targeted day separately
                        for d in chosen_days_list:
                            global_capacity[(d, chosen_slot)] += weight

                        r_min, r_hour = generate_random_time_for_job(current_job, chosen_slot)
                        new_days_str = ",".join(chosen_days_list)
                        chosen_cron = f"{r_min} {r_hour} {new_days_str} {' '.join(cron_parts[3:])}"

                        new_line = f"{indent}cron: {chosen_cron}"
                        if new_line != line:
                            line = new_line
                            file_modified = True

                updated_lines.append(line)

            if file_modified:
                try:
                    yaml_file.write_text("\n".join(updated_lines) + "\n")
                    print(f"Successfully optimized schedules in: {yaml_file.name}")
                except Exception as e:
                    print(f"Failed to write updates to {yaml_file.name}: {e}")

if __name__ == "__main__":
    main()
