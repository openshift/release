#!/usr/bin/env python3
"""Report or prepare a grouped agentic-ci patch bump from one Git snapshot."""

import argparse
import difflib
import hashlib
import json
import re
import signal
import subprocess
from dataclasses import dataclass
from http.client import HTTPException
from pathlib import Path
from urllib.request import HTTPRedirectHandler, Request, build_opener

import yaml

# The Prow lint image omits this checker-only runtime dependency.
# pylint: disable=import-error
from packaging.specifiers import SpecifierSet
from packaging.tags import Tag
from packaging.utils import canonicalize_name, parse_wheel_filename
from packaging.version import Version

# pylint: enable=import-error

REPO_ROOT = Path(__file__).resolve().parent.parent
PATHS = {
    "sippy": "ci-operator/config/openshift/sippy/openshift-sippy-main__agentic.yaml",
    "origin": "ci-operator/config/openshift/origin/openshift-origin-main__agentic.yaml",
    "ship-status-dash": (
        "ci-operator/config/openshift-eng/ship-status-dash/"
        "openshift-eng-ship-status-dash-main__agentic.yaml"
    ),
}
PACKAGE = "agentic-ci"
SERIES = (0, 5)
PYPI_URL = "https://pypi.org/pypi/agentic-ci/json"
PYPI_TIMEOUT = 15
MAX_PYPI_BYTES = 2 * 1024 * 1024
NUMBER = r"(?:0|[1-9][0-9]*)"
EXACT_VERSION = rf"{NUMBER}\.{NUMBER}\.{NUMBER}"
PIN = re.compile(rf"RUN python3 -m pip install --no-cache-dir agentic-ci==({EXACT_VERSION})")

# Allow the shared provisioning commands. A new RUN may install or change the
# package or interpreter indirectly and needs review before this check supports it.
PROVISIONING_RUNS = {
    "RUN dnf install -y podman fuse-overlayfs shadow-utils openssl python3-pip && dnf clean all",
    (
        "RUN setcap cap_setuid+ep /usr/bin/newuidmap && "
        "setcap cap_setgid+ep /usr/bin/newgidmap && "
        "touch /etc/subgid /etc/subuid && "
        "chmod -R g=u /etc/subuid /etc/subgid /etc/passwd /etc/group && "
        "chmod +rx /entrypoint.sh"
    ),
    "RUN chgrp -R 0 /workspace && chmod -R g=u /workspace",
    "RUN mkdir -p /home/vscode/.claude/plugins",
    (
        "RUN chgrp -R 0 /opt/ai-helpers /home/vscode/.claude && "
        "chmod -R g=u /opt/ai-helpers /home/vscode/.claude"
    ),
}


class Blocked(ValueError):
    """The inputs cannot support a recommendation."""


class InlineLoader(yaml.SafeLoader):  # pylint: disable=too-many-ancestors
    def compose_node(self, parent, index):
        event = self.peek_event()
        if getattr(event, "anchor", None) is not None:
            raise Blocked("YAML anchors and aliases are unsupported")
        return super().compose_node(parent, index)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


@dataclass(frozen=True)
class Pin:
    version: str
    lines: list[str]
    line: int
    column: int


