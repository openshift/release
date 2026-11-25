"""PR changed files from Prow's JOB_SPEC and the GitHub pull request files API.

The step image needs no Git history: the job's refs name the repository and
pull request heads Prow tested, and GitHub lists each pull request's files.
The API client takes an injectable opener so tests never touch the network.
"""

from dataclasses import dataclass
import http.client
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from .eval_plan import EvalError
except ImportError:
    from eval_plan import EvalError


API_URL = "https://api.github.com"
PER_PAGE = 100  # The maximum page size of the pull request files endpoint.
# GET /repos/{owner}/{repo}/pulls/{number}/files "includes a maximum of 3000 files":
# https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files
FILE_LIST_CAP = 3000
REQUEST_TIMEOUT = 30
MAX_ATTEMPTS = 4
MAX_RETRY_WAIT = 120  # Never sleep longer than this for one retry.
SELECTION_TIMEOUT = 600
JOB_TYPES = ("presubmit", "batch")
OWNER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?")
REPOSITORY = re.compile(r"[A-Za-z0-9._-]{1,100}")
SHA = re.compile(r"[0-9a-fA-F]{40}")
NEXT_LINK = re.compile(r'<([^>]+)>\s*;\s*rel="?next"?')


@dataclass(frozen=True)
class Pull:
    number: int
    sha: str


@dataclass(frozen=True)
class ChangeTarget:
    """The repository checked out for the job and the pull requests merged into it."""

    org: str
    repo: str
    base_ref: str
    pulls: tuple
    job_refs: str  # org/repo#number of JOB_SPEC refs, for diagnostics.
    from_extra_refs: bool

    @property
    def name(self):
        return f"{self.org}/{self.repo}"


def _refs_label(refs):
    pulls = refs.get("pulls") if isinstance(refs.get("pulls"), list) else []
    numbers = ",".join(f"#{pull.get('number')}" for pull in pulls if isinstance(pull, dict))
    return f"{refs.get('org')}/{refs.get('repo')}{numbers}"


def _pulls(refs, label):
    pulls = refs.get("pulls", [])
    if pulls is None:
        pulls = []
    if not isinstance(pulls, list):
        raise EvalError(f"JOB_SPEC {label}.pulls must be a list")
    parsed = []
    for index, pull in enumerate(pulls):
        field = f"JOB_SPEC {label}.pulls[{index}]"
        if not isinstance(pull, dict):
            raise EvalError(f"{field} must be a mapping")
        number, sha = pull.get("number"), pull.get("sha")
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise EvalError(f"{field}.number must be a positive integer: {number!r}")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            raise EvalError(f"{field}.sha must be the 40-character commit SHA Prow tested: {sha!r}")
        parsed.append(Pull(number, sha.lower()))
    return tuple(parsed)


def parse_job_spec(raw, job_type):
    """Return the repository and pull requests whose changes select evals.

    The target is the ref checked out as the working directory, as Prow
    decides it: the first ref with workdir: true, otherwise refs. A pj-rehearse
    rehearsal of a consumer job has refs naming the openshift/release PR and
    the consumer as a workdir extra_ref without pulls; it has no PR diff for
    the consumer, and the openshift/release PR's files are never used.
    """
    if job_type not in JOB_TYPES:
        raise EvalError(f"changed-file selection supports JOB_TYPE {' or '.join(JOB_TYPES)}, not {job_type!r}")
    if not isinstance(raw, str) or not raw.strip():
        raise EvalError("changed-file selection requires Prow's JOB_SPEC environment variable")
    try:
        spec = json.loads(raw)
    except ValueError as error:
        raise EvalError(f"JOB_SPEC is not valid JSON: {error}") from error
    if not isinstance(spec, dict):
        raise EvalError("JOB_SPEC must be a JSON object")
    if spec.get("type") != job_type:
        raise EvalError(f"JOB_SPEC type {spec.get('type')!r} does not match JOB_TYPE {job_type!r}")
    refs, extra_refs = spec.get("refs"), spec.get("extra_refs")
    extra_refs = [] if extra_refs is None else extra_refs
    if not isinstance(refs, dict):
        raise EvalError(f"JOB_SPEC of a {job_type} job must contain refs")
    if not isinstance(extra_refs, list) or not all(isinstance(ref, dict) for ref in extra_refs):
        raise EvalError("JOB_SPEC extra_refs must be a list of mappings")
    labels = ["refs", *(f"extra_refs[{index}]" for index in range(len(extra_refs)))]
    index = next((i for i, ref in enumerate([refs, *extra_refs]) if ref.get("workdir") is True), 0)
    target, label = [refs, *extra_refs][index], labels[index]
    org, repo = target.get("org"), target.get("repo")
    if not isinstance(org, str) or not OWNER.fullmatch(org):
        raise EvalError(f"JOB_SPEC {label}.org is not a GitHub owner name: {org!r}")
    if not isinstance(repo, str) or not REPOSITORY.fullmatch(repo) or repo in (".", ".."):
        raise EvalError(f"JOB_SPEC {label}.repo is not a GitHub repository name: {repo!r}")
    pulls = _pulls(target, label)
    if index == 0:  # Prow's own refs: a presubmit has one pull, a batch at least one.
        if job_type == "presubmit" and len(pulls) != 1:
            raise EvalError(f"JOB_SPEC refs of a presubmit job must contain exactly one pull, found {len(pulls)}")
        if job_type == "batch" and not pulls:
            raise EvalError("JOB_SPEC refs of a batch job must contain at least one pull")
    base_ref = target.get("base_ref") if isinstance(target.get("base_ref"), str) else ""
    return ChangeTarget(org, repo, base_ref, pulls, _refs_label(refs), index != 0)


