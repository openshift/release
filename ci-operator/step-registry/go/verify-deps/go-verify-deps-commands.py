#!/usr/bin/env python3
"""go-verify-deps step: verify a tested repo's vendored Go dependencies.

Idiomatic, standard-library-only port of the original go-verify-deps-commands.sh
(ART-26147). It performs two things, in order, when run as the step command:

1. An opt-in Go module proxy availability check (CHECK_GOPROXY_AVAILABILITY):
   before a build, confirm that pinned pseudo-versions in go.mod are actually
   resolvable on the Go module proxy, so an unavailable commit fails here with an
   actionable message instead of as an opaque 404 inside the ART/Konflux hermeto
   prefetch later.
2. The original vendor/go.mod consistency flow (go-directive patch check,
   v3.9.0+incompatible guard, ``go list``, ``go mod tidy``, ``go [work] vendor``,
   and a ``git status --porcelain --ignored`` diff).

Run ``--self-test`` (or set ``GOPROXY_SELF_TEST=1``) to execute the embedded
self-test instead of the real flow. All user-facing message text is identical to
the shell original.
"""
# pylint: disable=too-many-lines  # single-file step command (run_as_script) kept self-contained

from __future__ import annotations

import argparse
import contextlib
import enum
import fnmatch
import inspect
import io
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

# --------------------------------------------------------------------------- #
# Constants                                                                    #
# --------------------------------------------------------------------------- #

# A pseudo-version ends in a 14-digit UTC timestamp and a 12-hex commit prefix,
# optionally followed by "+incompatible". The separator before the timestamp is
# "-" (base-less form) or "." (pre-release / post-release form); matching both is
# required to detect pins like v1.37.0-alpha.0.0.20261110024958-4608138db381.
PSEUDO_RE = re.compile(r"[-.][0-9]{14}-[0-9a-f]{12}([+]incompatible)?$")

DEFAULT_PROXY = "https://proxy.golang.org"
OUTAGE_THRESHOLD = 3  # consecutive transport failures that trip the outage stop
DEFAULT_PROBE_TIMEOUT = 15.0  # per-probe timeout (seconds) when no deadline bounds it

# Go module proxy availability-check tuning. These used to be consumer-facing env
# knobs (GOPROXY_CHECK_RETRIES / _RETRY_DELAY_SECONDS / _DEADLINE_SECONDS) but are
# now fixed internals: sensible defaults that need no per-repo configuration.
GOPROXY_RETRIES = 5  # probe attempts per module version (absorb proxy propagation)
GOPROXY_RETRY_DELAY_SECONDS = 10  # base backoff per attempt (attempt N waits N times this)
GOPROXY_DEADLINE_SECONDS = 120  # overall wall-clock budget for the probe loop (0 disables)

# Bounded jitter fraction applied to each backoff delay (+/-20%).
JITTER_FRACTION = 0.2
# Module-level RNG for backoff jitter. Seed it (``JITTER_RNG.seed(...)``) in tests to make
# the jitter deterministic.
JITTER_RNG = random.Random()

# Optional injection hook: a callable(url) -> status (or (url, timeout)) returning a
# status-code string, a (code, retry_after_seconds) tuple, or a ProbeResponse. When
# set (by the self-test / unit tests) it overrides curl/wget and the GOPROXY_PROBE_CMD
# env. This mirrors the shell GOPROXY_PROBE_CMD indirection.
PROBE_OVERRIDE = None

_GENERAL_REMEDIATION = """\
ERROR: An discrepancy was found in go dependency metadata or it could not
be checked successfully. Common failures:
- go mod tidy failed to run with the repository's configured "build root".
  Errors output like 'go.mod file indicates go 1.21, but maximum supported version is 1.17'
  indicate your go.mod requests 1.21, but your Test Platform build root is based
  on a go 1.17 builder image. The following documentation explains build root configuration:
  https://docs.ci.openshift.org/docs/architecture/images/#controlling-go-versions-in-component-repositories
  Generally, you will want 'build_root.from_repository: true' in your
  ci-operator configuration file and to manage your build root in your component
  repository in .ci-operator.yaml (.ci-operator.yaml is ignored if from_repository: true
  is not set).

- go.mod information may be incomplete / inaccurate.

- /vendor may not contain the versions declared in go.mod or certain
  files which should be in /vendor have not been checked in. This can
  happen due to .gitignore rules ignoring files in /vendor .

- You may be trying to introduce a code change in vendored content. This
  is not permitted. If you must make custom changes to a module,
  there are two options:
  1. Use a local go.mod replace statement. For example:
     replace example.com/foo/bar => ../bar-modified
  2. When multiple repositories need the same modification, it may prove easier
     to fork the upstream dependency into github.com/openshift, customize
     a branch, and vendor the fork in your go.mod. For example:
     https://github.com/openshift/golang-crypto/tree/patch_v0.33.openshift.1

Job logs show files that have been added or modified by running
"go mod tidy" and "go mod vendor" (or "go work vendor" for workspaces).
You can run these commands locally and check for discrepancies with
> git status --porcelain --ignored.

This check does not respect .gitignore entries. If .gitignore is masking
files in vendor/, the check will fail. Update your .gitignore file to
prevent it from acting on files in vendor/.

In order for the OpenShift Build and Release Team (ART) to create
productized builds, all dependencies must be present and consistent.
Please correct these discrepancies before merging the PR."""

_MODLIST_REMEDIATION = """\
ERROR: go list -mod=readonly -m all failed with the message listed above.
Cachito used in ART builds will fail to resolve dependencies offline.
Typically, a pinned version is missing in go.mod, e.g.:
    replace k8s.io/foo => k8s.io/foo v0.26.0"""

