#!/usr/bin/env python3
"""
Performance Cron Management Tool for OpenShift Pipelines.

Manages version lifecycle (add/remove/promote) for performance cron jobs
with variant-based scheduling.

After any mutating command, run: make update
"""

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("pyyaml required: python3 -m pip install pyyaml", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "openshift-pipelines-performance-main.yaml")

# ---------------------------------------------------------------------------
# Schedule constants -- must match the variant-based scheduling plan
# ---------------------------------------------------------------------------

VARIANT_DAYS = {
    "standard":    [1,  8, 15, 22],
    "ha-10":       [2,  9, 16, 23],
    "ha-10-state": [3, 10, 17, 24],
    "qbt":         [4, 11, 18, 25],
    "ha-10-qbt":   [5, 12, 19, 26],
}
FOCUS_DAYS = [6, 13, 20, 27]
BUFFER_DAYS = [7, 14, 21, 28]

PIPELINES_VERSION_START = 2
PIPELINES_SPACING = 2

CHAINS_VERSION_START = 14
CHAINS_SPACING = 2

RESULTS_VERSION_START = 10
RESULTS_SPACING = 2

PHASE1_CHAINS = {"standard": 1, "ha-10": 3, "qbt": 5, "ha-10-qbt": 7}
PHASE1_PIPELINES = {
    "standard": 9, "ha-10": 11, "ha-10-state": 13, "qbt": 15, "ha-10-qbt": 17,
}
PHASE1_RESULTS = 21

JOB_DURATIONS = {"pipelines": 8, "chains": 6, "results": 4}

# ---------------------------------------------------------------------------
# YAML helpers (read-only, used by show and classification)
# ---------------------------------------------------------------------------

def load_config():
    with open(CONFIG_FILE) as f:
        return yaml.safe_load(f)

# ---------------------------------------------------------------------------
# Line-based file helpers (used by mutating commands)
# ---------------------------------------------------------------------------

def _read_lines():
    with open(CONFIG_FILE) as f:
        return f.readlines()


def _write_lines(lines):
    with open(CONFIG_FILE, "w") as f:
        f.writelines(lines)
    print(f"\nWrote {CONFIG_FILE}")
    print("Run 'make update' to regenerate periodics.")


def _find_test_boundaries(lines):
    """Map each test entry to its line range.

    Returns [(job_name, start_idx, end_idx), ...] where end_idx is exclusive.
    """
    tests_start = None
    for i, line in enumerate(lines):
        if line.rstrip() == "tests:":
            tests_start = i + 1
            break
    if tests_start is None:
        return []

    entries = []
    cur_start = None
    cur_name = None

    for i in range(tests_start, len(lines)):
        stripped = lines[i].rstrip("\n")

        if stripped.startswith("- "):
            if cur_start is not None:
                entries.append((cur_name, cur_start, i))
            cur_start = i
            cur_name = None
            if "as: " in stripped:
                cur_name = stripped.split("as: ", 1)[1].strip()

        elif stripped and not stripped[0].isspace() and not stripped.startswith("-"):
            if cur_start is not None:
                entries.append((cur_name, cur_start, i))
            break

        if cur_name is None and cur_start is not None and "  as: " in lines[i]:
            cur_name = lines[i].split("as: ", 1)[1].strip()
    else:
        if cur_start is not None:
            entries.append((cur_name, cur_start, len(lines)))

    return entries

# ---------------------------------------------------------------------------
# Job classification
# ---------------------------------------------------------------------------

def get_family(job):
    name = job["as"]
    if "sign-tkn-bb" in name:
        return "chains"
    if name.startswith("tkn-res"):
        return "results"
    if "max-concurrency" in name or "scaling-pipelines" in name:
        return "pipelines"
    return "other"


def get_version(job):
    env = job.get("steps", {}).get("env", {})
    ver = env.get("DEPLOYMENT_VERSION")
    if ver and ver != "nightly":
        return ver
    if ver == "nightly" or env.get("NIGHTLY_BUILD") == "true":
        return "nightly"
    name = job["as"]
    m = re.search(r"(?:pipelines|-)(\d+)-(\d+)", name)
    if m:
        return f"{m.group(1)}.{m.group(2)}"
    return None


