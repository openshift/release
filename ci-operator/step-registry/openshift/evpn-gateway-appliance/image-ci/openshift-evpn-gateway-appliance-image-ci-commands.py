#!/usr/bin/env python3

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(command, **kwargs):
    result = subprocess.run(command, check=False, **kwargs)
    if result.returncode < 0:
        raise SystemExit(128 - result.returncode)
    if result.returncode:
        raise SystemExit(result.returncode)
    return result


def remove_path(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def compress(source, destination):
    partial = Path(f"{destination}.partial")
    partial.unlink(missing_ok=True)
    print(f"image-ci: compressing {source} to {destination}", flush=True)
    try:
        with partial.open("wb") as output:
            run(["gzip", "--best", "-c", str(source)], stdout=output)
    except (OSError, SystemExit):
        partial.unlink(missing_ok=True)
        print(f"image-ci: failed to compress {source}", file=sys.stderr)
        raise SystemExit(1) from None
    os.replace(partial, destination)
    print(f"image-ci: saved {destination} {destination.stat().st_size}", flush=True)


def build_disk(kind, filename, destname, workroot, archive, artifacts, bib_image):
    out = Path(f"{workroot}/output-{kind}")
    remove_path(out)
    out.mkdir(parents=True, exist_ok=True)
    print(f"image-ci: building {kind} from {archive}", flush=True)
    run(
        [
            "podman",
            "run",
            "--rm",
            "--privileged",
            "--pull=newer",
            "-v",
            f"{out}:/output",
            "-v",
            f"{archive}:/appliance-image.tar:ro",
            bib_image,
            "--type",
            kind,
            "oci-archive:/appliance-image.tar",
        ]
    )

    result = run(
        ["find", str(out), "-type", "f", "-name", filename, "-print", "-quit"],
        stdout=subprocess.PIPE,
    )
    disk = result.stdout.decode().rstrip("\n")
    if not disk:
        print(f"image-ci: {filename} missing under {out}", file=sys.stderr)
        try:
            subprocess.run(
                ["find", str(out), "-type", "f", "-print"],
                stdout=sys.stderr,
                check=False,
            )
        except OSError:
            pass
        raise SystemExit(1)
    compress(Path(disk), Path(f"{artifacts}/{destname}.gz"))


def main():
    repo = (
        os.environ.get("EVPN_APPLIANCE_REPO")
        or "https://github.com/openshift/evpn-gateway-appliance"
    )
    pr = os.environ.get("EVPN_APPLIANCE_PR") or "6"
    workroot = os.environ.get("WORKROOT") or "/tmp/evpn-appliance-pr"
    image_tag = (
        os.environ.get("IMAGE_TAG") or "localhost/evpn-appliance-rhel10:ci-probe"
    )
    bootc_base = (
        os.environ.get("BOOTC_BASE") or "quay.io/centos-bootc/centos-bootc:stream10"
    )
    frr_image = (
        os.environ.get("FRR_IMAGE") or "registry.ci.openshift.org/ocp/4.22:metallb-frr"
    )
    node_exporter_image = (
        os.environ.get("NODE_EXPORTER_IMAGE")
        or "registry.ci.openshift.org/ocp/4.22:prometheus-node-exporter"
    )
    bib_image = (
        os.environ.get("BIB_IMAGE") or "quay.io/centos-bootc/bootc-image-builder:latest"
    )
    home = os.environ.get("HOME", "")
    pull_secret = next(
        (
            candidate
            for candidate in (
                "/var/run/registry-pull-credentials/.dockerconfigjson",
                "/etc/pull-secret/.dockerconfigjson",
                f"{home}/.docker/config.json",
            )
            if os.path.isfile(candidate)
        ),
        None,
    )
    if pull_secret:
        print(f"image-ci: using pull secret at {pull_secret}", flush=True)

    print(f"image-ci: fetching {repo} pull request {pr}", flush=True)
    if not pull_secret:
        print("image-ci: required registry pull secret not found", file=sys.stderr)
        raise SystemExit(1)
    os.environ["REGISTRY_AUTH_FILE"] = pull_secret

    remove_path(Path(workroot))
    Path(workroot).mkdir(parents=True, exist_ok=True)
    repo_slug = repo.removeprefix("https://github.com/")
    result = run(
        [
            "curl",
            "-fsSL",
            "-H",
            "Accept: application/vnd.github.sha",
            f"https://api.github.com/repos/{repo_slug}/commits/refs/pull/{pr}/head",
        ],
        stdout=subprocess.PIPE,
    )
    sha = result.stdout.decode().rstrip("\n")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        print("image-ci: could not read a full pull request head sha", file=sys.stderr)
        raise SystemExit(1)
    print(f"image-ci: HEAD {sha}", flush=True)
    print(f"image-ci: fetching immutable archive {sha}", flush=True)
    descriptor, download_archive = tempfile.mkstemp()
    os.close(descriptor)
    run(
        [
            "curl",
            "-fsSL",
            "-o",
            download_archive,
            "-L",
            f"{repo}/archive/{sha}.tar.gz",
        ]
    )
    run(
        [
            "tar",
            "-xzf",
            download_archive,
            "-C",
            workroot,
            "--strip-components=1",
        ]
    )
    Path(download_archive).unlink()

    os.chdir(f"{workroot}/image/rhel10")
    print(f"image-ci: building appliance image {image_tag}", flush=True)
    run(
        [
            "podman",
            "build",
            "-t",
            image_tag,
            "-f",
            "Containerfile",
            "--build-arg",
            f"BOOTC_BASE={bootc_base}",
            "--build-arg",
            f"FRR_IMAGE={frr_image}",
            "--build-arg",
            f"NODE_EXPORTER_IMAGE={node_exporter_image}",
            "--secret",
            f"id=dockerconfig,src={pull_secret}",
            ".",
        ]
    )

    os.chdir(workroot)
    artifacts = os.environ.get("ARTIFACT_DIR") or "/tmp/artifacts"
    os.environ["ARTIFACT_DIR"] = artifacts
    Path(artifacts).mkdir(parents=True, exist_ok=True)
    archive = f"{workroot}/appliance-image.tar"
    Path(archive).unlink(missing_ok=True)
    print(f"image-ci: saving {image_tag} to {archive}", flush=True)
    run(["podman", "save", "--format", "oci-archive", "-o", archive, image_tag])

    if not shutil.which("gzip"):
        print("image-ci: gzip is required to save disks", file=sys.stderr)
        raise SystemExit(1)

    disk_specs = (
        ("qcow2", "disk.qcow2", "disk.qcow2"),
        ("ami", "disk.raw", "disk.ami.raw"),
    )
    for kind, filename, destname in disk_specs:
        build_disk(kind, filename, destname, workroot, archive, artifacts, bib_image)

    compress(Path(archive), Path(f"{artifacts}/appliance-image.tar.gz"))

    smoke = Path(f"{workroot}/image/tools/smoke-payloads.py")
    if smoke.is_file() and shutil.which("python3"):
        print(
            "image-ci: running payload smoke without failing the disk build", flush=True
        )
        try:
            result = subprocess.run(["python3", str(smoke), image_tag], check=False)
        except OSError:
            result = None
        if result is None or result.returncode:
            print(
                "image-ci: payload smoke failed; disk artifacts are already saved",
                file=sys.stderr,
            )
    else:
        print(
            f"image-ci: skipping payload smoke because {smoke} is not in this archive",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