_INCOMPATIBLE_V39_MESSAGE = """\
ERROR: Detected github.com/openshift/api or client-go v3.9.0+incompatible in go.mod
Do not use this 'version' of openshift/api or client-go . For complex
reasons, this invalid version is a contagion which causes modules
which import your code to also import the invalid version.
Fix:
Use an explicit commit in your 'require' statement. You can do
this with 'go get github.com/openshift/api@latest' or just specify
the import directly. For example, for openshift/api require:
        github.com/openshift/api@v0.0.0-20250710004639-926605d3338b
In addition, remove any 'replace' statement that may have been in
use for the module.

Unfortunately, this will be necessary until modules you require
eliminate their own use of v3.9.0+incompatible import.

Detail: v3.9.0+incompatible used to be a valid version/tag. However
managing @latest via tags was not desired, so the version was deleted.
Before that deletion, many modules had incorporated the now invalid
version. Since the version is greater than v0.0.0 pseudo-versions,
go 'upgrades' importing go.mods to use v3.9.0+incompatible and the
contagion spreads."""

_MISSING_HEADER = """\
ERROR: go.mod pins one or more Go module pseudo-versions that the Go
module proxy cannot resolve. Each one below would make the ART/Konflux
hermeto prefetch fail later with an opaque 404 while fetching the
module's .zip, so the build is stopped here instead."""

_MISSING_FOOTER = """\
Likely cause:
- This typically happens with very large dependency repositories when the
  pinned commit is far from the nearest semver tag: the proxy cannot
  compute or serve a pseudo-version for a commit with no nearby tag, so
  the request 404s.

How to fix:
  1. Ask the maintainers of the dependency repository to push a semver
     tag on (or after) the pinned commit, so a nearby tag exists.
  2. After the tag is published (allow a few minutes for proxy
     propagation), update this repo to require the tag instead of the
     pseudo-version:
       - plain require:   go get <module>@<new-tag>
       - replace directive: go mod edit -replace <old>=<target>@<new-tag>
     then run 'go mod tidy' (and 'go mod vendor' if this repo vendors)
     to record the change.
  3. IMPORTANT: 'go mod tidy' alone will NOT swap an existing pinned
     pseudo-version or replace directive to the new tag. You must set the
     version explicitly first (step 2).

Alternatively, simply re-running the build after the tag exists may
succeed: the original pseudo-version can become resolvable once a nearby
tag is present on the proxy."""


# --------------------------------------------------------------------------- #
# Data types                                                                   #
# --------------------------------------------------------------------------- #

class Outcome(enum.Enum):
    """Result of probing a single module version on the proxy."""

    AVAILABLE = "AVAILABLE"
    MISSING = "MISSING"
    INCONCLUSIVE = "INCONCLUSIVE"


@dataclass(frozen=True)
class ProbeResponse:
    """Normalized result of a single probe call: the HTTP status code plus any
    server-advertised Retry-After delay in seconds (0.0 when none was surfaced).
    The curl and wget backends parse Retry-After from the response headers; the
    external GOPROXY_PROBE_CMD still returns a bare status string (0.0 Retry-After).
    See _coerce_probe_response for how each form is normalized."""

    code: str
    retry_after: float = 0.0


@dataclass(frozen=True)
class Candidate:
    """A module path pinned to a version, enumerated from go.mod."""

    path: str
    version: str

    @property
    def spec(self) -> str:
        """The ``path@version`` form used in logs and proxy URLs."""
        return f"{self.path}@{self.version}"


@dataclass(frozen=True)
class ProbeRecord:
    """A probed module version and its (redacted) proxy URL + HTTP status."""

    path: str
    version: str
    commit: str
    url: str  # already redacted for display
    status: str

    @property
    def spec(self) -> str:
        """The ``path@version`` form used in logs."""
        return f"{self.path}@{self.version}"


@dataclass(frozen=True)
class SkippedCandidate:
    """A candidate not probed because a deadline/outage stopped the loop."""

    path: str
    version: str
    reason: str

    @property
    def spec(self) -> str:
        """The ``path@version`` form used in logs."""
        return f"{self.path}@{self.version}"


@dataclass
class _ProbeResults:
    """Accumulated probe outcomes used to render the final summary."""

    missing: list[ProbeRecord] = field(default_factory=list)
    inconclusive: list[ProbeRecord] = field(default_factory=list)
    budget_skipped: list[SkippedCandidate] = field(default_factory=list)
    budget_stop: str = ""  # "deadline" or "outage" once we stop probing early


@dataclass
class _Budget:
    """Overall wall-clock budget for the probe loop. ``deadline`` <= 0 disables it,
    in which case nothing is ever capped or exhausted."""

    deadline: float
    start: float

    def remaining(self) -> float | None:
        """Seconds left, or None when the deadline is disabled."""
        if self.deadline <= 0:
            return None
        return self.deadline - (time.monotonic() - self.start)

    def exhausted(self) -> bool:
        """Whether the budget is enabled and has run out."""
        remaining = self.remaining()
        return remaining is not None and remaining <= 0

    def probe_timeout(self) -> float:
        """Per-probe timeout: the remaining budget, capped to DEFAULT_PROBE_TIMEOUT
        (or just the default when the deadline is disabled)."""
        remaining = self.remaining()
        if remaining is None:
            return DEFAULT_PROBE_TIMEOUT
        return max(0.0, min(DEFAULT_PROBE_TIMEOUT, remaining))

    def cap_sleep(self, delay: float) -> float:
        """Clamp a retry sleep to the remaining budget (unbounded when disabled)."""
        remaining = self.remaining()
        if remaining is None:
            return delay
        return max(0.0, min(delay, remaining))


# --------------------------------------------------------------------------- #
# Remediation helpers                                                          #
# --------------------------------------------------------------------------- #

def die_general() -> None:
    """Print the vendor/go.mod inconsistency remediation and exit 1."""
    print(_GENERAL_REMEDIATION)
    sys.exit(1)


