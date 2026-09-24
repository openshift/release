import hashlib
import html
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(os.environ['CONSOLE_AGENT_RUNROOT'])
ARTIFACTS = pathlib.Path(os.environ['ARTIFACT_DIR'])
EVIDENCE = ARTIFACTS / 'console-flake-evidence'
CONTEXT = ROOT / 'console-flake-context.json'
STATE = ROOT / 'state.json'
SOURCE = pathlib.Path('/go/src/github.com/openshift/console')
AGENT = ROOT / 'agent'
VERIFY = ROOT / 'verify'
ALLOWED = (
    'frontend/e2e/tests/', 'frontend/e2e/pages/', 'frontend/e2e/fixtures/',
    'frontend/e2e/clients/', 'frontend/e2e/utils/', 'frontend/e2e/test-utils/',
)
GENERATED = (
    'frontend/test-results/', 'frontend/playwright-report/',
    'frontend/e2e/.auth/', 'frontend/e2e/.test-config.json',
)
HISTORY_URL = 'https://console-dashboard-squared.apps.rosa.hcmais01ue1.s9m2.p3.openshiftapps.com/api/bulk-prompt'
GCS_ORIGIN = 'https://gcs.ci.openshift.org'
PILOT_JOB = 'pull-ci-openshift-console-main-e2e-gcp-console'


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def read(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return default


def save(state):
    dump(STATE, state)
    dump(ARTIFACTS / 'console-flake-result.json', state)


def git(*args, cwd=SOURCE, check=True, input=None):
    return subprocess.run(['git', '-c', 'safe.directory=*', *args], cwd=cwd,
                          input=input, capture_output=True, check=check)


def same_test(test):
    return (test.get('spec', ''), test.get('project', ''), test.get('name', ''))


def selected_tests(context, history):
    tests = context.get('failed_tests', []) + context.get('flaked_tests', [])
    rates = {entry['suite']: entry.get('flake_rate', 0) for entry in history.get('suites', [])}
    tests = [test for test in tests if all(isinstance(test.get(k), str) and test.get(k) for k in ('spec', 'project', 'name'))]
    tests.sort(key=lambda test: (rates.get(test['spec'], 0), test in context.get('flaked_tests', [])), reverse=True)
    return tests[:3]


def report(message):
    path = ARTIFACTS / 'console-flake-analysis.md'
    if not path.exists():
        path.write_text('> **AI-Generated Content** — Review before use.\n\n# Console e2e failure analysis\n\n' + message + '\n')


def sanitize(value):
    password_file = pathlib.Path(os.environ['SHARED_DIR']) / 'kubeadmin-password'
    if password_file.is_file():
        password = password_file.read_text().strip()
        if password:
            value = value.replace(password, '[REDACTED]')
    value = re.sub(r'(?i)\b(password|token|authorization|secret)\s*[:=]\s*\S+',
                   r'\1=[REDACTED]', value)
    return re.sub(r'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
                  '[REDACTED]', value)


def audit_tool(entry):
    name = entry.get('name', 'unknown')
    arguments = entry.get('input') or {}
    fields = {
        'Bash': ('command',),
        'Read': ('file_path',),
        'Write': ('file_path',),
        'Edit': ('file_path',),
        'Grep': ('pattern', 'path'),
        'Glob': ('pattern', 'path'),
    }.get(name, ())
    details = {key: sanitize(str(arguments[key])) for key in fields if key in arguments}
    return json.dumps({'tool': name, 'arguments': details}, ensure_ascii=False)


def original_artifact_base():
    try:
        job_spec = json.loads(os.environ.get('JOB_SPEC', '{}'))
    except json.JSONDecodeError:
        job_spec = {}
    if not isinstance(job_spec, dict):
        job_spec = {}
    job = os.environ.get('JOB_NAME') or job_spec.get('job', '')
    build = os.environ.get('BUILD_ID') or str(job_spec.get('buildid', ''))
    refs = job_spec.get('refs') if isinstance(job_spec.get('refs'), dict) else {}
    pulls = refs.get('pulls') or []
    pull = os.environ.get('PULL_NUMBER', '')
    if not re.fullmatch(r'[0-9]+', pull):
        pull = str(pulls[0].get('number', '')) if pulls and isinstance(pulls[0], dict) else ''
    rehearsal = re.fullmatch(rf'rehearse-([0-9]+)-{re.escape(PILOT_JOB)}', job)
    if job == PILOT_JOB:
        repository = 'openshift_console'
    elif (rehearsal and pull == rehearsal.group(1)
          and refs.get('org') == 'openshift' and refs.get('repo') == 'release'):
        repository = 'openshift_release'
    else:
        raise ValueError('Prow job is not the pilot job or its release PR rehearsal')
    if not re.fullmatch(r'[0-9]+', build) or not re.fullmatch(r'[0-9]+', pull):
        raise ValueError('Prow job, build, or pull identity is unavailable')
    base = (f'{GCS_ORIGIN}/gcs/test-platform-results-public/pr-logs/pull/'
            f'{repository}/{pull}/{job}/{build}/artifacts/e2e-gcp-console/test/')
    return job, build, base


def parse_original_junit(body):
    root = ET.fromstring(body)
    cases = {}
    for suite in root.iter('testsuite'):
        spec = suite.get('name', '')
        project = suite.get('hostname', '')
        for case in suite.findall('testcase'):
            name = case.get('name', '')
            if not spec or not project or not name:
                continue
            key = (spec, project, name, case.get('classname', ''))
            failure = case.find('failure')
            if failure is None:
                failure = case.find('error')
            outcome = 'fail' if failure is not None else ('skip' if case.find('skipped') is not None else 'pass')
            message = '' if failure is None else sanitize((failure.get('message', '') + '\n' +
                                                          (failure.text or ''))[:1600])
            cases.setdefault(key, []).append((outcome, message))
    failed, flaked = [], []
    for (spec, project, name, classname), attempts in cases.items():
        item = {'spec': spec, 'project': project, 'name': name, 'classname': classname,
                'message': next((message for outcome, message in reversed(attempts) if outcome == 'fail'), '')}
        if attempts[-1][0] == 'fail':
            failed.append(item)
        elif attempts[-1][0] == 'pass' and any(outcome == 'fail' for outcome, _ in attempts[:-1]):
            flaked.append(item)
    return failed, flaked


def original_context():
    job, build, base = original_artifact_base()
    context = {
        'schema_version': 1, 'job_name': job, 'build_id': build,
        'tested_commit': git('rev-parse', 'HEAD', cwd=SOURCE).stdout.decode().strip(),
        'scenario': 'e2e', 'workers': os.environ.get('WORKERS', '2'),
        'test_exit_code': None, 'report_status': 'missing',
        'original_artifacts': [base + 'artifacts/junit-playwright.xml',
                               base + 'artifacts/playwright-test-results/'],
        'artifact_base_url': base, 'failed_tests': [], 'flaked_tests': [],
        'truncated': False, 'has_test_failures': False,
    }
    completion = None
    for attempt in range(6):
        try:
            completion = json.loads(get_limited(base + 'finished.json', 4096, 15))
            break
        except (OSError, ValueError, urllib.error.URLError):
            if attempt < 5:
                time.sleep(5)
    if isinstance(completion, dict):
        context['test_step_passed'] = completion.get('passed')
        context['completion_result'] = str(completion.get('result', ''))[:50]
        context['reported_revision'] = str(completion.get('revision', ''))[:40]
        if completion.get('passed') is True:
            context['report_status'] = 'not_fetched_successful_step'
            return context
    try:
        body = get_limited(base + 'artifacts/junit-playwright.xml', 2 * 1024 * 1024, 30)
        context['failed_tests'], context['flaked_tests'] = parse_original_junit(body)
        context['report_status'] = 'parsed'
    except (OSError, ValueError, UnicodeError, ET.ParseError, urllib.error.URLError) as exc:
        context['report_status'] = 'unavailable'
        context['report_error'] = str(exc)[:200]
    for key in ('failed_tests', 'flaked_tests'):
        if len(context[key]) > 20:
            context[key] = context[key][:20]
            context['truncated'] = True
    context['has_test_failures'] = bool(context['failed_tests'] and completion is None or
                                        isinstance(completion, dict) and completion.get('passed') is False)
    payload = json.dumps(context)
    while len(payload.encode()) > 65536:
        context['truncated'] = True
        if context['failed_tests']:
            context['failed_tests'].pop()
        elif context['flaked_tests']:
            context['flaked_tests'].pop()
        else:
            break
        payload = json.dumps(context)
    return context


def init():
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    EVIDENCE.mkdir(exist_ok=True)
    try:
        context = original_context()
        dump(CONTEXT, context)
    except Exception as exc:
        context = {'job_name': os.environ.get('JOB_NAME', ''),
                   'build_id': os.environ.get('BUILD_ID', ''),
                   'tested_commit': '', 'has_test_failures': False,
                   'report_status': 'unavailable', 'report_error': str(exc)[:200]}
        dump(CONTEXT, context)
    state = {
        'schema_version': 1,
        'job_name': context.get('job_name', ''),
        'build_id': context.get('build_id', ''),
        'tested_commit': context.get('tested_commit', ''),
        'classification': [],
        'verification_status': 'skipped',
        'verified_runs': 0,
        'targets': [],
        'patch': None,
        'reason': 'no failure context',
    }
    if context.get('has_test_failures'):
        state['reason'] = ('investigation pending' if context.get('failed_tests') or context.get('flaked_tests')
                           else 'original step failed without identifiable Playwright tests')
    report('Investigation did not complete.')
    save(state)
    return bool(context.get('has_test_failures') and (context.get('failed_tests') or context.get('flaked_tests')))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, url):
        return None


