#!/usr/bin/env python3
"""Deliver and run OCM FVT artifact helpers through the step commands volume."""

import itertools
import json
import os
import re
import stat
import sys
import tempfile

# Publication audit manifest. Artifacts uploaded to GCS pass a post-upload
# pattern scanner that replaces a whole matching object with a short notice, so
# a published file and a file that was never produced can look identical after
# the fact. The manifest is written next to the published tree and records what
# publication did with every entry it saw, using only names, byte counts and a
# fixed set of reason categories - never artifact content.
AUDIT_NAME = "ocm-fvt-artifact-audit.json"
AUDIT_SCHEMA = 1
# Worst case about 160 KiB: AUDIT_MAX_ENTRIES publication records,
# AUDIT_MAX_HANDOFF inventory records and at most AUDIT_MAX_FAILED records for
# entries publication refused, each holding a bounded rendered name, plus a
# small fixed object. The first two lists are sorted before they are capped,
# so which records survive a cap is reproducible rather than readdir order.
AUDIT_MAX_ENTRIES = 512
AUDIT_MAX_FAILED = 8
AUDIT_MAX_HANDOFF = 128
AUDIT_MAX_SCAN = 8192
AUDIT_MAX_PATH = 160
AUDIT_MAX_COMPONENT = 96
AUDIT_UNSAFE = re.compile(r"[^0-9A-Za-z._-]")
# A file name is data produced by the test run, and the manifest is the one
# object that aggregates every name in the step. A long unbroken alphanumeric
# run is the shape of a token, a key id or a digest, so such a run is reduced
# to its length instead of reproduced: the manifest must stay useless to a
# reader looking for secrets, and must not become the object that the
# post-upload scanner replaces.
AUDIT_OPAQUE = re.compile(r"[0-9A-Za-z]{20,}")
PUBLISHED_DIR = "ocm-fvt-results"
# A caller-supplied destination names a directory created inside ARTIFACT_DIR,
# so it is restricted to a plain leading-alphanumeric name: no separator, no
# relative component and no leading dot can reach the rename.
PUBLISHED_NAME = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]{0,63}")
RESULT_REPORT = "report.xml"
# Entries publication deliberately keeps out of ARTIFACT_DIR, each with the
# fixed classification it is recorded under. These are named after cluster
# state - a cluster id, an IDP user - and they are the one group of names that
# never becomes a published object, so recording them would be the manifest
# disclosing a name for the first time. The rule that matched and a count per
# directory say what was held back and why without naming anything.
PRIVATE_STATE = {".datainfo": "datainfo", "cluster.ini": "cluster-ini",
                 "kubeconfig": "kubeconfig"}
PRIVATE_SUFFIX = ".kubeconfig"
PRIVATE_SUFFIX_RULE = "kubeconfig-named"
# Merged JUnit report that rosa-e2e-ocm-fvt copies into ARTIFACT_DIR before
# publication runs, so the manifest can tell "never collected" from "collected
# and later replaced".
MERGED_REPORT = "junit-ocm-fvt-report.xml"
# Per-phase Ginkgo reports ocmtest writes beside the merged report, as
# <phase>_<HHMMSS>.<xml|json> inside test-result-<job>-<timestamp>/.
#
# The phase part of that name is data the run chose, and some jobs use their
# own job name there, so it is matched by shape and then mapped onto this
# fixed list. The list is taken from public Prow artifacts only: a sample of
# 988 per-phase reports across six openshift-online/rosa-e2e ocm-fvt job
# families in the public test-platform-results-public bucket shows exactly
# these phase names recurring across jobs, in this order by the HHMMSS stamp
# each report carries. A name outside the list - a job name, or a phase added
# later - is counted under OTHER_PHASE and is never itself emitted, so no
# artifact field can carry a name this file does not already contain.
PHASES = ("pre-env-validation", "pre-vpc-cleaner", "pre-cluster-creation",
          "Day1Post", "Day1PostE2E", "CPUpgrade", "Day2Pre", "Day2CH", "Day2E2E",
          "Destructive", "post-alerts", "other", "post-clean")
OTHER_PHASE = "other"
PHASE_NAMES = frozenset(PHASES) - {OTHER_PHASE}
# The token is bounded only by what a file name can hold: it is never
# emitted, and refusing a long one would hide the report behind a state that
# means "no report", which is the ambiguity this artifact exists to remove.
PHASE_REPORT = re.compile(r"([0-9A-Za-z][0-9A-Za-z._-]{0,254})_([0-9]{6})\.(xml|json)")
RESULT_PREFIX = "test-result-"