def die_modlist() -> None:
    """Print the ``go list`` failure remediation and exit 1."""
    print(_MODLIST_REMEDIATION)
    sys.exit(1)


def goproxy_report_missing(rbase: str, records: list[ProbeRecord]) -> None:
    """Print the remediation for modules whose pinned pseudo-version is not
    resolvable on the Go module proxy. ``rbase`` is the redacted proxy base URL."""
    print(_MISSING_HEADER)
    print()
    print(f"Go module proxy base URL (redacted): {rbase}")
    print()
    print("Unresolvable module pseudo-version(s):")
    for rec in records:
        print(f"- module:  {rec.path}")
        print(f"  version: {rec.version}")
        print(f"  commit:  {rec.commit}")
        print(f"  proxy:   {rec.url}")
        print(f"  status:  {rec.status}")
    print()
    print(_MISSING_FOOTER)


# --------------------------------------------------------------------------- #
# Go module proxy availability check                                           #
# --------------------------------------------------------------------------- #

def goproxy_escape(value: str) -> str:
    """Escape a module path/version for the proxy: each uppercase ASCII letter
    becomes ``!`` followed by its lowercase form (e.g. ``Azure`` -> ``!azure``)."""
    return "".join(f"!{c.lower()}" if "A" <= c <= "Z" else c for c in value)


def goproxy_redact_url(url: str) -> str:
    """Redact a URL for display only: drop the ENTIRE userinfo (user:pass@, even a
    password that itself contains '@') and the query string / fragment, so
    credentials never reach the logs. The real probe always uses the full,
    unredacted URL. The proxy ``/@v/`` path segment is preserved because urlsplit
    keeps it in the path, not the authority."""
    parts = urlsplit(url)
    netloc = parts.netloc
    if "@" in netloc:
        # Strip everything up to and including the LAST '@' in the authority.
        netloc = netloc.rsplit("@", 1)[1]
    # Drop query and fragment (they may carry tokens) by passing empty strings.
    return urlunsplit((parts.scheme, netloc, parts.path, "", ""))


def _go_class_to_fnmatch(pattern: str) -> str:
    """Translate Go ``path.Match`` bracket-class syntax into the form
    ``fnmatch.fnmatchcase`` expects. Go negates a character class with ``^``
    (``[^abc]``) while fnmatch uses ``!`` (``[!abc]``); only the class-leading
    negation marker differs, so every other construct (ranges, literals, ``*`` and
    ``?``) is passed through unchanged. Scanning for the ``[`` that opens a class
    keeps a ``^`` elsewhere (a literal, or a range member) untouched."""
    result: list[str] = []
    index, length = 0, len(pattern)
    while index < length:
        char = pattern[index]
        result.append(char)
        # A '^' immediately after a class-opening '[' is Go's negation marker.
        if char == "[" and index + 1 < length and pattern[index + 1] == "^":
            result.append("!")
            index += 2
            continue
        index += 1
    return "".join(result)


def _path_match(pattern: str, candidate: str) -> bool:
    """Go ``path.Match`` equivalent: match ``candidate`` against ``pattern``
    element-by-element (``*``, ``?`` and ``[...]`` classes never cross ``/``). Each
    element is translated from Go class syntax (``[^...]``) to fnmatch syntax
    (``[!...]``) before matching so negated classes behave as Go does."""
    pat_parts = pattern.split("/")
    cand_parts = candidate.split("/")
    if len(pat_parts) != len(cand_parts):
        return False
    return all(fnmatch.fnmatchcase(part, _go_class_to_fnmatch(pat))
               for pat, part in zip(pat_parts, cand_parts))


def goproxy_path_is_private(path: str, patterns: list[str]) -> bool:
    """Return whether ``path`` matches any GONOPROXY/GOPRIVATE pattern using Go's
    module-matching semantics: a pattern matches if it matches the whole path or a
    leading prefix at a path-element boundary, where each element is matched with
    ``path.Match`` (supporting ``*``, ``?`` and ``[...]`` without crossing ``/``).
    Plain literal patterns reduce to the previous exact/prefix behavior. A trailing
    slash on a non-empty pattern is stripped first so ``github.com/corp/`` matches
    descendant module paths like ``github.com/corp/foo``."""
    elements = path.split("/")
    prefixes = ["/".join(elements[:i]) for i in range(1, len(elements) + 1)]
    stripped = [pattern.rstrip("/") for pattern in patterns if pattern]
    return any(
        _path_match(pattern, prefix)
        for pattern in stripped if pattern
        for prefix in prefixes
    )


def _parse_retry_after(value: str) -> float:
    """Parse an HTTP ``Retry-After`` header value. Only the integer delay-seconds
    form is honored (returned as a float); the HTTP-date form (and anything else
    unparseable) is treated as absent and returns ``0.0``."""
    text = value.strip()
    return float(text) if text.isdigit() else 0.0


def goproxy_probe_curl(url: str, timeout: float = DEFAULT_PROBE_TIMEOUT) -> ProbeResponse:
    """HEAD-probe ``url`` with curl, returning a ProbeResponse (HTTP status code plus
    any server-advertised Retry-After in seconds; ``000``/0.0 on a transport error or
    timeout). ``-I`` sends a HEAD so no body is downloaded; ``-D -`` dumps the
    response headers to stdout so Retry-After can be read while ``-o /dev/null``
    discards the (empty) body stream. No ``-f`` (so a 404 still reports its code);
    ``-L`` follows redirects so the terminal status is classified rather than a 3xx;
    the ``%{http_code}`` marker carries the final status. ``timeout`` bounds both
    curl's own ``--max-time`` and the subprocess as a hard backstop."""
    try:
        result = subprocess.run(
            ["curl", "-sS", "-o", "/dev/null", "-I", "-L", "--max-redirs", "5",
             "-D", "-", "-w", "\n_HTTP_CODE:%{http_code}\n",
             "--max-time", f"{timeout:.3f}", url],
            capture_output=True, text=True, check=False, timeout=timeout + 5,
        )
    except subprocess.TimeoutExpired:
        return ProbeResponse("000", 0.0)
    except (OSError, subprocess.SubprocessError):
        return ProbeResponse("000", 0.0)
    if result.returncode != 0:
        return ProbeResponse("000", 0.0)
    code = "000"
    retry_after = 0.0
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("_HTTP_CODE:"):
            code = stripped.split(":", 1)[1].strip() or "000"
        elif stripped.lower().startswith("retry-after:"):
            # Keep the last Retry-After seen: the final (post-redirect) response.
            retry_after = _parse_retry_after(stripped.split(":", 1)[1])
    return ProbeResponse(code, retry_after)


