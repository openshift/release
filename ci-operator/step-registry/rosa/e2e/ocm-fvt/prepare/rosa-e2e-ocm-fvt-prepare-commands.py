#!/usr/bin/env python3
"""Deliver and run OCM FVT artifact helpers through the step commands volume."""

import itertools
import json
import os
import re
import stat
import sys
import tempfile


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
                        if entry.name == "report.xml":
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


def publish(source, destination, budget, depth=0):
    """Copy bounded regular diagnostics without following links or sharing ownership."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if depth > 16:
        raise ValueError("Artifact nesting limit exceeded")
    with os.scandir(source) as entries:
        for entry in entries:
            budget["entries_left"] -= 1
            if budget["entries_left"] < 0:
                raise ValueError("Artifact entry limit exceeded")
            name = entry.name
            if name in (".datainfo", "cluster.ini", "kubeconfig") or name.endswith(".kubeconfig"):
                continue
            info = os.stat(name, dir_fd=source, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                try:
                    child = os.open(name, directory_flags, dir_fd=source)
                except PermissionError:
                    budget["excluded"] = True
                    continue
                try:
                    os.mkdir(name, 0o700, dir_fd=destination)
                    target = os.open(name, directory_flags, dir_fd=destination)
                    try:
                        publish(child, target, budget, depth + 1)
                    finally:
                        os.close(target)
                finally:
                    os.close(child)
            elif stat.S_ISREG(info.st_mode):
                try:
                    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source)
                except PermissionError:
                    budget["excluded"] = True
                    continue
                with os.fdopen(descriptor, "rb") as original:
                    opened = os.fstat(original.fileno())
                    if not stat.S_ISREG(opened.st_mode):
                        raise ValueError("Artifact changed type")
                    if opened.st_size > budget["bytes_left"]:
                        raise ValueError("Artifact size limit exceeded")
                    target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=destination)
                    with os.fdopen(target, "wb") as artifact:
                        while True:
                            chunk = original.read(min(1024 * 1024, budget["bytes_left"] + 1))
                            if not chunk:
                                break
                            budget["bytes_left"] -= len(chunk)
                            if budget["bytes_left"] < 0:
                                raise ValueError("Artifact size limit exceeded")
                            artifact.write(chunk)
            else:
                budget["excluded"] = True


def handle_publish(arguments):
    """Run the publish phase of artifact handling."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    budget = {"entries_left": 8192, "bytes_left": 256 * 1024 * 1024, "excluded": False}
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
            artifacts = os.open(arguments[2], directory_flags)
            try:
                try:
                    os.stat("ocm-fvt-results", dir_fd=artifacts, follow_symlinks=False)
                except FileNotFoundError:
                    os.rename("published", "ocm-fvt-results", src_dir_fd=holding, dst_dir_fd=artifacts)
                else:
                    raise FileExistsError("Artifact destination already exists")
            finally:
                os.close(artifacts)
        finally:
            os.close(holding)
    finally:
        os.close(source)
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