def get_variant(job):
    env = job.get("steps", {}).get("env", {})
    family = get_family(job)

    if family == "chains":
        has_ha = env.get("DEPLOYMENT_CHAINS_CONTROLLER_HA_REPLICAS") == "10"
        has_qbt = env.get("DEPLOYMENT_CHAINS_THREADS_PER_CONTROLLER") == "32"
    else:
        has_ha = env.get("DEPLOYMENT_PIPELINES_CONTROLLER_HA_REPLICAS") == "10"
        has_qbt = env.get("DEPLOYMENT_PIPELINES_THREADS_PER_CONTROLLER") == "32"
    has_state = env.get("DEPLOYMENT_PIPELINES_CONTROLLER_TYPE") == "statefulSets"

    if has_ha and has_state:
        return "ha-10-state"
    if has_ha and has_qbt:
        return "ha-10-qbt"
    if has_ha:
        return "ha-10"
    if has_qbt:
        return "qbt"
    return "standard"


def is_cron_job(job):
    return "cron" in job


def is_optional_job(job):
    return job.get("always_run") is False


def parse_cron(cron_str):
    parts = cron_str.split()
    return {"minute": parts[0], "hour": int(parts[1]),
            "dom": parts[2], "month": parts[3], "dow": parts[4]}


def make_cron(hour, days=None):
    if days:
        dom = ",".join(str(d) for d in sorted(days))
        return f"0 {hour} {dom} * *"
    return f"0 {hour} * * *"


def fires_on_day(job, day):
    cron = parse_cron(job["cron"])
    if cron["dom"] == "*" and cron["dow"] == "*":
        return True
    if cron["dom"] != "*":
        return day in [int(d) for d in cron["dom"].split(",")]
    return False

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

def cmd_show(args):
    data = load_config()
    cron_jobs = [t for t in data["tests"] if is_cron_job(t)]

    families = {"pipelines": [], "chains": [], "results": []}
    for job in cron_jobs:
        f = get_family(job)
        if f in families:
            families[f].append(job)

    header = f"  {'Version':<10} {'Variant':<16} {'Hour':<6} {'Days'}"
    sep =    f"  {'─'*10} {'─'*16} {'─'*6} {'─'*30}"

    for fkey, label in [("pipelines", "PIPELINES"), ("chains", "CHAINS"),
                        ("results", "RESULTS")]:
        jobs = families[fkey]
        print(f"\n{label} ({len(jobs)} cron jobs)")
        print(header)
        print(sep)
        for job in jobs:
            ver = get_version(job) or "?"
            var = get_variant(job)
            cron = parse_cron(job["cron"])
            dom = "daily" if cron["dom"] == "*" and cron["dow"] == "*" else cron["dom"]
            print(f"  {ver:<10} {var:<16} h{cron['hour']:<4} {dom}")

    print(f"\nVARIANT-DAY SUMMARY")
    print(f"  {'Day type':<20} {'Days':<20} {'Jobs'}")
    print(f"  {'─'*20} {'─'*20} {'─'*5}")
    for vname, vdays in VARIANT_DAYS.items():
        count = sum(1 for j in cron_jobs if fires_on_day(j, vdays[0]))
        print(f"  {vname:<20} {_fmt_days(vdays):<20} {count}")
    focus_ct = sum(1 for j in cron_jobs if fires_on_day(j, FOCUS_DAYS[0]))
    buffer_ct = sum(1 for j in cron_jobs if fires_on_day(j, BUFFER_DAYS[0]))
    print(f"  {'Focus Day':<20} {_fmt_days(FOCUS_DAYS):<20} {focus_ct}")
    print(f"  {'Buffer Day':<20} {_fmt_days(BUFFER_DAYS):<20} {buffer_ct}")

    versions = sorted(set(
        get_version(j) for j in cron_jobs
        if get_version(j) and get_version(j) != "nightly"
    ))
    print(f"\nActive versions: nightly, {', '.join(versions)}")
    print(f"Cron jobs: {len(cron_jobs)}")

    _print_concurrency(cron_jobs)