def get_limited_bytes(url, limit, timeout):
    opener = urllib.request.build_opener(NoRedirect)
    with opener.open(urllib.request.Request(url, headers={'User-Agent': 'console-qe-agent/1'}), timeout=timeout) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('response exceeds size limit')
    return data


def get_limited(url, limit, timeout):
    return get_limited_bytes(url, limit, timeout).decode('utf-8')


def original_error_contexts(context, selected):
    root_url = context['artifact_base_url'] + 'artifacts/playwright-test-results/'
    manifest = []
    deadline = time.monotonic() + 90
    try:
        listing = get_limited(root_url, 1024 * 1024, 20)
        directory_urls = []
        for link in re.findall(r'href="([^"]+/)"', html.unescape(listing)):
            url = urllib.parse.urljoin(GCS_ORIGIN, link)
            if url.startswith(root_url) and url != root_url:
                directory_urls.append(url)
        for index, test in enumerate(selected, 1):
            relative_spec = test['spec'].split('/', 1)[-1].removesuffix('.spec.ts')
            prefix = re.sub(r'[^a-z0-9]+', '-', relative_spec.lower()).strip('-')[:18]
            words = {word.lower() for word in re.findall(r'[A-Za-z0-9]+', test['name'])
                     if len(word) >= 4}
            candidates = [url for url in directory_urls
                          if urllib.parse.unquote(url.rstrip('/').rsplit('/', 1)[-1]).lower().startswith(prefix)]
            candidates.sort(key=lambda url: sum(
                word in urllib.parse.unquote(url).lower() for word in words), reverse=True)
            entry = {'test': {key: test[key] for key in ('spec', 'project', 'name')},
                     'status': 'unavailable'}
            for url in candidates[:12]:
                if time.monotonic() >= deadline:
                    break
                file_url = url + 'error-context.md'
                try:
                    body = get_limited(file_url, 128 * 1024,
                                       min(15, max(1, deadline - time.monotonic())))
                except (OSError, ValueError, UnicodeError, urllib.error.URLError):
                    continue
                match = re.search(r'(?m)^- Name: (.+)$', body)
                parts = match.group(1).strip().split(' >> ') if match else []
                if not parts or parts[0] != test['spec'] or ' › '.join(parts[1:]) != test['name']:
                    continue
                start = body.find('# Test info')
                normalized = body[start:] if start >= 0 else body
                path = EVIDENCE / f'original-error-context-{index}.md'
                path.write_text(sanitize(normalized[:48000]))
                entry.update(status='available', artifact=str(path.relative_to(ARTIFACTS)),
                             source_url=file_url, screenshot_url=url + 'test-failed-1.png',
                             trace_url=url + 'trace.zip')
                try:
                    screenshot = get_limited_bytes(entry['screenshot_url'], 2 * 1024 * 1024,
                                                   min(15, max(1, deadline - time.monotonic())))
                    if screenshot.startswith(b'\x89PNG\r\n\x1a\n'):
                        image_path = EVIDENCE / f'original-screenshot-{index}.png'
                        image_path.write_bytes(screenshot)
                        entry['screenshot_artifact'] = str(image_path.relative_to(ARTIFACTS))
                except (OSError, ValueError, urllib.error.URLError):
                    pass
                break
            manifest.append(entry)
    except (OSError, ValueError, UnicodeError, urllib.error.URLError) as exc:
        manifest = [{'status': 'unavailable', 'reason': str(exc)[:200]}]
    dump(EVIDENCE / 'original-error-contexts.json', manifest)