# Failure summary. The per-phase reports and the merged JUnit report are
# verbose test output: the post-upload scanner replaces a whole matching object
# with a notice, so after a run that produced them there can be nothing left
# saying which cases failed. The summary is built from the same per-phase
# reports, before publication, but it is a projection rather than a copy. Every
# field it emits is either a member of a closed vocabulary fixed in this file or
# a bounded integer, so it carries no text taken from a report: no spec text,
# label, author tag, failure message, stack trace, resource identifier, file
# name, timestamp or URL. Nothing either censoring layer removes can be
# reconstructed from it, and it has no content for the scanner to match.
SUMMARY_SCHEMA = 1
# Ginkgo serialises types.SpecState to one of these strings (onsi/ginkgo
# types.SpecState MarshalJSON). A value outside the set is counted as
# "unrecognized" rather than copied into the summary.
SPEC_STATES = ("pending", "skipped", "passed", "failed", "aborted", "panicked",
               "interrupted", "timedout")
# types.SpecStateFailureStates.
FAILURE_STATES = ("failed", "aborted", "panicked", "interrupted", "timedout")
UNRECOGNIZED_STATE = "unrecognized"
# Ginkgo labels are the only metadata that carries a case identity, and the OCM
# FVT suites tag a case as id_<number> (the zero-egress case is referred to as
# @id_76488 in rosa-e2e-ocm-fvt-commands.sh). Only a canonical unpadded decimal
# run of at most nine digits is accepted, so a padded, token-shaped or
# otherwise ambiguous label contributes no identifier instead of being copied.
# A JSON true, a number or a nested list is not a string and never matches.
SUMMARY_CASE = re.compile(r"id_([1-9][0-9]{0,8})")
# No source location is emitted. A Ginkgo report carries LeafNodeLocation, but
# its file name comes from the private test repository: no public vocabulary
# fixes which basenames are legitimate, so any basename copied from a report
# would be arbitrary text from a censored object. A line number alone names
# nothing, so the summary omits both rather than widening the allowlist.
SUMMARY_MAX_RESULTS = 16
# Per phase per result directory, so a phase that wrote many reports cannot
# push another phase out of the summary entirely.
SUMMARY_MAX_REPORTS = 8
# OTHER_PHASE collects every unrecognised name at once, so it cannot share the
# per-phase budget a single known phase gets.
SUMMARY_MAX_OTHER_REPORTS = 32
# Directory entries examined. Counted apart from the report limit so that a
# result directory holding unrelated files does not hide the reports in it.
SUMMARY_MAX_SCAN = 4096
# A per-phase Ginkgo report carrying captured writer output is legitimately
# large, so the read bound is generous: refusing a real report would lose the
# diagnostic this artifact exists to keep. It bounds a degenerate document to
# a parse this step can afford, running after the test container has exited.
SUMMARY_MAX_BYTES = 8 * 1024 * 1024
SUMMARY_MAX_SPECS = 4096
# Labels examined per spec, over all of its label groups.
SUMMARY_MAX_LABELS = 256
SUMMARY_MAX_FAILURES = 64
# Why one report could not be folded in, in the order a phase reports them when
# it holds several unusable reports and no usable one.
SUMMARY_UNUSABLE = ("unreadable", "oversized", "malformed", "ambiguous")


def phase_report(name):
    """Classify a result-directory entry as one phase report, or None.

    Returns the phase, the extension and the HHMMSS stamp the name carries.
    The phase is a member of PHASES: a name the public artifacts show is a
    phase, or OTHER_PHASE for anything else that has the shape of a report.
    The token itself never leaves this function.
    """
    match = PHASE_REPORT.fullmatch(name)
    if match is None:
        return None
    token = match.group(1)
    return (token if token in PHASE_NAMES else OTHER_PHASE), match.group(3), match.group(2)


class PublishLimit(ValueError):
    """A refused publication, carrying a fixed content-free reason category.

    The category travels on the exception rather than being recovered from its
    message: an OSError message carries a path, so no exception text is ever
    copied into the manifest.
    """

    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def audit_component(name):
    """Render one path component without reproducing token-shaped text."""
    rendered = AUDIT_OPAQUE.sub(lambda run: f"_opaque{len(run.group())}_",
                                AUDIT_UNSAFE.sub("_", name))
    if len(rendered) > AUDIT_MAX_COMPONENT:
        rendered = rendered[:AUDIT_MAX_COMPONENT] + "~"
    return rendered