def seconds_after(value, since):
    """Seconds from since until the numeric header value; one minute if unusable."""
    try:
        return max(0.0, float(value) - since)
    except (TypeError, ValueError):
        return 60.0


def safe_origin(parts):
    """Name a URL in diagnostics by scheme and host only.

    Userinfo, path, query, and fragment can carry credentials or tokens, so
    a rejected URL is never logged raw.
    """
    try:
        port = f":{parts.port}" if parts.port is not None else ""
    except ValueError:
        port = ":<invalid port>"
    return f"{parts.scheme or '<no scheme>'}://{parts.hostname or '<unknown host>'}{port}"


class SameOriginRedirects(urllib.request.HTTPRedirectHandler):
    """Follow redirects only within the API origin, so the token never leaves it.

    urllib copies request headers, including Authorization, to the redirect
    target. A redirect to another host, or from HTTPS to HTTP, is refused
    before any request is sent to it.
    """

    def __init__(self, origin):
        super().__init__()
        self.origin = origin

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # pylint: disable=too-many-arguments,too-many-positional-arguments
        target = urllib.parse.urlsplit(urllib.parse.urljoin(req.full_url, newurl))
        if (target.scheme, target.netloc) != (self.origin.scheme, self.origin.netloc):
            fp.close()
            raise EvalError(f"GitHub API redirected (HTTP {code}) to {safe_origin(target)}; refusing to send "
                            f"credentials outside {safe_origin(self.origin)}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def next_link(header):
    match = NEXT_LINK.search(header or "")
    return match.group(1) if match else None


class GitHubAPI:  # pylint: disable=too-many-instance-attributes
    """A minimal GitHub REST client: JSON GETs, bounded retries, and pagination."""

    def __init__(self, token="", *, base_url=API_URL, opener=None, sleep=time.sleep,  # pylint: disable=too-many-arguments
                 clock=time.monotonic, now=time.time, deadline=None):
        self.token = token
        self.base_url = base_url.rstrip("/")
        self.opener = opener
        self.sleep, self.clock, self.now = sleep, clock, now
        self.deadline = deadline if deadline is not None else clock() + SELECTION_TIMEOUT

    @classmethod
    def from_env(cls, env):
        """Authenticate with the step's mounted token file when present."""
        token = ""
        path = env.get("GITHUB_TOKEN_PATH")
        if path:
            try:
                with open(path, encoding="utf-8") as stream:
                    token = stream.read().strip()
            except FileNotFoundError:
                token = ""
            except OSError as error:
                raise EvalError(f"cannot read the GitHub token at GITHUB_TOKEN_PATH: {type(error).__name__}") from error
        if not token:
            print("WARNING: no GitHub token at GITHUB_TOKEN_PATH; the pull request API is used "
                  "unauthenticated (public repositories only, low shared rate limit).", flush=True)
        return cls(token)

    def headers(self):
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                   "User-Agent": "openshift-release-manifest-eval-runner"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def url(self, path, params=None):
        query = f"?{urllib.parse.urlencode(params)}" if params else ""
        return f"{self.base_url}{path}{query}"

    def same_origin(self, url):
        mine, theirs = urllib.parse.urlsplit(self.base_url), urllib.parse.urlsplit(url)
        return (mine.scheme, mine.netloc) == (theirs.scheme, theirs.netloc)

    def retry_wait(self, error, attempt):
        """Seconds to wait before retrying an HTTP error, or None not to retry.

        Follows https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api.
        """
        headers = error.headers if error.headers is not None else {}
        if error.code in (500, 502, 503, 504):
            wait = 2.0 ** attempt
        elif error.code not in (403, 429):
            wait = None
        elif headers.get("retry-after") is not None:
            wait = seconds_after(headers.get("retry-after"), 0.0)
        elif headers.get("x-ratelimit-remaining") == "0":
            wait = seconds_after(headers.get("x-ratelimit-reset"), self.now()) + 1
        elif error.code == 429 or "rate limit" in getattr(error, "github_message", "").lower():
            # A 429 is always a rate limit; a 403 only when GitHub says so. Without
            # headers, GitHub says to wait at least a minute, backing off exponentially.
            wait = 60.0 * 2 ** (attempt - 1)
        else:
            wait = None
        return wait

    def describe(self, error, url):
        path = urllib.parse.urlsplit(url).path
        detail = getattr(error, "github_message", "")
        detail = f": {detail}" if detail else ""
        if error.code == 404:
            return (f"GitHub API {path} returned HTTP 404{detail}. GitHub answers 404 for a private repository "
                    "the caller cannot read: ensure the token at GITHUB_TOKEN_PATH can read this repository's "
                    "pull requests (a failed lookup is not a no-op)")
        if error.code == 401:
            return (f"GitHub API {path} rejected the token from GITHUB_TOKEN_PATH (HTTP 401){detail}; "
                    "a failed lookup is not a no-op")
        return f"GitHub API {path} failed with HTTP {error.code}{detail}"

    def wait_or_fail(self, wait, attempt, message):
        if wait is None:
            raise EvalError(message)
        if attempt >= MAX_ATTEMPTS:
            raise EvalError(f"{message} (gave up after {attempt} attempts)")
        if wait > MAX_RETRY_WAIT or self.clock() + wait > self.deadline:
            raise EvalError(f"{message} (retry would wait {wait:.0f} seconds, beyond the selection time limit)")
        print(f"WARNING: {message}; retrying in {wait:.0f} seconds ({attempt}/{MAX_ATTEMPTS})", flush=True)
        self.sleep(wait)

    def default_open(self, request, timeout):
        """Open with urllib, following redirects only within the API origin."""
        director = urllib.request.build_opener(SameOriginRedirects(urllib.parse.urlsplit(self.base_url)))
        return director.open(request, timeout=timeout)

    def get_url(self, url):
        """GET one JSON document; return it with the response headers."""
        opener = self.opener or self.default_open
        for attempt in range(1, MAX_ATTEMPTS + 1):
            timeout = max(1.0, min(REQUEST_TIMEOUT, self.deadline - self.clock()))
            request = urllib.request.Request(url, headers=self.headers())
            try:
                with opener(request, timeout=timeout) as response:
                    body = response.read()
                    headers = response.headers
            except urllib.error.HTTPError as error:
                try:
                    message = json.loads(error.read() or b"{}").get("message", "")
                except (ValueError, AttributeError, OSError, http.client.HTTPException):
                    message = ""
                error.github_message = message if isinstance(message, str) else ""
                self.wait_or_fail(self.retry_wait(error, attempt), attempt, self.describe(error, url))
                continue
            except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
                # HTTPException covers a body cut short (IncompleteRead): retry, then fail closed.
                path = urllib.parse.urlsplit(url).path
                self.wait_or_fail(2.0 ** attempt, attempt,
                                  f"GitHub API {path} request failed: {type(error).__name__}: {error}")
                continue
            try:
                return json.loads(body), headers
            except ValueError as error:
                raise EvalError(f"GitHub API {urllib.parse.urlsplit(url).path} returned invalid JSON") from error
        raise AssertionError("unreachable")  # pragma: no cover

    def get(self, path, params=None):
        return self.get_url(self.url(path, params))[0]

    def pages(self, path, params, limit):
        """Yield each page of a paginated list, following Link rel="next"."""
        url = self.url(path, params)
        for _ in range(limit):
            document, headers = self.get_url(url)
            yield document
            url = next_link(headers.get("Link") if headers is not None else None)
            if url is None:
                return
            if not self.same_origin(url):
                raise EvalError(f"GitHub API {path} pagination link points to {safe_origin(urllib.parse.urlsplit(url))}, "
                                f"outside {safe_origin(urllib.parse.urlsplit(self.base_url))}; refusing to follow it")
        raise EvalError(f"GitHub API {path} returned more than {limit} pages")


def repository_path(value, field):
    """GitHub file names are repository-relative; Git allows newlines but not '..'."""
    if (not isinstance(value, str) or not value or "\0" in value or value.startswith("/")
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise EvalError(f"GitHub returned an invalid repository path for {field}: {value!r}")
    return value


def check_head(api, target, pull):
    """Fail unless the PR still has the head and base Prow tested; return changed_files.

    The base branch is compared only when JOB_SPEC names one (refs.base_ref).
    """
    document = api.get(f"/repos/{target.org}/{target.repo}/pulls/{pull.number}")
    head = document.get("head") if isinstance(document, dict) else None
    sha = head.get("sha") if isinstance(head, dict) else None
    if not isinstance(sha, str) or sha.lower() != pull.sha:
        raise EvalError(f"{target.name}#{pull.number} head is {sha!r}, but this job tested {pull.sha}; "
                        "the pull request changed after the job started, so its file list does not "
                        "describe the tested commit (rerun the job)")
    count = document.get("changed_files")
    if not isinstance(count, int) or isinstance(count, bool) or count < 0:
        raise EvalError(f"GitHub returned no usable changed_files for {target.name}#{pull.number}: {count!r}")
    if target.base_ref:
        base = document.get("base")
        ref = base.get("ref") if isinstance(base, dict) else None
        if ref != target.base_ref:
            raise EvalError(f"{target.name}#{pull.number} targets base branch {ref!r}, but this job tested it "
                            f"against {target.base_ref!r}; the pull request was retargeted after the job started, "
                            "so its file list does not describe the tested merge (rerun the job)")
    return count


def pull_files(api, target, pull):
    """Return a pull request's changed paths, as git diff --name-only --no-renames would.

    Renames contribute the old and new paths; deletions count. The listing is
    rejected unless it is complete and the head and base did not change while
    reading it.
    """
    label = f"{target.name}#{pull.number}"
    expected = check_head(api, target, pull)
    if expected > FILE_LIST_CAP:
        raise EvalError(f"{label} changes {expected} files, more than the {FILE_LIST_CAP} GitHub lists for "
                        "a pull request; changed-file selection cannot see them all")
    entries = []
    path = f"/repos/{target.org}/{target.repo}/pulls/{pull.number}/files"
    for page in api.pages(path, {"per_page": PER_PAGE}, FILE_LIST_CAP // PER_PAGE + 1):
        if not isinstance(page, list) or not all(isinstance(entry, dict) for entry in page):
            raise EvalError(f"GitHub API {path} did not return a list of files")
        entries.extend(page)
    if len(entries) != expected:
        raise EvalError(f"GitHub listed {len(entries)} files for {label}, but the pull request reports "
                        f"changed_files={expected}; refusing an incomplete file list")
    check_head(api, target, pull)  # The head and base must not change while the pages are read.
    paths = []
    for entry in entries:
        paths.append(repository_path(entry.get("filename"), f"{label} filename"))
        if entry.get("status") == "renamed":
            paths.append(repository_path(entry.get("previous_filename"), f"{label} previous_filename"))
    return paths


def changed_files(env, api=None):
    """Return the union of paths changed by every pull request the job tested."""
    target = parse_job_spec(env.get("JOB_SPEC", ""), env.get("JOB_TYPE") or "presubmit")
    if not target.pulls:
        print(f"NO-PR: the checkout under test is {target.name}@{target.base_ref or '<unknown>'} from "
              f"JOB_SPEC extra_refs without a pull request (job refs: {target.job_refs}, e.g. a pj-rehearse "
              "rehearsal); it has no PR diff, so no evaluations are selected", flush=True)
        return []
    api = api if api is not None else GitHubAPI.from_env(env)
    files = {}
    for pull in target.pulls:
        paths = pull_files(api, target, pull)
        print(f"CHANGES {target.name}#{pull.number} at {pull.sha[:12]}: {len(paths)} path(s)", flush=True)
        files.update(dict.fromkeys(paths))
    return list(files)