def history_data(context):
    job = context.get('job_name', '')
    if job != PILOT_JOB and not re.fullmatch(rf'rehearse-[0-9]+-{re.escape(PILOT_JOB)}', job):
        return {'status': 'unavailable', 'reason': 'job name is not the pilot job', 'suites': []}
    job = PILOT_JOB
    days = int(os.environ.get('CONSOLE_FLAKE_HISTORY_DAYS', '14'))
    if not 1 <= days <= 90:
        raise ValueError('history days must be between 1 and 90')
    url = HISTORY_URL + '?' + urllib.parse.urlencode({'repo': 'openshift/console', 'job': job, 'days': days})
    try:
        body = get_limited(url, 1024 * 1024, 60)
        if '| Repo | `openshift/console` |' not in body or f'| Prow job | `{job}` |' not in body:
            raise ValueError('dashboard returned mismatched context')
        suites = []
        for line in body.splitlines():
            if not re.match(r'^\| \d+ \| `', line):
                continue
            columns = [part.strip() for part in line.strip('|').split('|')]
            if len(columns) < 10:
                continue
            suite = columns[1].strip('`')
            if suite in ('step graph', 'job') or not suite.endswith('.spec.ts'):
                continue
            try:
                suites.append({
                    'suite': suite,
                    'runs': int(columns[6]),
                    'failed': int(columns[7]),
                    'flaked': int(columns[8]),
                    'flake_rate': int(columns[5]) / 100,
                    'evidence_url': re.search(r'\]\((https://[^)]+)\)', columns[9]).group(1),
                })
            except (ValueError, AttributeError):
                continue
        generated = re.search(r'generated ([0-9T:.Z-]+)', body)
        if not suites:
            return {'status': 'unknown', 'reason': 'no Console test suites in dashboard response',
                    'source_url': url, 'suites': []}
        return {'status': 'available', 'generated_at': generated.group(1) if generated else '',
                'source_url': url, 'suites': suites}
    except (OSError, ValueError, UnicodeError, urllib.error.URLError) as exc:
        return {'status': 'unavailable', 'reason': str(exc)[:200], 'suites': []}