def audit_path(parts):
    """Render a traversal path over a conservative character set."""
    rendered = "/".join(audit_component(part) for part in parts)
    if len(rendered) > AUDIT_MAX_PATH:
        rendered = rendered[:AUDIT_MAX_PATH] + "~"
    return rendered


def private_state(name):
    """Return the fixed rule that keeps an entry private, or None."""
    if name in PRIVATE_STATE:
        return PRIVATE_STATE[name]
    if name.endswith(PRIVATE_SUFFIX):
        return PRIVATE_SUFFIX_RULE
    return None


def private_record(budget, parents, rule):
    """Count one private-state exclusion against its directory and rule.

    Counting rather than listing keeps the entry's own name out of the
    manifest, and bounds these records to one per rule per directory. The key
    is the directory's own identity, never its rendered form: rendering caps
    the path, and a cap applied to a directory deep enough to reach it would
    otherwise collapse distinct rules onto one key and drop the rule with the
    truncated tail. The rule travels in its own field for the same reason.
    """
    counted = budget["private"]
    key = (parents, rule)
    counted[key] = counted.get(key, 0) + 1


def private_rendered(counted):
    """Render private-state counts, folding directories that render alike."""
    folded = {}
    for (parents, rule), count in counted.items():
        key = (audit_path(parents) or ".", rule)
        folded[key] = folded.get(key, 0) + count
    return [{"path": path, "disposition": "excluded", "reason": "private-state",
             "rule": rule, "count": count} for (path, rule), count in folded.items()]


def audit_record(budget, parts, disposition, **fields):
    """Remember one disposition; the list is sorted and capped when written.

    The traversal already refuses to walk more than budget["entries_left"]
    entries, so the list this appends to is bounded by that same limit.
    """
    budget["audit"].append(dict(fields, path=audit_path(parts), disposition=disposition))


def failed_record(budget, parts, reason, rule=None):
    """Record the entry publication refused, then let the caller raise.

    Kept apart from the ordinary records because this one must survive: the
    ordinary list is capped, and the entry that stopped publication is the
    least useful record to lose. The list is bounded on its own, and holds a
    rendered path and a fixed reason - never the refusal's message.

    A private-state refusal passes the entry's directory and the rule that
    matched instead of the entry itself, so refusing one cannot disclose a
    name that excluding it would have withheld.
    """
    failures = budget["failed"]
    if len(failures) < AUDIT_MAX_FAILED:
        record = {"path": audit_path(parts) or ".", "disposition": "failed", "reason": reason}
        if rule is not None:
            record["rule"] = rule
        failures.append(record)


def audit_state(parent, name):
    """Classify one directory entry without following links."""
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return {"state": "missing"}
    except OSError as error:
        return {"state": "error", "errno": error.errno}
    if stat.S_ISDIR(info.st_mode):
        return {"state": "directory"}
    if stat.S_ISREG(info.st_mode):
        return {"state": "file", "size": info.st_size}
    return {"state": "irregular"}


def audit_expected_report(artifacts, budget):
    """Describe the merged JUnit report as publication left it.

    Only the main test step copies MERGED_REPORT into ARTIFACT_DIR. A caller
    publishing a second tree under its own name never collects it, so probing
    there would report a state of "missing" - which this manifest defines as
    collected and later replaced - for a report that was never expected.
    """
    if budget["destination"] != PUBLISHED_DIR:
        return {"state": "not-applicable", "name": MERGED_REPORT,
                "published_copies": budget["reports"]}
    return dict(audit_state(artifacts, MERGED_REPORT),
                name=MERGED_REPORT, published_copies=budget["reports"])


def audit_handoff(artifacts):
    """Inventory the artifact directory as the step hands it to the sidecar.

    Taken before the manifest itself is created, so the manifest is not among
    the names listed. A name listed with a byte count that the uploaded object
    no longer matches was removed or replaced after this step ended. A name
    missing from a listing that reports no dropped records was never collected.
    """
    names = []
    total = 0
    try:
        with os.scandir(artifacts) as entries:
            for entry in entries:
                total += 1
                if len(names) < AUDIT_MAX_SCAN:
                    names.append(entry.name)
    except OSError as error:
        return {"state": "error", "errno": error.errno, "entries": [], "records_dropped": total}
    names.sort()
    kept = names[:AUDIT_MAX_HANDOFF]
    return {
        "state": "listed",
        "entries": [dict(audit_state(artifacts, name), name=audit_path((name,)))
                    for name in kept],
        "records_dropped": total - len(kept),
    }