def _fmt_days(days):
    return ",".join(str(d) for d in days)


def _print_concurrency(cron_jobs):
    print(f"\nPEAK CONCURRENCY ESTIMATE (includes previous-day spillover)")
    day_types = [
        ("Variant day (with chains)", VARIANT_DAYS["standard"][0]),
        ("Variant day (no chains)",   VARIANT_DAYS["ha-10-state"][0]),
        ("Focus Day",                  FOCUS_DAYS[0]),
        ("Buffer Day",                 BUFFER_DAYS[0]),
    ]
    print(f"  {'Day type':<30} {'Peak':>4}  {'At hour'}")
    print(f"  {'─'*30} {'─'*4}  {'─'*7}")
    for label, sample_day in day_types:
        peak, peak_hour = _estimate_peak(cron_jobs, sample_day)
        print(f"  {label:<30} ~{peak:<3}  h{peak_hour}")


def _estimate_peak(cron_jobs, day):
    """Peak concurrency on *day*, accounting for previous-day spillover."""
    prev_day = day - 1 if day > 1 else 28

    current = [(parse_cron(j["cron"])["hour"], JOB_DURATIONS.get(get_family(j), 8))
               for j in cron_jobs if fires_on_day(j, day)]
    spillover = [(parse_cron(j["cron"])["hour"], JOB_DURATIONS.get(get_family(j), 8))
                 for j in cron_jobs
                 if fires_on_day(j, prev_day)
                 and parse_cron(j["cron"])["hour"] + JOB_DURATIONS.get(get_family(j), 8) > 24]

    peak = 0
    peak_hour = 0
    for h in range(24):
        count = sum(1 for s, d in current if s <= h < s + d)
        count += sum(1 for s, d in spillover if h < s + d - 24)
        if count > peak:
            peak = count
            peak_hour = h
    return peak, peak_hour

# ---------------------------------------------------------------------------
# remove  (line-based)
# ---------------------------------------------------------------------------

def cmd_remove(args):
    data = load_config()
    version = args.version

    to_remove = []
    for job in data["tests"]:
        if is_cron_job(job) and get_version(job) == version:
            to_remove.append(job["as"])

    if not to_remove:
        print(f"No cron jobs found for version {version}")
        return

    print(f"Cron jobs to remove for version {version} ({len(to_remove)}):")
    for name in to_remove:
        print(f"  - {name}")

    if not args.confirm:
        print(f"\nDry run. Pass --confirm to execute.")
        return

    names_to_remove = set(to_remove)
    lines = _read_lines()
    boundaries = _find_test_boundaries(lines)

    ranges_to_delete = [(s, e) for name, s, e in boundaries if name in names_to_remove]
    for start, end in sorted(ranges_to_delete, reverse=True):
        del lines[start:end]

    _write_lines(lines)
    print(f"Removed {len(ranges_to_delete)} cron jobs.")

# ---------------------------------------------------------------------------
# add  (line-based)
# ---------------------------------------------------------------------------