def clone(destination, commit):
    git('clone', '--shared', '--no-checkout', str(SOURCE), str(destination), cwd=ROOT)
    git('checkout', '--detach', commit, cwd=destination)
    modules = destination / 'frontend/node_modules'
    if not modules.exists():
        modules.symlink_to(SOURCE / 'frontend/node_modules', target_is_directory=True)


def cluster_env():
    env = os.environ.copy()
    shared = pathlib.Path(env['SHARED_DIR'])
    if not env.get('KUBECONFIG') and (shared / 'kubeconfig').is_file():
        env['KUBECONFIG'] = str(shared / 'kubeconfig')
    if not env.get('KUBECONFIG') or not pathlib.Path(env['KUBECONFIG']).is_file():
        raise ValueError('KUBECONFIG is unavailable')
    password = shared / 'kubeadmin-password'
    if not password.is_file():
        raise ValueError('kubeadmin-password is unavailable')
    env['BRIDGE_KUBEADMIN_PASSWORD'] = password.read_text().strip()
    env.setdefault('BRIDGE_HTPASSWD_IDP', 'test')
    env.setdefault('BRIDGE_HTPASSWD_USERNAME', 'test')
    env.setdefault('BRIDGE_HTPASSWD_PASSWORD', 'test')
    result = subprocess.run(['oc', 'get', 'consoles.config.openshift.io', 'cluster',
                             '-o', 'jsonpath={.status.consoleURL}'], env=env,
                            capture_output=True, text=True, timeout=20, check=True)
    url = result.stdout.strip()
    if not url.startswith('https://'):
        raise ValueError('Console URL is unavailable')
    env['BRIDGE_BASE_ADDRESS'] = url
    env['WEB_CONSOLE_URL'] = url.rstrip('/') + '/'
    env['CI'] = 'true'
    env['OPENSHIFT_CI'] = 'true'
    env['GIT_CONFIG_COUNT'] = '1'
    env['GIT_CONFIG_KEY_0'] = 'safe.directory'
    env['GIT_CONFIG_VALUE_0'] = '*'
    env['GLOBAL_TIMEOUT_MS'] = '600000'
    return env


def prepare():
    context = read(CONTEXT, {})
    state = read(STATE, {})
    commit = context.get('tested_commit', '')
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('tested commit is missing or malformed')
    image_commit = git('rev-parse', 'HEAD').stdout.decode().strip()
    if commit != image_commit:
        raise ValueError('test context does not match the source image')
    revision = os.environ.get('CONSOLE_FLAKE_SKILL_REVISION', '')
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('pin CONSOLE_FLAKE_SKILL_REVISION to a merged release commit')
    skill_url = (f'https://raw.githubusercontent.com/openshift/release/{revision}/'
                 'ci-operator/step-registry/openshift/console/qe-agent/SKILL.md')
    skill = get_limited(skill_url, 102400, 30)
    if not skill.startswith('---\nname: console-flake\n'):
        raise ValueError('pinned skill has unexpected content')
    (ROOT / 'skill.md').write_text(skill)
    history = history_data(context)
    dump(EVIDENCE / 'history.json', history)
    state['history_status'] = history['status']
    selected = selected_tests(context, history)
    if not selected:
        raise ValueError('no individual Playwright tests were identified')
    dump(ROOT / 'selected.json', selected)
    original_error_contexts(context, selected)
    clone(AGENT, commit)
    env = cluster_env()
    dump(ROOT / 'runtime.json', {key: env[key] for key in ('KUBECONFIG', 'BRIDGE_BASE_ADDRESS', 'WEB_CONSOLE_URL', 'BRIDGE_HTPASSWD_IDP', 'BRIDGE_HTPASSWD_USERNAME')})
    save(state)