def audit_write(artifacts, budget, outcome):
    """Write the publication manifest; auditing never fails or masks the step."""
    def ordering(record):
        return record["path"], json.dumps(record, sort_keys=True)

    records = sorted(budget["audit"] + private_rendered(budget["private"]), key=ordering)
    kept = records[:AUDIT_MAX_ENTRIES]
    dropped = len(records) - len(kept)
    # The refused entry is appended after the cap rather than competing for a
    # place under it: it is the one record a reader needs when publication
    # stopped, and AUDIT_MAX_FAILED keeps the addition bounded. It is counted
    # out of records_dropped, which reports only what the cap discarded.
    kept = sorted(kept + budget["failed"], key=ordering)
    manifest = {
        "schema": AUDIT_SCHEMA,
        # Rendered like every other name in the manifest: the destination is
        # now caller-supplied rather than a constant, so it goes through the
        # same restricted character set and token-run elision.
        "publication": dict(outcome, destination=audit_component(budget["destination"])),
        "limits": {
            "entries_left": budget["entries_left"],
            "bytes_left": budget["bytes_left"],
            "records_dropped": dropped,
        },
        "expected_report": audit_expected_report(artifacts, budget),
        "handoff": audit_handoff(artifacts),
        "entries": kept,
    }
    try:
        descriptor = os.open(AUDIT_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o644, dir_fd=artifacts)
        with os.fdopen(descriptor, "w") as artifact:
            json.dump(manifest, artifact, sort_keys=True)
            artifact.write("\n")
    except Exception:  # pylint: disable=broad-except
        # This runs from a finally block: letting anything escape would replace
        # the publication failure it is meant to describe.
        print("WARNING: failed to write the ocm-fvt artifact audit manifest")


def stage(arguments):
    """Run the stage phase of artifact handling."""
    artifacts = os.path.abspath(arguments[1])
    if os.path.realpath(artifacts) != artifacts:
        raise ValueError("Artifact path must not contain symlinks")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    artifact_fd = os.open(artifacts, flags)
    try:
        parent = os.path.dirname(artifacts)
        if parent == artifacts:
            raise ValueError("Staging must be outside artifact collection")
        parent_fd = os.open(parent, flags)
        try:
            if os.fstat(parent_fd).st_dev != os.fstat(artifact_fd).st_dev:
                raise ValueError("Staging must use the artifact filesystem")
            workdir = tempfile.mkdtemp(prefix=".ocm-fvt-", dir=parent)
            if os.stat(workdir, follow_symlinks=False).st_dev != os.fstat(artifact_fd).st_dev:
                raise ValueError("Staging must use the artifact filesystem")
            print(workdir)
        finally:
            os.close(parent_fd)
    finally:
        os.close(artifact_fd)


