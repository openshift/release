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
# Worst case about 160 KiB: AUDIT_MAX_ENTRIES publication records and
# AUDIT_MAX_HANDOFF inventory records, each holding a bounded rendered name,
# plus a small fixed object. Both lists are sorted before they are capped, so
# which records survive a cap is reproducible rather than readdir order.
AUDIT_MAX_ENTRIES = 512
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
    manifest, and bounds these records to one per rule per directory.
    """
    counted = budget["private"]
    path = audit_path(parents + (rule,))
    counted[path] = counted.get(path, 0) + 1


def audit_record(budget, parts, disposition, **fields):
    """Remember one disposition; the list is sorted and capped when written.

    The traversal already refuses to walk more than budget["entries_left"]
    entries, so the list this appends to is bounded by that same limit.
    """
    budget["audit"].append(dict(fields, path=audit_path(parts), disposition=disposition))


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
    """Describe the merged JUnit report as publication left it."""
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
    counted = [{"path": path, "disposition": "excluded", "reason": "private-state",
                "count": count} for path, count in budget["private"].items()]
    records = sorted(budget["audit"] + counted,
                     key=lambda record: (record["path"], json.dumps(record, sort_keys=True)))
    kept = records[:AUDIT_MAX_ENTRIES]
    manifest = {
        "schema": AUDIT_SCHEMA,
        "publication": dict(outcome, destination=PUBLISHED_DIR),
        "limits": {
            "entries_left": budget["entries_left"],
            "bytes_left": budget["bytes_left"],
            "records_dropped": len(records) - len(kept),
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
    phase_report = re.compile(
        r"(pre-env-validation|pre-vpc-cleaner|pre-cluster-creation|post-clean)_[0-9]{6}\.(xml|json)"
    )


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
                    if index == 128 or len(children) == (32 if result_directory else 16):
                        result["truncated"] = True
                        break
                    if result_directory:
                        match = phase_report.fullmatch(entry.name)
                        if entry.name == RESULT_REPORT:
                            label = "merged-xml"
                        elif match:
                            label = "-".join(match.groups())
                        else:
                            continue
                        child = metadata(descriptor, entry.name)
                    else:
                        if not entry.name.startswith("test-result-"):
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


def publish(source, destination, budget, depth=0, parents=()):
    """Copy bounded regular diagnostics without following links or sharing ownership."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if depth > 16:
        raise PublishLimit("depth-limit", "Artifact nesting limit exceeded")
    with os.scandir(source) as entries:
        for entry in entries:
            budget["entries_left"] -= 1
            if budget["entries_left"] < 0:
                raise PublishLimit("entry-limit", "Artifact entry limit exceeded")
            name = entry.name
            located = parents + (name,)
            rule = private_state(name)
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
                try:
                    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source)
                except PermissionError:
                    budget["excluded"] = True
                    audit_record(budget, located, "excluded", reason="unreadable")
                    continue
                with os.fdopen(descriptor, "rb") as original:
                    opened = os.fstat(original.fileno())
                    if not stat.S_ISREG(opened.st_mode):
                        raise PublishLimit("type-changed", "Artifact changed type")
                    if opened.st_size > budget["bytes_left"]:
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
                                raise PublishLimit("size-limit", "Artifact size limit exceeded")
                            copied += len(chunk)
                            artifact.write(chunk)
                    if name == RESULT_REPORT:
                        # Counted here, from the real name: the rendered paths
                        # in the manifest are capped and may be truncated.
                        budget["reports"] += 1
                    audit_record(budget, located, "published", size=copied)
            else:
                budget["excluded"] = True
                audit_record(budget, located, "excluded", reason="irregular")


def handle_publish(arguments):
    """Run the publish phase of artifact handling."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    budget = {"entries_left": 8192, "bytes_left": 256 * 1024 * 1024, "excluded": False,
              "audit": [], "private": {}, "reports": 0}
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
                        os.stat(PUBLISHED_DIR, dir_fd=artifacts, follow_symlinks=False)
                    except FileNotFoundError:
                        os.rename("published", PUBLISHED_DIR,
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
         "publish": handle_publish}[sys.argv[1]]([sys.argv[0], *sys.argv[2:]])