def test_command(test, worktree, workers, grep):
    spec = test['spec']
    if spec.startswith('frontend/e2e/tests/'):
        spec = spec[len('frontend/e2e/tests/'):]
    if not re.fullmatch(r'[A-Za-z0-9_./-]+\.spec\.ts', spec) or '..' in pathlib.PurePosixPath(spec).parts:
        raise ValueError('unsafe spec path')
    path = worktree / 'frontend/e2e/tests' / spec
    if not path.is_file():
        raise ValueError(f'spec missing from checkout: {spec}')
    project = test['project']
    if not re.fullmatch(r'[A-Za-z0-9_-]+', project):
        raise ValueError('unsafe project')
    command = ['./node_modules/.bin/playwright', 'test', '--project=' + project,
               '--retries=0', '--workers=' + str(workers),
               '--reporter=./e2e/reporters/prow-junit-reporter.ts',
               'e2e/tests/' + spec]
    if grep:
        command.extend(['--grep', re.escape(test['name'].split(' › ')[-1]) + '$'])
    return command


def run_test(test, worktree, workers, label, deadline, grep=True):
    report_path = worktree / 'frontend/test-results/prow-junit-results.xml'
    if report_path.exists():
        report_path.unlink()
    env = cluster_env()
    env['ARTIFACT_DIR'] = str(ROOT / 'private-artifacts')
    env['WORKERS'] = str(workers)
    remaining = min(600, int(deadline - time.monotonic()))
    result = {'label': label, 'test': {key: test[key] for key in ('spec', 'project', 'name')},
              'workers': workers, 'retries': 0, 'passed': False, 'executed': False}
    if remaining < 1:
        result['error'] = 'verification time limit reached'
        return result
    try:
        finished = subprocess.run(test_command(test, worktree, workers, grep),
                                  cwd=worktree / 'frontend', env=env, capture_output=True,
                                  text=True, timeout=remaining)
        result['exit_code'] = finished.returncode
        result['output'] = sanitize((finished.stdout + '\n' + finished.stderr)[-3000:])
    except subprocess.TimeoutExpired:
        result['error'] = 'Playwright timed out'
        return result
    if not report_path.is_file():
        result['error'] = 'Playwright Prow reporter did not produce a report'
        return result
    try:
        xml_root = ET.parse(report_path).getroot()
        matches = []
        for suite in xml_root.iter('testsuite'):
            suite_name = suite.get('name', '')
            project = suite.get('hostname', '')
            if suite_name != test['spec'] or project != test['project']:
                continue
            for case in suite.findall('testcase'):
                if case.get('name') == test['name']:
                    matches.append(case)
        result['executed'] = bool(matches)
        result['passed'] = (finished.returncode == 0 and len(matches) == 1
                            and all(case.find('failure') is None and case.find('error') is None
                                    and case.find('skipped') is None for case in matches))
    except ET.ParseError:
        result['error'] = 'Playwright report is malformed'
    if not result['passed']:
        screenshot_dir = EVIDENCE / 'screenshots'
        existing = len(list(screenshot_dir.glob('*.png'))) if screenshot_dir.is_dir() else 0
        if existing < 6:
            screenshots = []
            for image in (worktree / 'frontend/test-results').rglob('*.png'):
                if len(screenshots) >= 2 or existing + len(screenshots) >= 6:
                    break
                if image.is_file() and image.stat().st_size <= 2 * 1024 * 1024:
                    screenshot_dir.mkdir(parents=True, exist_ok=True)
                    identifier = hashlib.sha256(repr(same_test(test)).encode()).hexdigest()[:10]
                    destination = screenshot_dir / f'{label}-{identifier}-{len(screenshots)}.png'
                    shutil.copyfile(image, destination)
                    screenshots.append(str(destination.relative_to(ARTIFACTS)))
            if screenshots:
                result['screenshots'] = screenshots
    return result