def digest(arguments):
    """Run the digest phase of artifact handling."""
    with os.fdopen(os.open(arguments[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644), "w") as artifact:
        artifact.write(arguments[2] + "\n")


def handle_metadata(arguments):
    """Run the metadata phase of artifact handling."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


    def metadata(parent, name):
        try:
            info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            return {
                "type": stat.S_IFMT(info.st_mode),
                "mode": format(stat.S_IMODE(info.st_mode), "04o"),
                "uid": info.st_uid,
                "gid": info.st_gid,
            }
        except OSError as error:
            return {"errno": error.errno}


    def collect(parent, name, result_directory=False):
        result = metadata(parent, name)
        if result.get("type") != stat.S_IFDIR:
            return result
        try:
            descriptor = os.open(name, directory_flags, dir_fd=parent)
        except OSError as error:
            result["errno"] = error.errno
            return result
        try:
            children = []
            result["reports" if result_directory else "results"] = children
            with os.scandir(descriptor) as entries:
                for index, entry in enumerate(itertools.islice(entries, 129)):
                    merged = result_directory and entry.name == RESULT_REPORT
                    # The merged report keeps its record whatever the cap did:
                    # it is the one name that tells "never collected" from
                    # "collected and replaced", and the phase names now
                    # matched here can fill the list before it is reached.
                    if index == 128 or (not merged and len(children) ==
                                        (32 if result_directory else 16)):
                        result["truncated"] = True
                        if not merged:
                            # Keep scanning the bounded window: the merged
                            # report must be recorded even when the entries
                            # before it already filled the list.
                            continue
                    if result_directory:
                        report = phase_report(entry.name)
                        if merged:
                            label = "merged-xml"
                        elif report:
                            label = "-".join(report[:2])
                        else:
                            continue
                        child = metadata(descriptor, entry.name)
                    else:
                        if not entry.name.startswith(RESULT_PREFIX):
                            continue
                        label = "result-" + str(len(children) + 1)
                        child = collect(descriptor, entry.name, result_directory=True)
                    children.append(dict(child, label=label))
        except OSError as error:
            result["errno"] = error.errno
        finally:
            os.close(descriptor)
        return result


    groups = os.getgroups()
    with os.fdopen(os.open(arguments[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644), "w") as artifact:
        json.dump({
            "collector": {
                "euid": os.geteuid(), "egid": os.getegid(),
                "groups": groups[:32], "groups_truncated": len(groups) > 32,
            },
            "output": collect(None, arguments[1]),
        }, artifact)
        artifact.write("\n")


def summary_labels(spec):
    """Yield the bounded Ginkgo labels of one spec, ignoring anything else.

    One budget covers every group, rather than one per group: the identifier
    is the single datum this reads, so the bound has to be a number the whole
    spec is measured against instead of one a spec can multiply.
    """
    groups = [spec.get("LeafNodeLabels")]
    hierarchy = spec.get("ContainerHierarchyLabels")
    if isinstance(hierarchy, list):
        groups.extend(hierarchy)
    budget = SUMMARY_MAX_LABELS
    for group in groups:
        if not isinstance(group, list):
            continue
        for label in group:
            if budget == 0:
                return
            budget -= 1
            if isinstance(label, str):
                yield label


def summary_case(spec):
    """Return how a case was identified and the identifier, when there is one.

    A case is named only when the labels agree on exactly one identifier. Two
    different identifiers are reported as conflicting and neither is emitted,
    because guessing between them would attribute a failure to a case that did
    not fail. "ambiguous" is deliberately not reused here: it is already the
    state of a report whose shape this summary does not model.
    """
    found = set()
    for label in summary_labels(spec):
        match = SUMMARY_CASE.fullmatch(label)
        if match:
            found.add(int(match.group(1)))
            if len(found) > 1:
                return "conflicting", None
    if len(found) == 1:
        return "label", found.pop()
    return "none", None


def summary_state(spec):
    """Classify one spec against the fixed Ginkgo state vocabulary."""
    state = spec.get("State")
    if isinstance(state, str) and state in SPEC_STATES:
        return state
    return UNRECOGNIZED_STATE


def summary_specs(documents):
    """Return the specs of a report in the one form Ginkgo writes, or None.

    GenerateJSONReport encodes a []types.Report, so anything else - an object,
    a bare spec list, a report whose SpecReports is not a list - is a form this
    summary does not model, and is refused rather than guessed at. Returns the
    specs and whether the scan limit cut the list short.
    """
    if not isinstance(documents, list):
        return None
    collected = []
    for document in documents:
        if not isinstance(document, dict) or "SpecReports" not in document:
            # types.Report always carries SpecReports, as null when the suite
            # ran none, so a dict without it is some other document - a bare
            # spec, a merged summary - and is refused rather than read as a
            # report that held no specs.
            return None
        specs = document["SpecReports"]
        if specs is None:
            continue
        if not isinstance(specs, list):
            return None
        for spec in specs:
            if not isinstance(spec, dict):
                return None
            if len(collected) == SUMMARY_MAX_SPECS:
                return collected, True
            collected.append(spec)
    return collected, False


def summary_read(parent, name):
    """Read one bounded per-phase report, or name the reason it is unusable."""
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except OSError:
        return "unreadable", (), False
    content = None
    try:
        # Classified on the raw descriptor: os.open succeeds on a directory
        # and os.fdopen then raises without closing a descriptor it was handed
        # rather than opened, which would leak one per directory entry.
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
        else:
            with os.fdopen(descriptor, "rb") as report:
                # One byte past the limit, so a file that grew between the
                # stat and the read is refused rather than silently truncated.
                content = report.read(SUMMARY_MAX_BYTES + 1)
    except OSError:
        content = None
    if content is None:
        return "unreadable", (), False
    if len(content) > SUMMARY_MAX_BYTES:
        return "oversized", (), False
    try:
        # A report the run never finished writing is incomplete JSON, so a
        # truncated report is refused here rather than read as a short one.
        documents = json.loads(content.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, RecursionError):
        return "malformed", (), False
    collected = summary_specs(documents)
    if collected is None:
        return "ambiguous", (), False
    return "parsed", collected[0], collected[1]


def summary_fold(phase, record, specs, failures, budget):
    """Fold one parsed report into its phase counts and the failure list."""
    counts = record["counts"]
    for spec in specs:
        state = summary_state(spec)
        counts[state] = counts.get(state, 0) + 1
        if state not in FAILURE_STATES:
            continue
        record["failed"] += 1
        if len(failures) == SUMMARY_MAX_FAILURES:
            # Phases are folded in run order, so the budget reaches the test
            # phases before a teardown that fails every spec can exhaust it,
            # and each phase reports what it lost on its own record.
            record["dropped"] += 1
            budget["failures_dropped"] += 1
            continue
        identified, case = summary_case(spec)
        failure = {"phase": phase, "state": state, "identified": identified}
        if case is not None:
            failure["case"] = case
        failures.append(failure)


def summary_phase_state(record):
    """Reduce what happened to a phase's reports to one fixed state."""
    if not record["reports"]:
        return "unavailable" if not record["dropped_reports"] else "partial"
    if record["parsed_reports"] == record["reports"]:
        return "parsed" if not record["dropped_reports"] else "partial"
    if record["parsed_reports"]:
        return "partial"
    for reason in SUMMARY_UNUSABLE:
        if reason in record["unusable"]:
            return reason
    # No reason outside SUMMARY_UNUSABLE can reach this, and a phase whose
    # reports were all refused is never reported as readable.
    return "malformed"


def summary_result(parent, name, phases, failures, budget):
    """Summarise the per-phase JSON reports of one result directory."""
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    except OSError:
        budget["results_unreadable"] += 1
        return
    try:
        found = {phase: [] for phase in PHASES}
        with os.scandir(descriptor) as entries:
            for index, entry in enumerate(entries):
                if index == SUMMARY_MAX_SCAN:
                    budget["truncated"] = True
                    break
                report = phase_report(entry.name)
                # Only the JSON form is read: the sibling XML is JUnit, which
                # does not carry Ginkgo labels, so reading it could not name a
                # case without falling back to spec text.
                if report and report[1] == "json":
                    found[report[0]].append((report[2], entry.name))
        names = []
        for phase in PHASES:
            # Sorted by the stamp the report carries, so which reports a cap
            # keeps follows the run rather than the order the filesystem
            # returned them, and capped per phase, so a phase that wrote many
            # reports cannot displace another phase.
            found[phase].sort()
            limit = SUMMARY_MAX_OTHER_REPORTS if phase == OTHER_PHASE else SUMMARY_MAX_REPORTS
            kept = found[phase][:limit]
            phases[phase]["dropped_reports"] += len(found[phase]) - len(kept)
            names.extend((phase, report_name) for _, report_name in kept)
        # Run order, so the failure budget reaches the test phases first.
        for phase, report_name in names:
            record = phases[phase]
            record["reports"] += 1
            outcome, specs, truncated = summary_read(descriptor, report_name)
            if outcome != "parsed":
                record["unusable"].add(outcome)
                continue
            record["parsed_reports"] += 1
            record["specs"] += len(specs)
            record["specs_truncated"] = record["specs_truncated"] or truncated
            summary_fold(phase, record, specs, failures, budget)
    except OSError:
        budget["results_unreadable"] += 1
    finally:
        os.close(descriptor)


def summary_scan(output, phases, failures, budget):
    """Walk the result directories of the private output tree."""
    try:
        descriptor = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return "missing"
    except NotADirectoryError:
        # A symlinked or regular-file output path fails O_DIRECTORY|O_NOFOLLOW
        # here: the tree is not followed, and the summary says so instead of
        # reading through it.
        return "irregular"
    except OSError:
        return "unreadable"
    try:
        names = []
        with os.scandir(descriptor) as entries:
            for index, entry in enumerate(entries):
                if index == SUMMARY_MAX_SCAN:
                    budget["truncated"] = True
                    break
                if entry.name.startswith(RESULT_PREFIX):
                    names.append(entry.name)
        names.sort()
        budget["results_dropped"] = max(0, len(names) - SUMMARY_MAX_RESULTS)
        if budget["results_dropped"]:
            budget["truncated"] = True
            names = names[:SUMMARY_MAX_RESULTS]
        budget["results"] = len(names)
        for name in names:
            summary_result(descriptor, name, phases, failures, budget)
    except OSError:
        return "unreadable"
    finally:
        os.close(descriptor)
    return "scanned"


def handle_summary(arguments):
    """Run the summary phase of artifact handling.

    Written before publication, from the private output tree, so that a run
    whose reports are later replaced by a scanner notice still says which cases
    failed. It never changes what the suite did: the caller runs it after the
    test container has exited and ignores its status.
    """
    if len(arguments) != 3:
        raise ValueError("summary takes an output directory and an artifact path")
    phases = {phase: {"reports": 0, "parsed_reports": 0, "specs": 0, "failed": 0,
                      "dropped": 0, "dropped_reports": 0, "specs_truncated": False,
                      "unusable": set(), "counts": {}}
              for phase in PHASES}
    failures = []
    budget = {"results": 0, "results_dropped": 0, "results_unreadable": 0,
              "failures_dropped": 0, "truncated": False}
    try:
        output = summary_scan(arguments[1], phases, failures, budget)
    except Exception:  # pylint: disable=broad-except
        # Like the audit manifest: an artifact that says the tree could not be
        # read is worth more than no artifact, because "never written" and
        # "replaced after upload" look alike to a reader.
        output = "unreadable"
    failures.sort(key=lambda failure: (PHASES.index(failure["phase"]), failure["state"],
                                       failure.get("case", 0), failure["identified"]))
    summary = {
        "schema": SUMMARY_SCHEMA,
        "output": output,
        "phases": [{"phase": phase, "state": summary_phase_state(phases[phase]),
                    **{field: phases[phase][field] for field in
                       ("reports", "parsed_reports", "dropped_reports", "specs",
                        "specs_truncated", "failed", "dropped", "counts")}}
                   for phase in PHASES],
        "failures": failures,
        "limits": {
            "results": budget["results"],
            "results_dropped": budget["results_dropped"],
            "results_unreadable": budget["results_unreadable"],
            "failures_dropped": budget["failures_dropped"],
            "max_failures": SUMMARY_MAX_FAILURES,
            "truncated": budget["truncated"],
        },
    }
    with os.fdopen(os.open(arguments[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                           0o644), "w") as artifact:
        json.dump(summary, artifact, sort_keys=True)
        artifact.write("\n")


def publish_file(source, destination, budget, name, located):
    """Copy one regular file, recording what the copy did or why it stopped."""
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source)
    except PermissionError:
        budget["excluded"] = True
        audit_record(budget, located, "excluded", reason="unreadable")
        return
    with os.fdopen(descriptor, "rb") as original:
        opened = os.fstat(original.fileno())
        if not stat.S_ISREG(opened.st_mode):
            failed_record(budget, located, "type-changed")
            raise PublishLimit("type-changed", "Artifact changed type")
        if opened.st_size > budget["bytes_left"]:
            failed_record(budget, located, "size-limit")
            raise PublishLimit("size-limit", "Artifact size limit exceeded")
        target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=destination)
        copied = 0
        with os.fdopen(target, "wb") as artifact:
            while True:
                chunk = original.read(min(1024 * 1024, budget["bytes_left"] + 1))
                if not chunk:
                    break
                budget["bytes_left"] -= len(chunk)
                if budget["bytes_left"] < 0:
                    failed_record(budget, located, "size-limit")
                    raise PublishLimit("size-limit", "Artifact size limit exceeded")
                copied += len(chunk)
                artifact.write(chunk)
        if name == RESULT_REPORT:
            # Counted here, from the real name: the rendered paths in the
            # manifest are capped and may be truncated.
            budget["reports"] += 1
        audit_record(budget, located, "published", size=copied)