def git(*args):
    try:
        return subprocess.run(
            ["git", "-C", str(REPO_ROOT), "--no-replace-objects", *args],
            check=True, capture_output=True, timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise Blocked(f"Git {args[0]} failed") from exc


def mapping(node, where):
    if not isinstance(node, yaml.MappingNode) or node.tag != "tag:yaml.org,2002:map":
        raise Blocked(f"{where} must be a YAML mapping")
    fields = {}
    seen = set()
    for key, value in node.value:
        if not isinstance(key, yaml.ScalarNode) or key.tag != "tag:yaml.org,2002:str":
            raise Blocked(f"{where} has an unsupported key")
        name = key.value.casefold()
        if name in seen:
            raise Blocked(f"{where} has a duplicate key")
        seen.add(name)
        fields[key.value] = value
    return fields


def string(node):
    if isinstance(node, yaml.ScalarNode) and node.tag == "tag:yaml.org,2002:str":
        return node.value
    return None


def read_pin(source):
    if "\r" in source or not source.endswith("\n"):
        raise Blocked("expected LF-terminated YAML")
    config = mapping(yaml.compose(source, Loader=InlineLoader), "config")
    images = mapping(config.get("images"), "images")
    items = images.get("items")
    if (set(images) != {"items"} or not isinstance(items, yaml.SequenceNode)
            or items.tag != "tag:yaml.org,2002:seq"):
        raise Blocked("expected images.items list")
    definitions = [mapping(item, "image") for item in items.value]
    if any(not string(image.get("to")) for image in definitions):
        raise Blocked("image is missing a named target")
    matches = [image for image in definitions if string(image["to"]) == "agentic-dev"]
    if len(matches) != 1:
        raise Blocked("expected exactly one agentic-dev image")
    image = matches[0]
    if set(image) - {"to", "from", "inputs", "dockerfile_literal"}:
        raise Blocked("unsupported agentic-dev image fields")
    literal = image.get("dockerfile_literal")
    base = string(image.get("from"))
    if not base or string(literal) is None or literal.style != "|":
        raise Blocked("expected an agentic-dev base and inline literal Dockerfile")

    lines = [line + "\n" for line in source.split("\n")[:-1]]
    pin = None
    in_final_stage = False
    continued = ""
    for offset, content in enumerate(literal.value.split("\n"), literal.start_mark.line + 1):
        line = content.strip()
        if re.match(r"#\s*(escape|syntax)\s*=", line, re.IGNORECASE):
            raise Blocked("unsupported Dockerfile parser directive")
        if not line or line.startswith("#"):
            continue
        if line.endswith("\\"):
            continued += line[:-1].strip() + " "
            continue
        instruction = continued + line
        if instruction.startswith("COPY ") and "<<" in instruction:
            raise Blocked("Dockerfile COPY heredocs are unsupported")
        match = PIN.fullmatch(instruction)
        if match:
            if pin or continued or not in_final_stage:
                raise Blocked("ambiguous or unsupported agentic-ci install")
            if lines[offset].lstrip(" ") != instruction + "\n":
                raise Blocked("cannot locate the literal pin in the source YAML")
            indent = len(lines[offset]) - len(instruction) - 1
            pin = Pin(match[1], lines, offset, indent + match.start(1))
        elif instruction.startswith("FROM "):
            if pin:
                raise Blocked("agentic-ci install is outside the final stage")
            in_final_stage = instruction == f"FROM {base}"
        elif instruction.startswith("RUN "):
            if instruction not in PROVISIONING_RUNS:
                raise Blocked("unsupported RUN in agentic-dev Dockerfile")
        elif instruction != "ENV BUILDAH_ISOLATION=chroot" and not re.fullmatch(
            r"(COPY|USER|WORKDIR|ENTRYPOINT|CMD) .+", instruction
        ):
            raise Blocked("unsupported instruction in agentic-dev Dockerfile")
        continued = ""
    if continued or not pin:
        raise Blocked("expected one active exact agentic-ci install")
    return pin


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Blocked("duplicate JSON key")
        result[key] = value
    return result


def read_pypi():
    def timed_out(signum, frame):
        raise TimeoutError("PyPI request exceeded its deadline")

    previous = signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(PYPI_TIMEOUT)
    try:
        request = Request(PYPI_URL, headers={"Accept": "application/json"})
        with build_opener(NoRedirect()).open(request, timeout=PYPI_TIMEOUT) as response:
            if response.status != 200 or response.headers.get_content_type() != "application/json":
                raise Blocked("unexpected PyPI response")
            payload = response.read(MAX_PYPI_BYTES + 1)
        if len(payload) > MAX_PYPI_BYTES:
            raise Blocked("PyPI metadata exceeds the size limit")
        return payload
    except (HTTPException, OSError) as exc:
        raise Blocked("public PyPI lookup failed or timed out") from exc
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def published_releases(payload):
    data = json.loads(payload, object_pairs_hook=unique_object)
    if not isinstance(data, dict) or not isinstance(data.get("info"), dict):
        raise Blocked("invalid PyPI project metadata")
    name = data["info"].get("name")
    releases = data.get("releases")
    if not isinstance(name, str) or canonicalize_name(name) != PACKAGE or not isinstance(releases, dict):
        raise Blocked("invalid PyPI project or release metadata")

    result = {}
    for number, files in releases.items():
        version = Version(number)
        if version in result or not isinstance(files, list):
            raise Blocked("ambiguous or invalid PyPI release metadata")
        if any(not isinstance(file, dict) or not isinstance(file.get("yanked"), bool) for file in files):
            raise Blocked("missing or invalid PyPI file yanked status")
        result[version] = [file for file in files if not file["yanked"]]
    return result


def read_evidence(path, source_commit):
    if path is None:
        raise Blocked("interpreter evidence is required for the three agentic-dev images")
    with path.open("rb") as stream:
        payload = stream.read(16385)
    if len(payload) > 16384:
        raise Blocked("image evidence exceeds the size limit")
    data = json.loads(payload, object_pairs_hook=unique_object)
    if not isinstance(data, dict) or data.get("source_commit") != source_commit:
        raise Blocked("image evidence must name the resolved source commit")
    images = data.get("images")
    if not isinstance(images, dict) or images.keys() != PATHS.keys():
        raise Blocked("image evidence must cover exactly the three agentic-dev images")
    for name, evidence in images.items():
        if not isinstance(evidence, dict) or evidence.keys() != {"image_digest", "python"}:
            raise Blocked(f"{name} evidence must include image_digest and python")
        image_digest, python = evidence["image_digest"], evidence["python"]
        if not isinstance(image_digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", image_digest):
            raise Blocked(f"{name} evidence has an invalid image digest")
        if not isinstance(python, str) or not re.fullmatch(rf"3\.{NUMBER}\.{NUMBER}", python):
            raise Blocked(f"{name} evidence must give an exact final Python 3 version")
    return images


def matching_wheel(version, files, images):
    for file in files:
        if file.get("packagetype") != "bdist_wheel":
            continue
        filename = file.get("filename")
        if not isinstance(filename, str):
            raise Blocked("PyPI wheel filename is missing")
        name, wheel_version, _, tags = parse_wheel_filename(filename)
        if name != PACKAGE or wheel_version != version:
            raise Blocked("PyPI wheel does not match its release")
        if Tag("py3", "none", "any") not in tags:
            continue
        requires_python = file.get("requires_python")
        if not isinstance(requires_python, str) or not requires_python.strip():
            continue
        spec = SpecifierSet(requires_python)
        if not all(Version(image["python"]) in spec for image in images.values()):
            continue
        digests = file.get("digests")
        sha256 = digests.get("sha256") if isinstance(digests, dict) else None
        if not isinstance(sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", sha256):
            raise Blocked("PyPI wheel is missing a valid SHA-256 digest")
        return {"filename": filename, "requires_python": requires_python, "sha256": sha256}
    return None


def make_patch(pins, candidate):
    hunks = []
    for name, pin in pins.items():
        path = PATHS[name]
        updated = pin.lines.copy()
        line = updated[pin.line]
        updated[pin.line] = line[:pin.column] + candidate + line[pin.column + len(pin.version):]
        hunks.extend(difflib.unified_diff(pin.lines, updated, f"a/{path}", f"b/{path}"))
    return "".join(hunks)


def check(args, report):
    commit = git("rev-parse", "--verify", "--end-of-options", f"{args.ref}^{{commit}}").decode().strip()
    report["source_commit"] = commit
    entries = git("ls-tree", "-z", commit, "--", *PATHS.values()).decode().split("\0")
    blobs = {}
    for entry in filter(None, entries):
        fields, path = entry.split("\t", 1)
        blobs[path] = fields.split()
    pins = {}
    for name, path in PATHS.items():
        details = report["pins"][path]
        try:
            entry = blobs.get(path, [])
            if len(entry) != 3 or entry[:2] != ["100644", "blob"]:
                raise Blocked("missing regular config file")
            details["blob"] = entry[2]
            pins[name] = read_pin(git("cat-file", "blob", entry[2]).decode())
            details["version"] = pins[name].version
        except yaml.YAMLError:
            details["error"] = "invalid YAML or unsupported document structure"
        except (Blocked, UnicodeError) as exc:
            details["error"] = str(exc)
    if len(pins) != len(PATHS):
        raise Blocked("one or more agentic-dev pins could not be read")
    versions = {pin.version for pin in pins.values()}
    if len(versions) != 1:
        raise Blocked("the three active agentic-ci pins differ")
    current = Version(versions.pop())
    if current.release[:2] != SERIES:
        raise Blocked("the common pin is outside the maintained 0.5 series")

    payload = read_pypi()
    report["pypi"]["sha256"] = hashlib.sha256(payload).hexdigest()
    releases = published_releases(payload)
    if current not in releases:
        raise Blocked("the current pin is missing from PyPI release metadata")
    later_series = {}
    newer_patches = []
    for version in sorted(releases, reverse=True):
        series = (version.major, version.minor)
        if version.epoch or version <= current or not releases[version]:
            continue
        if series > SERIES:
            later_series.setdefault(series, str(version))
        elif (
            series == SERIES and len(version.release) == 3 and not version.is_prerelease
            and not version.is_postrelease and version.local is None
        ):
            newer_patches.append(version)
    report["newer_series"] = list(later_series.values())
    if not newer_patches:
        report.update(status="no_change", reason="no newer non-yanked final 0.5.x patch on PyPI")
        return

    images = read_evidence(args.image_evidence, commit)
    report["image_evidence"] = images
    for version in newer_patches:
        wheel = matching_wheel(version, releases[version], images)
        if wheel:
            break
    else:
        raise Blocked("no newer final 0.5.x patch has an evidenced compatible non-yanked wheel")
    candidate = str(version)
    if args.prepare_patch is not None and args.prepare_patch != candidate:
        raise Blocked(f"reviewed candidate does not match the current eligible candidate ({candidate})")
    report.update(
        status="update_available",
        reason="newer final 0.5.x patch with a non-yanked universal wheel matching all three Python versions",
        candidate=candidate,
        wheel=wheel,
        newer_patches_without_verified_wheel=[str(item) for item in newer_patches if item > version],
    )
    if args.prepare_patch is not None:
        report["patch"] = make_patch(pins, candidate)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="refs/remotes/origin/main", help="local Git ref or commit")
    parser.add_argument("--image-evidence", type=Path, help="reviewed interpreter evidence JSON")
    parser.add_argument("--prepare-patch", metavar="VERSION", help="include the diff for this reviewed candidate")
    args = parser.parse_args(argv)
    report = {
        "status": "blocked",
        "reason": None,
        "source_commit": None,
        "pins": {path: {"version": None, "blob": None} for path in PATHS.values()},
        "pypi": {"url": PYPI_URL, "sha256": None},
        "newer_series": [],
        "candidate": None,
    }
    try:
        check(args, report)
    except (OSError, RecursionError, ValueError) as exc:
        report["reason"] = str(exc)
    print(json.dumps(report, indent=2))
    return 2 if report["status"] == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