def cmd_add(args):
    data = load_config()
    new_ver = args.version
    new_vdash = new_ver.replace(".", "-")

    cron_jobs = [t for t in data["tests"] if is_cron_job(t)]
    versions = sorted(set(
        get_version(j) for j in cron_jobs
        if get_version(j) and get_version(j) != "nightly"
    ))
    if not versions:
        print("No existing versioned jobs to clone from.")
        return

    clone_ver = versions[-1]
    clone_vdash = clone_ver.replace(".", "-")

    if any(get_version(j) == new_ver for j in data["tests"]):
        print(f"Version {new_ver} already exists. Remove it first or use promote.")
        return

    lines = _read_lines()
    boundaries = _find_test_boundaries(lines)
    boundary_map = {name: (s, e) for name, s, e in boundaries}

    new_blocks = []

    for job in cron_jobs:
        if get_version(job) != clone_ver:
            continue

        family = get_family(job)
        variant = get_variant(job)
        name = job["as"]
        if name not in boundary_map:
            continue

        s, e = boundary_map[name]
        block_text = "".join(lines[s:e])

        if family == "pipelines":
            hour = PHASE1_PIPELINES.get(variant)
            if hour is None:
                continue
            block_text = block_text.replace(f"pipelines{clone_vdash}", f"pipelines{new_vdash}")
        elif family == "chains":
            hour = PHASE1_CHAINS.get(variant)
            if hour is None:
                continue
            block_text = block_text.replace(f"{clone_vdash}-sign", f"{new_vdash}-sign")
        elif family == "results":
            hour = PHASE1_RESULTS
            block_text = block_text.replace(f"pipelines{clone_vdash}", f"pipelines{new_vdash}")
        else:
            continue

        block_text = re.sub(
            r'DEPLOYMENT_VERSION: "' + re.escape(clone_ver) + '"',
            f'DEPLOYMENT_VERSION: "{new_ver}"',
            block_text,
        )
        block_text = re.sub(r"  cron: .+\n", f"  cron: {make_cron(hour)}\n", block_text)

        new_blocks.append((family, variant, name, block_text))

    if not new_blocks:
        print("No jobs generated.")
        return

    print(f"Cloning from version {clone_ver}")
    print(f"\nPhase 1 jobs to add ({len(new_blocks)}):")
    for family, variant, _, block in new_blocks:
        cron_match = re.search(r"cron: (.+)", block)
        cron_val = cron_match.group(1) if cron_match else "?"
        new_name_match = re.search(r"^- as: (.+)", block)
        new_name = new_name_match.group(1).strip() if new_name_match else "?"
        print(f"  + [{family:10}] {new_name:60} cron: {cron_val}")

    _print_concurrency_impact_from_blocks(data, new_blocks)

    if not args.confirm:
        print(f"\nDry run. Pass --confirm to execute.")
        return

    insert_idx = None
    for name, s, e in boundaries:
        if name and boundary_map.get(name):
            job_data = next((j for j in data["tests"] if j["as"] == name), None)
            if job_data and is_optional_job(job_data):
                insert_idx = s
                break
    if insert_idx is None:
        insert_idx = boundaries[-1][2] if boundaries else len(lines)

    combined = "".join(block for _, _, _, block in new_blocks)
    lines.insert(insert_idx, combined)

    _write_lines(lines)
    print(f"Added {len(new_blocks)} Phase 1 jobs.")


def _print_concurrency_impact_from_blocks(data, new_blocks):
    cron_jobs = [t for t in data["tests"] if is_cron_job(t)]

    items = [(j["cron"], get_family(j)) for j in cron_jobs]
    for family, _, _, block in new_blocks:
        cron_match = re.search(r"cron: (.+)", block)
        if cron_match:
            items.append((cron_match.group(1), family))

    print(f"\nEstimated peak concurrency during Phase 1:")
    for label, day in [("Variant day", VARIANT_DAYS["standard"][0]),
                       ("Focus Day", FOCUS_DAYS[0]),
                       ("Buffer Day", BUFFER_DAYS[0])]:
        peak, peak_hour = _estimate_peak_from_items(items, day)
        print(f"  {label}: ~{peak} (at h{peak_hour})")


def _estimate_peak_from_items(items, day):
    """Peak concurrency from (cron_str, family) tuples."""
    prev_day = day - 1 if day > 1 else 28

    def fires(cron_str, d):
        parts = cron_str.split()
        dom, dow = parts[2], parts[4]
        if dom == "*" and dow == "*":
            return True
        if dom != "*":
            return d in [int(x) for x in dom.split(",")]
        return False

    current = []
    spillover = []
    for cron_str, family in items:
        h = int(cron_str.split()[1])
        dur = JOB_DURATIONS.get(family, 8)
        if fires(cron_str, day):
            current.append((h, dur))
        if fires(cron_str, prev_day) and h + dur > 24:
            spillover.append((h, dur))

    peak = 0
    peak_hour = 0
    for h in range(24):
        count = sum(1 for s, d in current if s <= h < s + d)
        count += sum(1 for s, d in spillover if h < s + d - 24)
        if count > peak:
            peak = count
            peak_hour = h
    return peak, peak_hour