def goproxy_probe_wget(url: str, timeout: float = DEFAULT_PROBE_TIMEOUT) -> ProbeResponse:
    """Fallback HEAD-probe using wget, returning a ProbeResponse (HTTP status code
    plus any Retry-After in seconds; ``000``/0.0 on error or timeout).
    ``--server-response --spider`` reads the response headers from stderr without
    downloading a body."""
    try:
        result = subprocess.run(
            ["wget", "--server-response", "--spider",
             f"--timeout={max(1, int(timeout))}", "-t", "1", url],
            capture_output=True, text=True, check=False, timeout=timeout + 5,
        )
    except subprocess.TimeoutExpired:
        return ProbeResponse("000", 0.0)
    except (OSError, subprocess.SubprocessError):
        return ProbeResponse("000", 0.0)
    output = (result.stdout or "") + (result.stderr or "")
    code = "000"
    retry_after = 0.0
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("HTTP/"):
            parts = stripped.split()
            if len(parts) >= 2:
                code = parts[1]  # keep the last HTTP status line
        elif stripped.lower().startswith("retry-after:"):
            retry_after = _parse_retry_after(stripped.split(":", 1)[1])
    return ProbeResponse(code, retry_after)


def go_env(name: str) -> str:
    """Return ``go env <name>`` (empty string if go is unavailable or fails)."""
    try:
        result = subprocess.run(["go", "env", name],
                                capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def candidates_from_json(data: dict) -> list[Candidate]:
    """Enumerate candidates from parsed ``go mod edit -json`` output.

    Replace-aware: emit a Replace's remote target (``New.Version`` non-empty,
    ``New.Path`` not starting with ``.`` or ``/``) only when that replacement is
    active, plus every Require whose version is NOT replaced. A replace with no
    ``Old.Version`` (wildcard) always applies and suppresses the requirement for all
    versions. A replace with an explicit ``Old.Version`` only applies -- and only
    suppresses that exact version -- when Go actually selects that old module+version;
    an inactive versioned replacement is neither probed nor failed. A remote replace's
    target is emitted via its New entry; a local replace emits nothing, so the
    requirement is simply dropped. Returned sorted and de-duplicated by ``spec``
    (matches the original ``sort -u``)."""
    by_spec: dict[str, Candidate] = {}

    # The module+version pairs the main module directly requires. 'go mod edit -json'
    # exposes only the main module's own require/replace directives, not the fully
    # resolved build graph, so this is the best available signal for whether a
    # version-specific replace is active (see the activity rule below).
    required = {
        (req.get("Path") or "", req.get("Version") or "")
        for req in data.get("Require") or []
        if req.get("Path")
    }

    wildcard_replaced: set[str] = set()      # Old.Path with no version -> all versions
    versioned_replaced: set[tuple[str, str]] = set()  # (Old.Path, Old.Version)
    for replace in data.get("Replace") or []:
        old = replace.get("Old") or {}
        old_path = old.get("Path") or ""
        if not old_path:
            continue
        old_version = old.get("Version") or ""
        if old_version:
            versioned_replaced.add((old_path, old_version))
            # Activity rule: a version-specific replacement is inert unless Go
            # actually selects that exact old module+version. We approximate "Go
            # selects it" by its presence in the main module's require set. This
            # cannot prove the full module graph -- a version pulled in only
            # transitively will look inactive -- so we accept that false negative
            # rather than probe (and possibly fail on) a replace Go never applies.
            active = (old_path, old_version) in required
        else:
            wildcard_replaced.add(old_path)
            active = True  # wildcard/versionless replacements always apply

        if not active:
            continue
        new = replace.get("New") or {}
        new_path = new.get("Path") or ""
        new_version = new.get("Version") or ""
        if new_version and not new_path.startswith((".", "/")):
            cand = Candidate(new_path, new_version)
            by_spec[cand.spec] = cand

    for require in data.get("Require") or []:
        path = require.get("Path") or ""
        version = require.get("Version") or ""
        if not path:
            continue
        if path in wildcard_replaced or (path, version) in versioned_replaced:
            continue
        cand = Candidate(path, version)
        by_spec[cand.spec] = cand

    return [by_spec[spec] for spec in sorted(by_spec)]


def enumerate_candidates() -> list[Candidate]:
    """Run ``go mod edit -json`` (offline) and return the candidate list."""
    try:
        result = subprocess.run(["go", "mod", "edit", "-json"],
                                capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return []
    if result.returncode != 0 or not result.stdout.strip():
        return []
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return []
    return candidates_from_json(data)


def _resolve_proxy_base() -> str:
    """Return the proxy base URL: the first http(s) entry of ``go env GOPROXY``
    (skipping ``direct``/``off``), else the public proxy. Any trailing slash is
    stripped.

    GOPROXY_AVAILABILITY_URL is read here as an UNDECLARED, test-only override hook
    (like GOPROXY_PROBE_CMD / GOPROXY_SELF_TEST): it lets the self-test and unit
    tests point the probe at a fake proxy. It is intentionally NOT exposed as
    consumer configuration in the step ref."""
    base = os.environ.get("GOPROXY_AVAILABILITY_URL", "")  # test-only hook, not consumer config
    if not base:
        entries = re.split(r"[,|]", go_env("GOPROXY"))
        base = next((e for e in entries if e.startswith(("http://", "https://"))), DEFAULT_PROXY)
    return base.rstrip("/")


def probe_cmd(cmd: str, url: str, timeout: float) -> str:
    """Run an external GOPROXY_PROBE_CMD probe, returning its stdout status code (or
    ``000`` on error/timeout — a stalled custom probe is killed and counts as a
    transport failure)."""
    try:
        result = subprocess.run([cmd, url], capture_output=True, text=True,
                                check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "000"
    except (OSError, subprocess.SubprocessError):
        return "000"
    return result.stdout.strip() or "000"


def _invoke_override(override, url: str, timeout: float):
    """Call the PROBE_OVERRIDE hook, dispatching by arity: the common test form
    accepts just ``(url)``; a two-parameter form additionally receives the
    per-attempt ``timeout`` so tests can assert it is capped to the budget."""
    try:
        arity = len(inspect.signature(override).parameters)
    except (TypeError, ValueError):
        arity = 1
    return override(url, timeout) if arity >= 2 else override(url)


def _select_probe():
    """Return a callable(url, timeout) -> status-code / ProbeResponse, or None if no
    probe is available. Priority: the PROBE_OVERRIDE hook (a Python callable(url) or
    (url, timeout)), then a GOPROXY_PROBE_CMD external command, then curl, then
    wget."""
    if PROBE_OVERRIDE is not None:
        override = PROBE_OVERRIDE
        return lambda url, timeout: _invoke_override(override, url, timeout)
    cmd = os.environ.get("GOPROXY_PROBE_CMD", "")
    if cmd:
        return lambda url, timeout: probe_cmd(cmd, url, timeout)
    if shutil.which("curl"):
        return goproxy_probe_curl
    if shutil.which("wget"):
        return goproxy_probe_wget
    return None


def _coerce_probe_response(value) -> ProbeResponse:
    """Normalize a probe's return value into a ProbeResponse. The curl and wget
    backends already return a ProbeResponse (status code plus any Retry-After parsed
    from the response headers); the external GOPROXY_PROBE_CMD returns a bare status
    string (no Retry-After); and the PROBE_OVERRIDE hook may return a ProbeResponse,
    a (code, retry_after) tuple, or a bare status string so tests can exercise
    Retry-After handling through the injected path."""
    if isinstance(value, ProbeResponse):
        return value
    if isinstance(value, tuple):
        code, retry_after = value
        return ProbeResponse(str(code), float(retry_after))
    return ProbeResponse(str(value), 0.0)


def _apply_jitter(delay: float) -> float:
    """Apply bounded +/-JITTER_FRACTION jitter to a backoff delay using the
    module-level RNG (seed ``JITTER_RNG`` in tests for determinism). A non-positive delay
    stays zero."""
    if delay <= 0:
        return 0.0
    return delay * (1.0 + JITTER_RNG.uniform(-JITTER_FRACTION, JITTER_FRACTION))


def _next_backoff(retry_delay: int, attempt: int, code: str, retry_after: float) -> float:
    """Compute the delay before the next probe attempt: the base backoff
    (``retry_delay * attempt``) with bounded jitter, raised to at least the
    server-advertised Retry-After on HTTP 429. The caller still caps the result to
    the remaining deadline budget."""
    base = _apply_jitter(retry_delay * attempt)
    if code == "429" and retry_after > 0:
        return max(base, retry_after)
    return base


def _probe_with_retries(probe, url: str, retries: int, retry_delay: int,
                        budget: _Budget) -> tuple[Outcome, str]:
    """Probe ``url`` up to ``retries`` times with increasing backoff, honoring the
    overall ``budget``: each probe timeout and each retry sleep are capped to the
    remaining budget, and retries stop once it is exhausted.

    Returns ``(outcome, last_code)`` where a ``200`` yields AVAILABLE immediately,
    a trailing ``404``/``410`` yields MISSING, and anything else (``000`` network /
    5xx / 429 / timeout) yields INCONCLUSIVE. Each attempt's timeout is capped to the
    remaining budget; the inter-attempt backoff carries bounded jitter and honors a
    429 Retry-After."""
    last = Outcome.INCONCLUSIVE
    code = "000"
    for attempt in range(1, retries + 1):
        if budget.exhausted():
            break
        try:
            response = _coerce_probe_response(probe(url, budget.probe_timeout()))
        except Exception:  # pylint: disable=broad-exception-caught  # any prober error -> transport failure
            response = ProbeResponse("000", 0.0)
        code = response.code
        if code == "200":
            return Outcome.AVAILABLE, code
        last = Outcome.MISSING if code in ("404", "410") else Outcome.INCONCLUSIVE
        if attempt < retries:
            delay = budget.cap_sleep(_next_backoff(retry_delay, attempt, code, response.retry_after))
            if delay > 0:
                time.sleep(delay)
            if budget.exhausted():
                break
    return last, code


def _report_goproxy_outcome(rproxy_base: str, results: _ProbeResults) -> None:
    """Print the outcome summary and exit 1 only on a hard failure (a module the
    proxy definitively does not have). Inconclusive (transient/non-404) results and
    budget/outage skips are treated as warnings and never fail the check."""
    if results.missing:
        goproxy_report_missing(rproxy_base, results.missing)
        sys.exit(1)

    if results.inconclusive:
        print(f"WARNING: could not conclusively verify {len(results.inconclusive)} module version(s) "
              "on the Go module proxy (transient/non-404 responses):")
        for rec in results.inconclusive:
            print(f"  - {rec.spec} ({rec.status}) {rec.url}")

    if results.budget_skipped:
        print(f"WARNING: stopped probing {len(results.budget_skipped)} module version(s) early "
              f"({results.budget_stop}); treated as inconclusive and NOT failing the check:")
        for skip in results.budget_skipped:
            print(f"  - {skip.spec} ({skip.reason})")

    if results.inconclusive or results.budget_skipped:
        print("Continuing (inconclusive results are treated as warnings and do not fail the check; "
              "only modules the proxy definitively cannot resolve fail, and budget/outage skips never fail).")
        return

    print("All checked Go module versions are resolvable on the Go module proxy.")


# The proxy endpoints a candidate must resolve, probed in order. The ART/Konflux
# hermeto prefetch fetches BOTH the ``.info`` (metadata) and the ``.zip`` (module
# source): a 200 on ``.info`` alone does NOT prove the ``.zip`` is served, so we
# confirm the ``.zip`` too and only report OK when every required endpoint resolves.
# This is the "probe the .zip endpoint" remediation (preferred over merely narrowing
# the docstring): it actually prevents the opaque prefetch 404 the message promises
# to catch. A 404/410 on ``.zip`` fails like a missing module; a transient failure
# on ``.zip`` is lenient like everywhere else; both share the retry/deadline budget.
_REQUIRED_PROXY_SUFFIXES = (".info", ".zip")


def _probe_candidate_endpoints(probe, proxy_base: str, cand: Candidate,
                               budget: _Budget) -> tuple[Outcome, str, str]:
    """Probe the required proxy endpoints for ``cand`` in order (``.info`` then
    ``.zip``), short-circuiting on the first non-AVAILABLE outcome. Returns
    ``(outcome, last_code, redacted_url)`` for the endpoint that determined the
    result: AVAILABLE only when every required endpoint resolves, MISSING on the
    first 404/410, INCONCLUSIVE on the first transient failure. Per-endpoint retries
    and backoff come from the module tuning constants (``GOPROXY_RETRIES`` /
    ``GOPROXY_RETRY_DELAY_SECONDS``, read live so tests can monkeypatch them); the
    overall deadline ``budget`` is shared across the endpoints."""
    base = f"{proxy_base}/{goproxy_escape(cand.path)}/@v/{goproxy_escape(cand.version)}"
    outcome = Outcome.AVAILABLE
    code = "000"
    rurl = ""
    for suffix in _REQUIRED_PROXY_SUFFIXES:
        url = base + suffix
        rurl = goproxy_redact_url(url)
        outcome, code = _probe_with_retries(
            probe, url, GOPROXY_RETRIES, GOPROXY_RETRY_DELAY_SECONDS, budget)
        if outcome is not Outcome.AVAILABLE:
            break
    return outcome, code, rurl


def check_goproxy_availability() -> None:
    """Verify pinned Go module pseudo-versions resolve on the Go module proxy
    before a build (ART-26147). Opt-in via CHECK_GOPROXY_AVAILABILITY. Raises
    ``SystemExit(1)`` only on a hard failure (a module the proxy definitively does
    not have); inconclusive/transient results are treated as warnings."""
    # Opt-in default-off: the ref default is "false", so an unset var must NOT
    # enable the check (ci-operator always sets it from the ref; this fallback
    # only guards bare/local invocations).
    if not Path("go.mod").is_file() or os.environ.get("CHECK_GOPROXY_AVAILABILITY", "false") != "true":
        return

    # Retry/backoff/deadline are fixed internals (module constants), no longer env
    # tunables. The deadline bounds the whole probe loop here; the per-endpoint
    # retries/backoff are read live inside _probe_candidate_endpoints. All are read
    # via module globals so tests can monkeypatch them.
    deadline = GOPROXY_DEADLINE_SECONDS

    print("Checking that pinned Go module versions are resolvable on the Go module proxy (ART-26147).")

    proxy_base = _resolve_proxy_base()
    rproxy_base = goproxy_redact_url(proxy_base)  # never log embedded credentials
    print(f"Using Go module proxy base URL: {rproxy_base}")

    probe = _select_probe()
    if probe is None:
        print("WARNING: neither 'curl' nor 'wget' is available; skipping Go module proxy availability check.")
        return

    candidates = enumerate_candidates()
    if not candidates:
        print("No module versions found to check; skipping Go module proxy availability check.")
        return

    # Private modules (GONOPROXY, defaulting to GOPRIVATE) are not served by the
    # public proxy, so they are never probed or failed.
    nopriv = go_env("GONOPROXY") or go_env("GOPRIVATE")
    priv_patterns = nopriv.split(",") if nopriv else []

    results = _ProbeResults()
    private_skipped: list[str] = []
    consecutive_000 = 0
    budget = _Budget(deadline, time.monotonic())

    for cand in candidates:
        # Only pseudo-versions are probed: a pinned commit with no nearby semver tag
        # is what the proxy cannot serve. Tagged versions are left to the build.
        if not PSEUDO_RE.search(cand.version):
            continue
        if priv_patterns and goproxy_path_is_private(cand.path, priv_patterns):
            private_skipped.append(cand.path)
            continue

        if not results.budget_stop and budget.exhausted():
            results.budget_stop = "deadline"
        if results.budget_stop:
            print(f"  INCONCLUSIVE {cand.spec} (skipped: {results.budget_stop})")
            results.budget_skipped.append(SkippedCandidate(cand.path, cand.version, results.budget_stop))
            continue

        commit = cand.version.rsplit("-", 1)[-1].removesuffix("+incompatible")

        outcome, code, rurl = _probe_candidate_endpoints(
            probe, proxy_base, cand, budget)
        consecutive_000 = consecutive_000 + 1 if code == "000" else 0

        if outcome is Outcome.AVAILABLE:
            print(f"  OK           {cand.spec} ({code})")
        elif outcome is Outcome.MISSING:
            print(f"  MISSING      {cand.spec} ({code}) {rurl}")
            results.missing.append(ProbeRecord(cand.path, cand.version, commit, rurl, code))
        else:
            print(f"  INCONCLUSIVE {cand.spec} ({code}) {rurl}")
            results.inconclusive.append(ProbeRecord(cand.path, cand.version, commit, rurl, code))

        if consecutive_000 >= OUTAGE_THRESHOLD:
            results.budget_stop = "outage"

    if private_skipped:
        listed = "".join(f"{path} " for path in sorted(set(private_skipped)))
        print(f"Skipping private module(s) matched by GONOPROXY/GOPRIVATE: {listed}")

    _report_goproxy_outcome(rproxy_base, results)


# --------------------------------------------------------------------------- #
# Embedded self-test (cases A-D); runs only on --self-test / GOPROXY_SELF_TEST  #
# --------------------------------------------------------------------------- #

_SELF_TEST_GOMOD = """\
// Fixture derived from github.com/openshift/origin release-5.0 (commit 4608138db381).
// It reproduces the pinned openshift/kubernetes pseudo-versions that were not
// resolvable on the Go module proxy, causing ART/Konflux hermeto prefetch to 404.
module github.com/openshift/origin

go 1.22.0

require (
\tgithub.com/stretchr/testify v1.11.1
\tgithub.com/example/benign v0.0.0-20240229000000-abcdef123456
)

replace (
\tk8s.io/api => github.com/openshift/kubernetes/staging/src/k8s.io/api v0.0.0-20261110024958-4608138db381
\tk8s.io/apimachinery => github.com/openshift/kubernetes/staging/src/k8s.io/apimachinery v0.0.0-20261110024958-4608138db381
\tk8s.io/apiserver => github.com/openshift/kubernetes/staging/src/k8s.io/apiserver v0.0.0-20261110024958-4608138db381
\tk8s.io/client-go => github.com/openshift/kubernetes/staging/src/k8s.io/client-go v0.0.0-20261110024958-4608138db381
\tk8s.io/kubernetes => github.com/openshift/kubernetes v1.37.0-alpha.0.0.20261110024958-4608138db381
)
"""


def _self_test_probe_404(url: str) -> str:
    """Mock probe: 404 for the failing commit, 200 otherwise."""
    return "404" if "20261110024958-4608138db381" in url else "200"


def _self_test_probe_200(_url: str) -> str:
    """Mock probe: everything is available."""
    return "200"


def _capture_check() -> tuple[str, int]:
    """Run check_goproxy_availability() capturing combined output and exit code."""
    buf = io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            check_goproxy_availability()
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 1
    return buf.getvalue(), rc


def run_self_test() -> bool:  # pylint: disable=too-many-statements  # four self-test cases inline
    """Reproduce cases A-D from the original self-test. Returns True on pass."""
    # pylint: disable=global-statement  # the probe hook / tuning are module globals
    global PROBE_OVERRIDE, GOPROXY_RETRIES, GOPROXY_RETRY_DELAY_SECONDS
    failures: list[str] = []
    origdir = Path.cwd()
    tmpdir = Path(tempfile.mkdtemp())

    # Force the master switch ON for every case: the production default is "false"
    # (opt-in), but the self-test must exercise the check regardless.
    os.environ["CHECK_GOPROXY_AVAILABILITY"] = "true"
    os.environ.pop("GONOPROXY", None)
    os.environ.pop("GOPRIVATE", None)

    # Keep the self-test instant: a couple of attempts with no backoff sleeps.
    orig_retries, orig_delay = GOPROXY_RETRIES, GOPROXY_RETRY_DELAY_SECONDS
    GOPROXY_RETRIES, GOPROXY_RETRY_DELAY_SECONDS = 2, 0

    # Isolate the self-test's `go env` reads from the developer's persisted Go env
    # file: a saved `go env -w GOPRIVATE=...`/`GONOPROXY=...` would otherwise make
    # Case A treat its fixture pins as private and skip them, masking the failure.
    # Point GOENV at an empty file so only explicit env vars (e.g. Case D's
    # GONOPROXY) take effect. The caller's GOENV is restored in the finally block.
    orig_goenv = os.environ.get("GOENV")

    try:
        (tmpdir / "go.mod").write_text(_SELF_TEST_GOMOD, encoding="utf-8")
        empty_goenv = tmpdir / "goenv.empty"
        empty_goenv.write_text("", encoding="utf-8")
        os.environ["GOENV"] = str(empty_goenv)
        os.chdir(tmpdir)

        print("=== Self-test case A: a missing pseudo-version must fail with remediation ===")
        os.environ["GOPROXY_AVAILABILITY_URL"] = "https://proxy.example.test"
        PROBE_OVERRIDE = _self_test_probe_404
        out, rc = _capture_check()
        print(out)
        if rc == 0:
            failures.append("case A expected a non-zero exit, got 0")
        if "github.com/openshift/kubernetes" not in out:
            failures.append("case A output is missing 'github.com/openshift/kubernetes'")
        # The exact dot-separated headline pin must be reported.
        if "github.com/openshift/kubernetes v1.37.0-alpha.0.0.20261110024958-4608138db381" not in out.replace("@", " "):
            failures.append("case A did not report the headline pin "
                            "github.com/openshift/kubernetes v1.37.0-alpha.0.0.20261110024958-4608138db381")
        if "go get" not in out:
            failures.append("case A output is missing the 'go get' remediation guidance")
        if not re.search(r"\btag\b", out):
            failures.append("case A output is missing the 'tag' remediation keyword")

        print("\n=== Self-test case B: all versions available must pass ===")
        PROBE_OVERRIDE = _self_test_probe_200
        out, rc = _capture_check()
        print(out)
        if rc != 0:
            failures.append(f"case B expected exit 0, got {rc}")

        print("\n=== Self-test case C: credentials in the proxy URL must never be logged ===")
        os.environ["GOPROXY_AVAILABILITY_URL"] = "https://user:s3cr3t@proxy.example.test"
        PROBE_OVERRIDE = _self_test_probe_404
        out, rc = _capture_check()
        print(out)
        if "s3cr3t" in out:
            failures.append("case C leaked the credential 's3cr3t' into the output")

        print("\n=== Self-test case D: a private module must be skipped, not probed ===")
        os.environ["GOPROXY_AVAILABILITY_URL"] = "https://proxy.example.test"
        PROBE_OVERRIDE = _self_test_probe_200
        os.environ["GONOPROXY"] = "github.com/example/benign"
        out, rc = _capture_check()
        print(out)
        if not re.search(r"Skipping private module\(s\) matched by GONOPROXY/GOPRIVATE:.*github.com/example/benign", out):
            failures.append("case D did not report github.com/example/benign as a skipped private module")
        if "github.com/example/benign@" in out:
            failures.append("case D probed github.com/example/benign instead of skipping it")
        if rc != 0:
            failures.append(f"case D expected exit 0, got {rc}")
        os.environ.pop("GONOPROXY", None)
    finally:
        PROBE_OVERRIDE = None
        GOPROXY_RETRIES, GOPROXY_RETRY_DELAY_SECONDS = orig_retries, orig_delay
        if orig_goenv is None:
            os.environ.pop("GOENV", None)
        else:
            os.environ["GOENV"] = orig_goenv
        os.chdir(origdir)
        shutil.rmtree(tmpdir, ignore_errors=True)

    print()
    for message in failures:
        print(f"FAIL: {message}")
    if failures:
        print("SELF-TEST FAILED")
        return False
    print("SELF-TEST PASSED")
    return True


# --------------------------------------------------------------------------- #
# Vendor-consistency flow + entrypoint                                         #
# --------------------------------------------------------------------------- #

def _go_directive_needs_patch(gomod_text: str) -> bool:
    """Return whether a ``go`` directive gives only major.minor (no patch) with a
    minor > 21 (hermeto requires a patch version for go1.22+)."""
    for line in gomod_text.splitlines():
        if line.startswith("go "):
            fields = re.split(r"[ .]+", line.strip())
            if len(fields) < 4:
                try:
                    if int(fields[2]) > 21:
                        return True
                except (IndexError, ValueError):
                    continue
    return False


def _run(cmd: list[str]) -> int:
    """Run ``cmd`` inheriting stdio and return its exit code."""
    return subprocess.run(cmd, check=False).returncode


def _verify_vendor() -> int:  # pylint: disable=too-many-return-statements  # fail-fast: each external step returns its own exit code
    """Run the original vendor/go.mod consistency flow. Returns an exit code."""
    gomod_path = Path("go.mod")
    if not gomod_path.is_file() or not Path("vendor").is_dir():
        print(f"No go.mod vendoring detected in {Path.cwd()}; skipping dependency checks.")
        return 0
    print(f"Detected go.mod in {Path.cwd()}; verifying vendored dependencies.")

    bad = [line for line in gomod_path.read_text(encoding="utf-8").splitlines()
           if re.search(r"github.com/openshift/(api|client-go) v3\.9\.0\+incompatible", line)]
    if bad:
        for line in bad:
            print(line)
        print(_INCOMPATIBLE_V39_MESSAGE)
        return 1

    print_rc = _run(["go", "version"])  # for debugging
    if print_rc != 0:
        return print_rc

    if os.environ.get("CHECK_MOD_LIST", "true") == "true":
        print("Checking that all modules can be resolved offline")
        if _run(["go", "list", "-mod=readonly", "-m", "all"]) != 0:
            die_modlist()
    else:
        print("Skipping go mod list check")

    compat = os.environ.get("COMPAT", "")  # explicit -compat argument for go mod tidy
    print("Checking that vendor/ is correct")
    print(f"Running: go mod tidy {compat}")
    rc = _run(["go", "mod", "tidy", *compat.split()])
    if rc != 0:
        return rc

    vendor_mode = "mod"
    if Path("go.work").is_file() and os.environ.get("GOWORK", "") != "off":
        print('Detected go workspace; using "go work vendor".')
        vendor_mode = "work"
    print(f"Running: go {vendor_mode} vendor")
    rc = _run(["go", vendor_mode, "vendor"])
    if rc != 0:
        return rc

    # "--ignored" ensures .gitignore is NOT honored during the comparison.
    status = subprocess.run(["git", "status", "--porcelain", "--ignored"],
                            capture_output=True, text=True, check=False)
    if status.returncode != 0:
        # Match the shell `set -o errexit`: a failing git status fails the step
        # rather than being treated as "no changes".
        sys.stderr.write(status.stderr or "")
        print(f"ERROR: 'git status --porcelain --ignored' failed with exit code {status.returncode}.")
        return status.returncode
    changes = status.stdout.strip("\n")
    if changes:
        print(f"ERROR: detected vendor inconsistency after 'go mod tidy {compat}; go {vendor_mode} vendor':")
        print(changes)
        die_general()

    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point: run the embedded self-test or the full verify-deps flow."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true",
                        help="run the embedded self-test (cases A-D) and exit")
    args = parser.parse_args(argv)

    if args.self_test or os.environ.get("GOPROXY_SELF_TEST") == "1":
        return 0 if run_self_test() else 1

    gomod_path = Path("go.mod")
    if gomod_path.is_file() and _go_directive_needs_patch(gomod_path.read_text(encoding="utf-8")):
        # Hermeto fails if the go directive does not have a patch version.
        print("Error: 'go' directive in go.mod must include a patch version (e.g. go 1.22.0) for go1.22+")
        return 1

    # Verify pinned pseudo-versions resolve on the proxy before the vendor check.
    check_goproxy_availability()

    return _verify_vendor()


if __name__ == "__main__":
    sys.exit(main())