def baseline():
    selected = read(ROOT / 'selected.json', [])
    context = read(CONTEXT, {})
    workers = int(context.get('workers', '2'))
    deadline = min(time.monotonic() + 1200, float(os.environ['CONSOLE_AGENT_INVESTIGATION_DEADLINE']))
    results = []
    for test in selected:
        for number in (1, 2):
            result = run_test(test, AGENT, workers, f'baseline-{number}', deadline)
            results.append(result)
            dump(EVIDENCE / 'baseline.json', results)
            if time.monotonic() >= deadline:
                return


def candidate_patch():
    ignored = set(GENERATED)
    untracked = git('ls-files', '--others', '--exclude-standard', '-z', cwd=AGENT).stdout.decode().split('\0')
    for path in filter(None, untracked):
        if any(path.startswith(prefix) for prefix in ignored) or path.startswith('.claude/'):
            continue
        if not any(path.startswith(prefix) for prefix in ALLOWED):
            raise ValueError(f'agent created a file outside test code: {path}')
        git('add', '-N', '--', path, cwd=AGENT)
    paths = git('diff', '--name-only', '-z', 'HEAD', cwd=AGENT).stdout.decode().split('\0')
    paths = list(filter(None, paths))
    for path in paths:
        if not any(path.startswith(prefix) for prefix in ALLOWED):
            raise ValueError(f'agent modified a file outside test code: {path}')
    patch = git('diff', '--binary', 'HEAD', cwd=AGENT).stdout
    if len(patch) > 102400:
        raise ValueError('candidate patch is too large')
    added = '\n'.join(line[1:] for line in patch.decode('utf-8', 'replace').splitlines()
                      if line.startswith('+') and not line.startswith('+++'))
    if re.search(r'\btest\.(?:skip|fixme|fail)\s*\(|\bwaitForTimeout\s*\(|\bretries\s*:', added):
        raise ValueError('candidate masks coverage or uses retries/time waits')
    if sanitize(added) != added:
        raise ValueError('candidate contains credential-like text')
    for path in paths:
        old = git('show', 'HEAD:' + path, cwd=AGENT, check=False)
        before = old.stdout.decode('utf-8', 'replace') if old.returncode == 0 else ''
        after = (AGENT / path).read_text(errors='replace') if (AGENT / path).is_file() else ''
        count = lambda content: len(re.findall(r'\b(?:expect|assert)\s*\(', content))
        if count(after) < count(before):
            raise ValueError(f'candidate removes an assertion from {path}')
    return paths, patch


def verify():
    state = read(STATE, {})
    context = read(CONTEXT, {})
    state.update(verification_status='no_fix', verified_runs=0, required_runs=0,
                 targets=[], patch=None, tested_commit=context.get('tested_commit', ''))
    (ARTIFACTS / 'console-flake-fix.patch').unlink(missing_ok=True)
    save(state)
    if state['tested_commit'] != git('rev-parse', 'HEAD', cwd=SOURCE).stdout.decode().strip():
        raise ValueError('original tested source changed before verification')
    selected = read(ROOT / 'selected.json', [])
    if not AGENT.is_dir():
        state['reason'] = 'agent workspace was not created'
        save(state)
        return
    paths, patch = candidate_patch()
    if not patch:
        state.update(verification_status='no_fix', reason='no candidate patch')
        save(state)
        return
    manifest = read(EVIDENCE / 'candidate-targets.json', [])
    selected_keys = {same_test(test) for test in selected}
    if not isinstance(manifest, list) or not 1 <= len(manifest) <= 3 or any(same_test(test) not in selected_keys for test in manifest):
        raise ValueError('candidate targets must match selected original failures')
    if len({same_test(test) for test in manifest}) != len(manifest):
        raise ValueError('candidate target is duplicated')
    state['targets'] = [{key: test[key] for key in ('spec', 'project', 'name')} for test in manifest]
    state['verification_status'] = 'unverified'
    patch_path = ARTIFACTS / 'console-flake-fix.patch'
    patch_path.write_bytes(patch)
    state['patch'] = patch_path.name
    save(state)
    clone(VERIFY, state['tested_commit'])
    git('apply', '--check', str(patch_path), cwd=VERIFY)
    git('apply', str(patch_path), cwd=VERIFY)
    evidence = []
    deadline = time.monotonic() + 1800
    env = cluster_env()
    env['ARTIFACT_DIR'] = str(ROOT / 'private-artifacts')
    for label, command in (
        ('lint', ['yarn', 'eslint', *[path.removeprefix('frontend/') for path in paths if path.endswith(('.ts', '.tsx'))]]),
        ('typecheck', ['yarn', 'tsc', '--noEmit', '-p', 'e2e/tsconfig.json']),
    ):
        if label == 'lint' and len(command) == 2:
            continue
        remaining = min(300, int(deadline - time.monotonic()))
        if remaining < 1:
            raise TimeoutError('verification time limit reached')
        finished = subprocess.run(command, cwd=VERIFY / 'frontend', env=env, capture_output=True,
                                  text=True, timeout=remaining)
        evidence.append({'label': label, 'passed': finished.returncode == 0,
                         'output': sanitize((finished.stdout + '\n' + finished.stderr)[-3000:])})
        dump(EVIDENCE / 'verification.json', evidence)
        if finished.returncode != 0:
            state['reason'] = f'{label} failed'
            save(state)
            return
    required = int(os.environ.get('CONSOLE_FLAKE_VERIFY_RUNS', '5'))
    if not 5 <= required <= 10:
        raise ValueError('verification runs must be from 5 to 10')
    workers = int(context.get('workers', '2'))
    for test in manifest:
        for number in range(1, required + 1):
            result = run_test(test, VERIFY, workers, f'fixed-{number}', deadline)
            evidence.append(result)
            dump(EVIDENCE / 'verification.json', evidence)
            if not result['passed']:
                state['reason'] = f'target failed verification run {number}'
                save(state)
                return
            state['verified_runs'] += 1
            save(state)
        result = run_test(test, VERIFY, workers, 'containing-spec', deadline, grep=False)
        evidence.append(result)
        dump(EVIDENCE / 'verification.json', evidence)
        if not result['passed']:
            state['reason'] = 'containing spec failed'
            save(state)
            return
    state.update(verification_status='validated', reason='all independent checks passed',
                 required_runs=required)
    save(state)


