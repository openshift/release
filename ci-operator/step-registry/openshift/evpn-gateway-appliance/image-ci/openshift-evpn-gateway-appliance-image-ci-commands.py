#!/usr/bin/env python3

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit, urlunsplit

FETCH_TIMEOUT = 180
BUILD_TIMEOUT = 45 * 60
SMOKE_TIMEOUT = 10 * 60


def timeout_for(command):
    program = Path(command[0]).name
    if program in {"podman", "docker"}:
        return BUILD_TIMEOUT
    if program == "python3":
        return SMOKE_TIMEOUT
    return FETCH_TIMEOUT


def run(command, **kwargs):
    timeout = kwargs.pop("timeout", timeout_for(command))
    try:
        result = subprocess.run(command, check=False, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired as expired:
        shown = shlex.join(command)
        print(
            f"image-ci: {shown} timed out after {expired.timeout}s",
            file=sys.stderr,
        )
        raise SystemExit(1) from expired
    if result.returncode < 0:
        raise SystemExit(128 - result.returncode)
    if result.returncode:
        raise SystemExit(result.returncode)
    return result


CREDENTIAL_QUERY_KEYS = frozenset(
    {
        "access_token",
        "api_key",
        "apikey",
        "auth",
        "authorization",
        "client_secret",
        "password",
        "passwd",
        "secret",
        "token",
    }
)


def repository_url(raw):
    parts = urlsplit(raw)
    if parts.username is not None or parts.password is not None:
        print("image-ci: repository URL must not include user info", file=sys.stderr)
        raise SystemExit(1)
    for key, _value in parse_qsl(parts.query, keep_blank_values=True):
        if key.lower() in CREDENTIAL_QUERY_KEYS:
            print(
                "image-ci: repository URL must not include query credentials",
                file=sys.stderr,
            )
            raise SystemExit(1)
    if parts.scheme not in {"https", "file"} or not parts.path:
        print("image-ci: repository URL must be https or file", file=sys.stderr)
        raise SystemExit(1)
    host = parts.hostname or ""
    if parts.port is not None:
        host = f"{host}:{parts.port}"
    return urlunsplit((parts.scheme, host, parts.path, "", ""))


def remove_path(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def main():
    repo = repository_url(
        os.environ.get("EVPN_APPLIANCE_REPO")
        or "https://github.com/openshift/evpn-gateway-appliance"
    )
    pr = os.environ.get("EVPN_APPLIANCE_PR") or "6"
    workroot = os.environ.get("WORKROOT") or "/tmp/evpn-appliance-pr"
    image_tag = os.environ.get("IMAGE_TAG") or "localhost/evpn-appliance-rhel10:ci"
    nested_tag = (
        os.environ.get("NESTED_CI_TAG") or "localhost/evpn-appliance-rhel10:nested-ci"
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

    os.chdir(workroot)
    engine = shutil.which("podman") or shutil.which("docker")
    if not engine:
        print("image-ci: no podman/docker found", file=sys.stderr)
        raise SystemExit(1)
    print(f"image-ci: building appliance image {image_tag}", flush=True)
    run(
        [
            engine,
            "build",
            "-f",
            "image/rhel10/Containerfile",
            "-t",
            image_tag,
            "--build-arg",
            f"BOOTC_BASE={bootc_base}",
            "--build-arg",
            f"FRR_IMAGE={frr_image}",
            "--build-arg",
            f"NODE_EXPORTER_IMAGE={node_exporter_image}",
            "--secret",
            f"id=dockerconfig,src={pull_secret}",
            "image/rhel10",
        ]
    )
    print(f"image-ci: building nested ci image {nested_tag}", flush=True)
    run(
        [
            engine,
            "build",
            "--pull=never",
            "-f",
            "image/rhel10/Containerfile.nested-ci",
            "--build-arg",
            f"APPLIANCE_IMAGE={image_tag}",
            "-t",
            nested_tag,
            "image/rhel10",
        ]
    )

    # artifacts = os.environ.get("ARTIFACT_DIR") or "/tmp/artifacts"
    # os.environ["ARTIFACT_DIR"] = artifacts
    # Path(artifacts).mkdir(parents=True, exist_ok=True)
    # smoke = Path(workroot) / "image/tools/smoke-payloads.py"
    # if not smoke.is_file():
    #     print(f"image-ci: {smoke} is not in this archive", file=sys.stderr)
    #     raise SystemExit(1)
    # print(f"image-ci: running payload smoke {image_tag}", flush=True)
    # run(["python3", str(smoke), image_tag])


if __name__ == "__main__":
    main()