# ---------------------------------------------------------------------------
# promote --replace  (line-based)
# ---------------------------------------------------------------------------

def cmd_promote(args):
    data = load_config()
    tests = data["tests"]
    new_ver = args.version
    old_ver = args.replace

    cron_jobs = [t for t in tests if is_cron_job(t)]

    groups = {}
    for job in cron_jobs:
        ver = get_version(job)
        if not ver or ver == "nightly":
            continue
        key = (get_family(job), get_variant(job))
        groups.setdefault(key, []).append({
            "ver": ver, "name": job["as"], "hour": parse_cron(job["cron"])["hour"],
        })
    for key in groups:
        groups[key].sort(key=lambda x: x["hour"])

    has_old = any(e["ver"] == old_ver for g in groups.values() for e in g)
    has_new = any(e["ver"] == new_ver for g in groups.values() for e in g)
    if not has_old:
        print(f"No cron jobs for {old_ver}")
        return

    need_clone = not has_new
    if need_clone:
        clone_ver = max(
            e["ver"] for g in groups.values() for e in g if e["ver"] != "nightly"
        )
        clone_vdash = clone_ver.replace(".", "-")
        new_vdash = new_ver.replace(".", "-")
        print(f"No existing {new_ver} jobs -- cloning from {clone_ver}\n")

    def slot_hour(family, index):
        if family == "pipelines":
            return PIPELINES_VERSION_START + index * PIPELINES_SPACING
        if family == "chains":
            return CHAINS_VERSION_START + index * CHAINS_SPACING
        return RESULTS_VERSION_START + index * RESULTS_SPACING

    def slot_days(family, variant):
        if family == "results":
            return None
        return VARIANT_DAYS.get(variant)

    if need_clone:
        for (fam, var), entries in groups.items():
            src = next((e for e in entries if e["ver"] == clone_ver), None)
            if not src:
                continue
            cloned_name = _clone_name(src["name"], clone_vdash, new_vdash, fam)
            entries.append({"ver": new_ver, "name": cloned_name, "hour": -1})

    ops = []
    slot_summary = {}

    for (fam, var), entries in groups.items():
        positions = [e for e in entries if e["ver"] != new_ver]
        new_content = sorted(
            [e for e in entries if e["ver"] != old_ver],
            key=lambda x: x["ver"],
        )
        days = slot_days(fam, var)

        for i, pos in enumerate(positions):
            if i < len(new_content):
                c = new_content[i]
                hour = slot_hour(fam, i)
                cron = make_cron(hour, days)
                ops.append((pos["name"], c["name"], cron))
                if var == "standard" or (fam == "results"):
                    slot_summary.setdefault(fam, []).append(
                        (hour, pos["ver"], c["ver"])
                    )

        if not need_clone:
            new_entry = next((e for e in entries if e["ver"] == new_ver), None)
            if new_entry:
                ops.append((new_entry["name"], None, None))

    print(f"Promote {new_ver}, replace {old_ver} (reorder by version):\n")
    for fam, label in [("pipelines", "PIPELINES"), ("chains", "CHAINS"),
                       ("results", "RESULTS")]:
        if fam not in slot_summary:
            continue
        variants = sum(1 for (f, _) in groups if f == fam)
        suffix = f" (x{variants} variants)" if variants > 1 else ""
        print(f"  {label}{suffix}:")
        for hour, was, now in sorted(slot_summary[fam]):
            print(f"    h{hour}: {was} -> {now}")

    deletes = [p for p, r, _ in ops if r is None]
    if deletes:
        print(f"\n  Phase 1 entries to delete: {len(deletes)}")

    if not args.confirm:
        print(f"\nDry run. Pass --confirm to execute.")
        return

    lines = _read_lines()
    boundaries = _find_test_boundaries(lines)
    bmap = {name: (s, e) for name, s, e in boundaries}

    texts = {}
    for _, rep_name, new_cron in ops:
        if not rep_name or rep_name not in bmap:
            continue
        s, e = bmap[rep_name]
        text = "".join(lines[s:e])
        text = re.sub(r"  cron: .+\n", f"  cron: {new_cron}\n", text)
        texts[(rep_name, new_cron)] = text

    if need_clone:
        for pos_name, rep_name, new_cron in ops:
            if not rep_name:
                continue
            if (rep_name, new_cron) in texts:
                continue
            src_name = _source_name(rep_name, new_vdash, clone_vdash)
            if src_name and src_name in bmap:
                s, e = bmap[src_name]
                text = "".join(lines[s:e])
                fam = get_family({"as": src_name})
                if fam == "pipelines" or fam == "results":
                    text = text.replace(f"pipelines{clone_vdash}", f"pipelines{new_vdash}")
                elif fam == "chains":
                    text = text.replace(f"{clone_vdash}-sign", f"{new_vdash}-sign")
                text = re.sub(
                    r'DEPLOYMENT_VERSION: "' + re.escape(clone_ver) + '"',
                    f'DEPLOYMENT_VERSION: "{new_ver}"', text)
                text = re.sub(r"  cron: .+\n", f"  cron: {new_cron}\n", text)
                texts[(rep_name, new_cron)] = text

    line_ops = []
    seen = set()
    for pos_name, rep_name, new_cron in ops:
        if pos_name not in bmap:
            continue
        s, e = bmap[pos_name]
        if (s, e) in seen:
            continue
        seen.add((s, e))
        if rep_name:
            line_ops.append((s, e, texts.get((rep_name, new_cron))))
        else:
            line_ops.append((s, e, None))

    for s, e, text in sorted(line_ops, key=lambda x: x[0], reverse=True):
        del lines[s:e]
        if text is not None:
            for j, ln in enumerate(text.splitlines(keepends=True)):
                lines.insert(s + j, ln)

    _write_lines(lines)
    print(f"Promoted {new_ver}, replaced {old_ver}, versions reordered.")