def finalize():
    state = read(STATE, {})
    stream = ROOT / 'session.jsonl'
    terminal = None
    audit = []
    if stream.is_file():
        for line in stream.read_text(errors='replace').splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get('type') == 'result':
                terminal = record
            if record.get('type') == 'assistant':
                for entry in record.get('message', {}).get('content', []):
                    if entry.get('type') == 'tool_use':
                        audit.append(audit_tool(entry))
    (ARTIFACTS / 'qe-agent-commands.log').write_text('\n'.join(audit) + ('\n' if audit else ''))
    if terminal:
        usage_record = {key: terminal[key] for key in (
            'session_id', 'usage', 'modelUsage', 'total_cost_usd',
            'duration_ms', 'duration_api_ms', 'num_turns', 'is_error', 'subtype',
        ) if key in terminal}
        dump(ARTIFACTS / 'qe-agent-usage.json', usage_record)
        usage = terminal.get('usage') or {}
        model = next(iter(terminal.get('modelUsage') or {}), os.environ.get('CLAUDE_MODEL', ''))
        row = {
            'session_id': str(terminal.get('session_id', '')),
            'model': str(model), 'claude_code_version': '', 'permission_mode': '',
            'entrypoint': 'openshift-console-qe-agent', 'prompt': '', 'plugins_loaded': '',
            'analyzed_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'duration_ms': str(terminal.get('duration_ms', 0)),
            'duration_api_ms': str(terminal.get('duration_api_ms', 0)),
            'ttft_ms': '0', 'num_turns': str(terminal.get('num_turns', 0)),
            'total_cost_usd': str(terminal.get('total_cost_usd', 0)),
            'input_tokens': str(usage.get('input_tokens', 0)),
            'output_tokens': str(usage.get('output_tokens', 0)),
            'cache_read_input_tokens': str(usage.get('cache_read_input_tokens', 0)),
            'cache_creation_input_tokens': str(usage.get('cache_creation_input_tokens', 0)),
            'cache_hit_rate_pct': '0', 'total_tool_calls': str(len(audit)),
            'tool_call_breakdown': '{}', 'skills_invoked': '', 'files_written': '0',
            'num_thinking_blocks': '0', 'num_subagents': '0', 'subagent_total_tool_uses': '0',
            'subagent_total_duration_ms': '0', 'is_error': '1' if terminal.get('is_error') else '0',
            'terminal_reason': '', 'stop_reason': '',
        }
        schema = {key: ('float64' if key in ('total_cost_usd', 'cache_hit_rate_pct')
                        else 'int64' if key in ('duration_ms', 'duration_api_ms', 'ttft_ms',
                        'num_turns', 'input_tokens', 'output_tokens', 'cache_read_input_tokens',
                        'cache_creation_input_tokens', 'total_tool_calls', 'files_written',
                        'num_thinking_blocks', 'num_subagents', 'subagent_total_tool_uses',
                        'subagent_total_duration_ms', 'is_error') else 'string') for key in row}
        dump(pathlib.Path(os.environ.get('CONSOLE_AGENT_METRICS_PATH',
                                        ARTIFACTS / 'claude-session-metrics-autodl.json')), {
            'table_name': 'claude_session_metrics', 'schema': schema, 'schema_mapping': None,
            'rows': [row], 'chunk_size': 0, 'expiration_days': 0, 'partition_column': '',
        })
    diagnoses = read(EVIDENCE / 'candidate-diagnoses.json', [])
    originals = read(CONTEXT, {}).get('failed_tests', []) + read(CONTEXT, {}).get('flaked_tests', [])
    keys = {same_test(test) for test in originals}
    baseline_runs = read(EVIDENCE / 'baseline.json', [])
    original_flakes = {same_test(test) for test in read(CONTEXT, {}).get('flaked_tests', [])}
    original_failures = {same_test(test) for test in read(CONTEXT, {}).get('failed_tests', [])}
    if isinstance(diagnoses, list):
        state['classification'] = []
        for entry in diagnoses:
            if not isinstance(entry, dict) or same_test(entry) not in keys or entry.get('classification') not in (
                    'test_defect', 'product_defect', 'infrastructure', 'inconclusive'):
                continue
            attempts = [run for run in baseline_runs if same_test(run.get('test', {})) == same_test(entry)
                        and run.get('executed')]
            intermittent = (
                same_test(entry) in original_flakes or
                (same_test(entry) in original_failures and any(run.get('passed') for run in attempts)) or
                (any(run.get('passed') for run in attempts) and
                 any(not run.get('passed') for run in attempts))
            )
            state['classification'].append({
                **{key: entry[key] for key in ('spec', 'project', 'name', 'classification')},
                'observed_flaky': intermittent,
            })
    save(state)
    analysis = ARTIFACTS / 'console-flake-analysis.md'
    if analysis.is_file():
        content = analysis.read_text(errors='replace')
        content = sanitize(content)
        if not content.startswith('> **AI-Generated Content**'):
            content = '> **AI-Generated Content** — Review before use.\n\n' + content
        content += ('\n\n## Independent verification\n\n'
                    f'Status: **{state.get("verification_status", "skipped")}**. '
                    f'{state.get("reason", "No result")}\n\n'
                    'See `console-flake-evidence/verification.json` for each attempt.\n')
        analysis.write_text(content)
    targets = state.get('targets', [])
    verified_runs = state.get('verified_runs', 0)
    passes_per_target = verified_runs // len(targets) if targets else 0
    if (state.get('verification_status') == 'validated' and state.get('patch')
            and (ARTIFACTS / state['patch']).is_file()
            and (ARTIFACTS / state['patch']).stat().st_size > 0
            and analysis.is_file() and (ARTIFACTS / 'console-flake-result.json').is_file()
            and targets and verified_runs == passes_per_target * len(targets)
            and passes_per_target == state.get('required_runs') and passes_per_target >= 5):
        print('\n' + '=' * 70 + '\n' + '=' * 70 + '\n')
        print('          PROPOSED SOLUTION TO FIX THE FLAKE FOUND\n')
        print(f'  Verification: PASSED — {passes_per_target} consecutive runs per targeted test')
        print('  Retries:      disabled')
        print('  Review:       human review required before applying\n')
        for test in targets:
            print(f'  Target: {test["project"]}: {test["spec"]} — {test["name"]}')
        print(f'\n  Artifacts:            {ARTIFACTS}')
        print('  Root cause analysis: console-flake-analysis.md')
        print('  Proposed patch:      console-flake-fix.patch')
        print('  Detailed results:   console-flake-result.json\n')
        print('  The original CI failure remains unchanged.\n')
        print('=' * 70 + '\n' + '=' * 70, flush=True)
    elif state.get('patch'):
        print('Candidate patch produced, but verification did not complete successfully.', flush=True)
    else:
        print('No verified fix proposal produced.', flush=True)


if __name__ == '__main__':
    command = sys.argv[1]
    try:
        if command == 'init':
            sys.exit(0 if init() else 2)
        if command == 'prepare':
            prepare()
        elif command == 'baseline':
            baseline()
        elif command == 'verify':
            verify()
        elif command == 'reject':
            state = read(STATE, {})
            state.update(verification_status='no_fix', verified_runs=0,
                         targets=[], patch=None, reason='agent changed protected verification inputs')
            (ARTIFACTS / 'console-flake-fix.patch').unlink(missing_ok=True)
            save(state)
        elif command == 'finalize':
            finalize()
        else:
            raise ValueError('unknown command')
    except Exception as exc:
        state = read(STATE, {})
        if command != 'finalize':
            state['reason'] = str(exc)[:300]
            if command == 'verify':
                state['verification_status'] = 'unverified' if state.get('patch') else 'no_fix'
            save(state)
        print(f'Console QE Agent {command}: {exc}', file=sys.stderr)
        sys.exit(1)