def publish(source, destination, budget, depth=0, parents=()):
    """Copy bounded regular diagnostics without following links or sharing ownership."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if depth > 16:
        failed_record(budget, parents, "depth-limit")
        raise PublishLimit("depth-limit", "Artifact nesting limit exceeded")
    with os.scandir(source) as entries:
        for entry in entries:
            budget["entries_left"] -= 1
            name = entry.name
            located = parents + (name,)
            # Classify before refusing. The entry that exhausts the budget is
            # recorded, and a private-state entry must not be named just
            # because it was the one the limit happened to land on: for those,
            # the record carries the directory and the rule, like the counters.
            rule = private_state(name)
            if budget["entries_left"] < 0:
                failed_record(budget, parents if rule else located, "entry-limit", rule=rule)
                raise PublishLimit("entry-limit", "Artifact entry limit exceeded")
            if rule is not None:
                private_record(budget, parents, rule)
                continue
            info = os.stat(name, dir_fd=source, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                try:
                    child = os.open(name, directory_flags, dir_fd=source)
                except PermissionError:
                    budget["excluded"] = True
                    audit_record(budget, located, "excluded", reason="unreadable")
                    continue
                try:
                    os.mkdir(name, 0o700, dir_fd=destination)
                    target = os.open(name, directory_flags, dir_fd=destination)
                    audit_record(budget, located, "directory")
                    try:
                        publish(child, target, budget, depth + 1, located)
                    finally:
                        os.close(target)
                finally:
                    os.close(child)
            elif stat.S_ISREG(info.st_mode):
                publish_file(source, destination, budget, name, located)
            else:
                budget["excluded"] = True
                audit_record(budget, located, "excluded", reason="irregular")


def handle_publish(arguments):
    """Run the publish phase of artifact handling."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    # Callers that publish a second tree into their own ARTIFACT_DIR - the
    # cleanup step publishes ocm-fvt-clean-results - name the destination;
    # the main test step omits it and keeps PUBLISHED_DIR.
    if len(arguments) not in (3, 4):
        raise ValueError("publish takes an output directory, an artifact directory and a name")
    published = arguments[3] if len(arguments) == 4 else PUBLISHED_DIR
    if not PUBLISHED_NAME.fullmatch(published):
        raise ValueError("Artifact destination must be a plain directory name")
    budget = {"entries_left": 8192, "bytes_left": 256 * 1024 * 1024, "excluded": False,
              "audit": [], "private": {}, "failed": [], "reports": 0,
              "destination": published}
    # Pessimistic until the publication tree is in place, so an unwinding this
    # function does not model - a signal, an interpreter error - cannot leave a
    # manifest claiming a publication that never completed.
    outcome = {"outcome": "aborted"}
    # The artifact directory is opened first and the manifest is written from a
    # finally block, so a publication that aborts half way - the case that is
    # hardest to reconstruct afterwards - still leaves its own record behind.
    artifacts = os.open(arguments[2], directory_flags)
    try:
        try:
            source = os.open(arguments[1], directory_flags)
            try:
                holding = os.open("..", directory_flags, dir_fd=source)
                try:
                    os.mkdir("published", 0o700, dir_fd=holding)
                    destination = os.open("published", directory_flags, dir_fd=holding)
                    try:
                        os.fchmod(destination, 0o700)
                        publish(source, destination, budget)
                    finally:
                        os.close(destination)
                    try:
                        os.stat(published, dir_fd=artifacts, follow_symlinks=False)
                    except FileNotFoundError:
                        os.rename("published", published,
                                  src_dir_fd=holding, dst_dir_fd=artifacts)
                    else:
                        raise PublishLimit("destination-exists",
                                           "Artifact destination already exists")
                    outcome = {"outcome": "published"}
                finally:
                    os.close(holding)
            finally:
                os.close(source)
        except PublishLimit as error:
            outcome = {"outcome": "failed", "reason": error.reason}
            raise
        except OSError as error:
            outcome = {"outcome": "failed", "reason": "io-error", "errno": error.errno}
            raise
        finally:
            audit_write(artifacts, budget, outcome)
    finally:
        os.close(artifacts)
    if budget["excluded"]:
        print("WARNING: unreadable or non-regular ocm-fvt artifacts excluded from publication")


def install():
    """Copy this delivered command into the shared volume for the FVT step."""
    shared = os.open(os.environ["SHARED_DIR"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        descriptor = os.open("ocm-fvt-artifacts.py", os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW, 0o600, dir_fd=shared)
        with os.fdopen(descriptor, "wb") as destination, open(__file__, "rb") as source:
            destination.write(source.read())
    finally:
        os.close(shared)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        install()
    else:
        {"stage": stage, "digest": digest, "metadata": handle_metadata,
         "summary": handle_summary, "publish": handle_publish}[sys.argv[1]]([sys.argv[0], *sys.argv[2:]])