def _clone_name(src_name, old_vdash, new_vdash, family):
    if family in ("pipelines", "results"):
        return src_name.replace(f"pipelines{old_vdash}", f"pipelines{new_vdash}")
    if family == "chains":
        return src_name.replace(f"{old_vdash}-sign", f"{new_vdash}-sign")
    return src_name


def _source_name(cloned_name, new_vdash, clone_vdash):
    """Reverse a cloned name back to its source."""
    if f"pipelines{new_vdash}" in cloned_name:
        return cloned_name.replace(f"pipelines{new_vdash}", f"pipelines{clone_vdash}")
    if f"{new_vdash}-sign" in cloned_name:
        return cloned_name.replace(f"{new_vdash}-sign", f"{clone_vdash}-sign")
    return None

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Manage OpenShift Pipelines performance cron jobs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  %(prog)s show                                  Show current schedule
  %(prog)s remove 1.20                           Preview removal of 1.20
  %(prog)s remove 1.20 --confirm                 Remove all 1.20 jobs
  %(prog)s add 1.23                              Preview Phase 1 daily jobs
  %(prog)s add 1.23 --confirm                    Add Phase 1 daily jobs
  %(prog)s promote 1.23 --replace 1.20           Preview promotion
  %(prog)s promote 1.23 --replace 1.20 --confirm Execute promotion
""",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("show", help="Show current schedule and concurrency")

    p_rm = sub.add_parser("remove", help="Remove all jobs for a version")
    p_rm.add_argument("version", help="Version to remove (e.g. 1.20)")
    p_rm.add_argument("--confirm", action="store_true")

    p_add = sub.add_parser("add", help="Add Phase 1 daily jobs for a new version")
    p_add.add_argument("version", help="Version to add (e.g. 1.23)")
    p_add.add_argument("--confirm", action="store_true")

    p_pro = sub.add_parser("promote", help="Promote a version to a permanent slot")
    p_pro.add_argument("version", help="Version to promote (e.g. 1.23)")
    p_pro.add_argument("--replace", required=True,
                       help="Version whose slot to take (e.g. 1.20)")
    p_pro.add_argument("--confirm", action="store_true")

    args = parser.parse_args()
    cmds = {
        "show": cmd_show, "remove": cmd_remove,
        "add": cmd_add, "promote": cmd_promote,
    }
    cmds[args.command](args)


if __name__ == "__main__":
    main()
