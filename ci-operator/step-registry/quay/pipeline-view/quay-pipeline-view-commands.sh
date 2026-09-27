#!/bin/bash

# Writes custom-link-quay-pipeline.html, which Prow's html lens renders on the
# job page. The page is a static shell: it renders in the browser at
# view time from this run's own GCS artifacts (ci-operator-step-graph.json,
# ci-operator.log, junit_operator.xml, finished.json and the quay step
# artifacts). A post step cannot render it itself: its own timings, the later
# post steps, finished.json and the step graph do not exist until the job ends.
# The GCS JSON API answers CORS requests from prow.ci.openshift.org; its XML
# API does not, so every fetch below goes through storage/v1.

set -o nounset
set -o errexit
set -o pipefail

# Compose the run's GCS path the same way quay-test-e2e does for its Playwright
# report link.
bucket="test-platform-results-public"
if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
  run_path="pr-logs/pull/${REPO_OWNER:-}_${REPO_NAME:-}/${PULL_NUMBER}/${JOB_NAME:-}/${BUILD_ID:-}"
else
  run_path="logs/${JOB_NAME:-}/${BUILD_ID:-}"
fi
page="${ARTIFACT_DIR}/custom-link-quay-pipeline.html"

cat > "${page}" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Quay pipeline</title>
<script>var RUN = { bucket: "${bucket}", path: "${run_path}", test: "${JOB_NAME_SAFE:-}" };</script>
EOF

# Quoted heredoc: nothing below is expanded by the shell.
cat >> "${page}" << 'EOF'
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@patternfly/patternfly@6.6.1/patternfly.min.css">
<style>
body { margin: 0; background: var(--pf-t--global--background--color--secondary--default); }
.qp-main { display: grid; gap: var(--pf-t--global--spacer--md); padding: var(--pf-t--global--spacer--md); }
.qp-sub { color: var(--pf-t--global--text--color--subtle); font-size: var(--pf-t--global--font--size--sm); font-weight: normal; }
.qp-ok { color: var(--pf-t--global--icon--color--status--success--default); }
.qp-bad { color: var(--pf-t--global--icon--color--status--danger--default); }
.qp-nw { white-space: nowrap; }
.qp-tail { max-height: 24em; overflow: auto; font-size: var(--pf-t--global--font--size--xs); white-space: pre-wrap; }
.pf-v6-c-masthead__logo svg { height: 28px; width: auto; display: block; }

.qp-graph { display: flex; flex-wrap: wrap; row-gap: var(--pf-t--global--spacer--md); align-items: center; padding: var(--pf-t--global--spacer--sm) 0; }
.qp-node { flex: 1 1 0; min-width: min-content; display: flex; flex-direction: column;
  padding: 6px 8px; border: var(--pf-t--global--border--width--regular) solid var(--pf-t--global--border--color--default);
  border-radius: var(--pf-t--global--border--radius--small); background: var(--pf-t--global--background--color--primary--default);
  color: var(--pf-t--global--text--color--regular); font-size: var(--pf-t--global--font--size--sm); line-height: 1.35; text-decoration: none; }
.qp-node:hover { border-color: var(--pf-t--global--border--color--hover); text-decoration: none; }
.qp-node svg { vertical-align: -2px; }
.qp-node b { font-weight: var(--pf-t--global--font--weight--body--bold); }
.qp-node small { font-size: var(--pf-t--global--font--size--xs); color: var(--pf-t--global--text--color--subtle); }
.qp-node.qp-failed { border: var(--pf-t--global--border--width--strong) solid var(--pf-t--global--border--color--status--danger--default); }
.qp-edge { flex: 0 0 12px; height: 1px; background: var(--pf-t--global--border--color--default); position: relative; }
.qp-edge::after { content: ""; position: absolute; right: 0; top: -3px; border-left: 5px solid var(--pf-t--global--border--color--default); border-top: 3px solid transparent; border-bottom: 3px solid transparent; }
.qp-edge.qp-after-fail { flex-basis: 36px; height: 0; background: none; border-top: 2px dashed var(--pf-t--global--border--color--status--danger--default); }
.qp-edge.qp-after-fail::after { top: -4px; border-left-color: var(--pf-t--global--border--color--status--danger--default); }
.qp-par { flex: 0 0 auto; display: flex; flex-direction: column; gap: 8px; padding: 0 0 0 4px;
  border-right: 1px solid var(--pf-t--global--border--color--default); }
.qp-lane { display: flex; align-items: center; }
.qp-lane::after { content: ""; height: 1px; background: var(--pf-t--global--border--color--default); flex: 1 0 12px; }
.qp-lane .qp-node { flex: none; }
</style>
</head>
<body>
<header class="pf-v6-c-masthead">
  <div class="pf-v6-c-masthead__main">
    <div class="pf-v6-c-masthead__brand"><span class="pf-v6-c-masthead__logo"><svg role="img" aria-label="Red Hat Quay" xmlns="http://www.w3.org/2000/svg" width="356.5" height="39.700001" viewBox="0 0 356.5 39.7"><defs><style>.cls-1{fill:#d71e00;}.cls-2{fill:#c21a00;}.cls-3{fill:#fff;}.cls-4{fill:#b7b7b7;}</style></defs><g transform="translate(48.651235,0.837963)"><g><path d="m 18.4,32.5 -4.5,-9.3 h -3.1 v 9.3 H 3.3 V 4.9 h 12.4 c 1.6,0 3.1,0.2 4.4,0.5 1.3,0.3 2.5,0.9 3.4,1.6 0.9,0.7 1.7,1.6 2.2,2.8 0.5,1.1 0.8,2.5 0.8,4.2 0,2.1 -0.4,3.8 -1.3,5.1 -0.9,1.3 -2.1,2.3 -3.6,3 L 27,32.5 Z M 18,11.9 c -0.5,-0.6 -1.4,-0.8 -2.6,-0.8 h -4.6 v 6 h 4.5 c 1.3,0 2.2,-0.3 2.7,-0.8 0.5,-0.5 0.8,-1.3 0.8,-2.3 0,-0.8 -0.3,-1.5 -0.8,-2.1 z" /><path d="M 32.8,32.5 V 4.9 H 54 v 6.4 H 40.3 V 15 h 8.2 v 6.3 H 40.3 V 26 h 13.9 v 6.4 H 32.8 Z" /><path d="m 83.3,25.1 c -0.6,1.8 -1.6,3.2 -2.8,4.3 -1.2,1.1 -2.8,1.9 -4.7,2.4 -1.9,0.5 -4,0.7 -6.5,0.7 h -9 V 4.9 H 70 c 2.2,0 4.1,0.2 5.9,0.7 1.8,0.4 3.3,1.2 4.5,2.3 1.2,1.1 2.2,2.5 2.8,4.2 0.7,1.7 1,3.9 1,6.5 0,2.6 -0.3,4.7 -0.9,6.5 z M 76,15.4 c -0.2,-0.9 -0.6,-1.7 -1.1,-2.3 -0.5,-0.6 -1.2,-1 -2,-1.3 -0.8,-0.3 -1.8,-0.4 -3,-0.4 H 68 V 26 h 1.7 c 1.2,0 2.2,-0.1 3,-0.4 0.8,-0.3 1.5,-0.7 2.1,-1.2 0.5,-0.6 0.9,-1.3 1.2,-2.3 0.2,-0.9 0.4,-2.1 0.4,-3.5 0,-1.2 -0.2,-2.3 -0.4,-3.2 z" /><path d="M 120.7,32.5 V 21.6 h -8.6 v 10.9 h -7.8 V 4.9 h 7.8 V 15 h 8.6 V 4.9 h 7.8 v 27.7 h -7.8 z" /><path d="m 153.2,32.5 -1.5,-4.9 h -8.3 l -1.5,4.9 h -8.2 l 10,-27.7 h 7.7 l 10,27.7 z m -3.9,-12.7 c -0.2,-0.9 -0.4,-1.7 -0.6,-2.3 -0.2,-0.7 -0.4,-1.3 -0.5,-1.8 -0.1,-0.5 -0.3,-1 -0.4,-1.4 -0.1,-0.4 -0.2,-0.9 -0.3,-1.4 -0.1,0.5 -0.2,0.9 -0.3,1.4 -0.1,0.4 -0.2,0.9 -0.4,1.5 -0.1,0.5 -0.3,1.1 -0.5,1.8 -0.2,0.7 -0.4,1.4 -0.6,2.3 l -0.5,1.8 h 4.6 z" /><path d="m 177.2,11.5 v 21 h -7.7 v -21 h -7.7 V 4.9 H 185 v 6.7 h -7.8 z" /><path d="m 195.2,9.6 c -0.2,0.4 -0.4,0.8 -0.8,1.1 -0.3,0.3 -0.7,0.6 -1.1,0.8 -0.4,0.2 -0.9,0.3 -1.4,0.3 -0.5,0 -1,-0.1 -1.4,-0.3 -0.4,-0.2 -0.8,-0.4 -1.1,-0.8 -0.3,-0.3 -0.6,-0.7 -0.8,-1.1 -0.2,-0.4 -0.3,-0.9 -0.3,-1.4 0,-0.5 0.1,-1 0.3,-1.4 0.2,-0.4 0.4,-0.8 0.8,-1.1 0.3,-0.3 0.7,-0.6 1.1,-0.8 0.4,-0.2 0.9,-0.3 1.4,-0.3 0.5,0 1,0.1 1.4,0.3 0.4,0.2 0.8,0.4 1.1,0.8 0.3,0.3 0.6,0.7 0.8,1.1 0.2,0.4 0.3,0.9 0.3,1.4 0,0.5 -0.1,1 -0.3,1.4 z m -0.5,-2.5 c -0.2,-0.4 -0.4,-0.7 -0.6,-1 -0.3,-0.3 -0.6,-0.5 -1,-0.6 -0.4,-0.2 -0.8,-0.2 -1.2,-0.2 -0.4,0 -0.8,0.1 -1.2,0.2 -0.4,0.2 -0.7,0.4 -0.9,0.6 -0.2,0.2 -0.5,0.6 -0.6,1 -0.2,0.4 -0.2,0.8 -0.2,1.2 0,0.4 0.1,0.8 0.2,1.2 0.2,0.4 0.4,0.7 0.6,0.9 0.3,0.3 0.6,0.5 0.9,0.6 0.4,0.2 0.8,0.2 1.2,0.2 0.4,0 0.8,-0.1 1.2,-0.2 0.4,-0.2 0.7,-0.4 1,-0.6 0.3,-0.3 0.5,-0.6 0.6,-0.9 0.2,-0.4 0.2,-0.8 0.2,-1.2 0,-0.5 -0.1,-0.9 -0.2,-1.2 z m -1.4,1 c -0.2,0.2 -0.4,0.3 -0.6,0.4 l 0.8,1.6 h -0.8 l -0.8,-1.5 h -0.7 v 1.5 h -0.7 V 6.2 h 1.7 c 0.2,0 0.3,0 0.5,0.1 0.2,0 0.3,0.1 0.4,0.2 0.1,0.1 0.2,0.2 0.3,0.4 0.1,0.1 0.1,0.3 0.1,0.5 0,0.3 -0.1,0.6 -0.2,0.7 z M 192.7,7 c -0.1,-0.1 -0.3,-0.1 -0.4,-0.1 h -1 V 8 h 1 c 0.2,0 0.3,0 0.4,-0.1 0.1,-0.1 0.2,-0.2 0.2,-0.4 -0.1,-0.3 -0.1,-0.4 -0.2,-0.5 z" /></g><g><path d="m 227,25.8 c -0.9,2 -2,3.7 -3.5,4.9 l 1.8,2.9 -2.5,1.5 -1.7,-2.8 c -1.3,0.6 -2.7,0.9 -4.2,0.9 -1.7,0 -3.3,-0.3 -4.7,-1 -1.4,-0.7 -2.6,-1.7 -3.6,-2.9 -1,-1.3 -1.8,-2.8 -2.3,-4.5 -0.5,-1.7 -0.8,-3.6 -0.8,-5.7 0,-2.1 0.3,-4 0.8,-5.7 0.6,-1.7 1.3,-3.2 2.3,-4.5 1,-1.3 2.2,-2.2 3.6,-2.9 1.4,-0.7 3,-1.1 4.7,-1.1 1.7,0 3.3,0.3 4.7,1 1.4,0.7 2.6,1.7 3.6,2.9 1,1.3 1.8,2.8 2.3,4.5 0.5,1.7 0.8,3.6 0.8,5.7 0,2.4 -0.5,4.7 -1.3,6.8 z m -2.5,-11.5 c -0.4,-1.4 -1,-2.6 -1.8,-3.6 -0.8,-1 -1.7,-1.8 -2.7,-2.3 -1,-0.5 -2.1,-0.8 -3.3,-0.8 -1.2,0 -2.3,0.3 -3.3,0.8 -1,0.5 -1.9,1.3 -2.6,2.3 -0.7,1 -1.3,2.2 -1.7,3.6 -0.4,1.4 -0.6,3 -0.6,4.7 0,1.7 0.2,3.3 0.6,4.7 0.4,1.4 1,2.6 1.8,3.6 0.7,1 1.6,1.8 2.7,2.3 1,0.5 2.1,0.8 3.3,0.8 0.9,0 1.8,-0.2 2.6,-0.5 l -2.2,-3.7 2.5,-1.5 2.2,3.6 c 1,-0.9 1.8,-2.2 2.4,-3.8 0.6,-1.6 0.9,-3.4 0.9,-5.6 -0.1,-1.7 -0.3,-3.2 -0.8,-4.6 z" /><path d="m 251.5,30.1 c -1.6,2 -4.1,3 -7.4,3 -3.3,0 -5.8,-1 -7.5,-2.9 -1.7,-2 -2.5,-4.8 -2.5,-8.7 V 5.2 h 3.1 v 16.3 c 0,5.9 2.3,8.9 7,8.9 2.4,0 4.1,-0.7 5.1,-2.2 1,-1.4 1.5,-3.7 1.5,-6.6 V 5.2 h 3.1 v 16.3 c 0,3.8 -0.8,6.7 -2.4,8.6 z" /><path d="m 277.9,32.7 -2.4,-7 h -11.4 l -2.4,7 h -3.1 l 9.6,-27.5 h 3.4 l 9.6,27.5 z m -6.4,-18.9 c -0.2,-0.4 -0.3,-0.9 -0.5,-1.5 -0.2,-0.5 -0.3,-1 -0.5,-1.5 -0.2,-0.5 -0.3,-0.9 -0.4,-1.4 -0.1,-0.4 -0.2,-0.8 -0.3,-1.1 -0.1,0.3 -0.2,0.6 -0.3,1.1 -0.1,0.4 -0.3,0.9 -0.4,1.4 -0.2,0.5 -0.3,1 -0.5,1.6 -0.2,0.5 -0.4,1 -0.5,1.5 l -3,9 h 9.5 z" /><path d="m 293.8,21.8 v 10.9 h -3.1 V 21.8 L 281.3,5.2 h 3.5 l 4.4,7.9 c 0.6,1 1.1,2 1.7,3.1 0.6,1.1 1,2 1.4,2.8 0.4,-0.8 0.9,-1.8 1.4,-2.8 0.6,-1.1 1.1,-2.1 1.7,-3.1 l 4.4,-7.9 h 3.4 z" /></g></g><g data-name="Layer 1" transform="matrix(0.39457959,0,0,0.39457959,1.0823681,0.10489944)"><circle r="50" cy="50" cx="50" class="cls-1" style="fill:#d71e00" /><path d="M 85.36,14.64 A 50.006592,50.006592 0 0 1 14.64,85.36 Z" class="cls-2" style="fill:#c21a00" /><polygon points="54.54,49.99 69.6,81.86 56.77,81.86 41.72,49.99 56.77,18.14 69.6,18.14 " class="cls-3" style="fill:#ffffff" /><polygon points="69.6,81.86 84.65,49.99 69.6,18.14 63.19,31.7 71.83,49.99 63.19,68.29 " class="cls-4" style="fill:#b7b7b7" /><polygon points="28.17,49.99 43.23,81.86 30.4,81.86 15.35,49.99 30.4,18.14 43.23,18.14 " class="cls-3" style="fill:#ffffff" /><polygon points="43.59,46.04 50,32.47 43.23,18.14 36.81,31.71 " class="cls-4" style="fill:#b7b7b7" /><polygon points="36.81,68.29 43.23,81.86 50,67.53 43.59,53.96 " class="cls-4" style="fill:#b7b7b7" /></g></svg></span></div>
  </div>
  <div class="pf-v6-c-masthead__content" id="qp-head"><span class="qp-sub">Loading this run...</span></div>
</header>
<main class="qp-main" id="qp-main"></main>
<script>
// Toggle PatternFly accordion items and expandable sections.
document.addEventListener('click', function (e) {
  var b = e.target.closest('.pf-v6-c-accordion__toggle, .pf-v6-c-expandable-section__toggle button');
  if (!b) return;
  var box = b.closest('.pf-v6-c-accordion__item, .pf-v6-c-expandable-section');
  var open = box.classList.toggle('pf-m-expanded');
  b.setAttribute('aria-expanded', open);
  box.querySelector('.pf-v6-c-accordion__expandable-content, .pf-v6-c-expandable-section__content').hidden = !open;
});

(function () {
'use strict';
var API = 'https://storage.googleapis.com/storage/v1/b/' + RUN.bucket + '/o';
var WEB = 'https://gcs.ci.openshift.org/gcs/' + RUN.bucket + '/' + RUN.path + '/';
var PROW = 'https://prow.ci.openshift.org/view/gs/' + RUN.bucket + '/' + RUN.path;

// CI replaces a file it redacts with a 76-byte notice; real logs can be that short too.
var REDACTED_SIZE = 76;

var ICON_OK = '<svg class="qp-ok" fill="currentColor" viewBox="0 0 32 32" width="14" height="14" aria-hidden="true"><path d="M16 1C7.729 1 1 7.729 1 16s6.729 15 15 15 15-6.729 15-15S24.271 1 16 1Zm7.795 11.795-8.646 8.646c-.317.317-.733.475-1.149.475s-.832-.158-1.149-.475l-4.646-4.646a1.126 1.126 0 0 1 1.591-1.591l4.205 4.205 8.205-8.205a1.126 1.126 0 0 1 1.591 1.591Z"/></svg>';
var ICON_BAD = '<svg class="qp-bad" fill="currentColor" viewBox="0 0 32 32" width="14" height="14" aria-hidden="true"><path d="M16 1C7.729 1 1 7.729 1 16s6.729 15 15 15 15-6.729 15-15S24.271 1 16 1Zm-1.5 8a1.5 1.5 0 1 1 3 0v7a1.5 1.5 0 1 1-3 0V9ZM16 25.001a2 2 0 1 1-.001-3.999A2 2 0 0 1 16 25.001Z"/></svg>';
var ICON_ALERT = ICON_BAD.replace('class="qp-bad"', 'class="pf-v6-svg"').replace(/ width="14" height="14"/, ' width="1em" height="1em"');
var CHEVRON = '<svg class="pf-v6-svg" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true" width="1em" height="1em"><path d="M18.71 5.29a.996.996 0 0 0-1.41 0l-7.29 7.29-7.3-7.29a.987.987 0 0 0-1.41-.02.987.987 0 0 0-.02 1.41l.02.02 7.65 7.65c.29.29.68.44 1.06.44s.77-.15 1.06-.44l7.65-7.65a.996.996 0 0 0 0-1.41Z"/></svg>';

// ---- GCS access. Every name below is relative to the run's directory. ----
var files = new Map();   // object name -> size
var dirs = new Set();    // "a/b/" for every directory known to hold an object

function addFile(name, size) {
  files.set(name, size);
  for (var i = name.indexOf('/'); i >= 0; i = name.indexOf('/', i + 1)) dirs.add(name.slice(0, i + 1));
}
function has(rel) { return rel.slice(-1) === '/' ? dirs.has(rel) : files.has(rel); }

function media(rel) {
  return fetch(API + '/' + encodeURIComponent(RUN.path + '/' + rel) + '?alt=media').then(function (r) {
    if (!r.ok) throw new Error(rel + ': HTTP ' + r.status);
    return r;
  });
}
function text(rel) { return media(rel).then(function (r) { return r.text(); }); }
function json(rel) { return media(rel).then(function (r) { return r.json(); }); }
function opt(p) { return p.catch(function () { return null; }); }

// Lists objects under rel; extra carries delimiter or matchGlob. Records what it finds.
async function list(rel, extra) {
  var token = '', cut = RUN.path.length + 1;
  do {
    var q = new URLSearchParams({ prefix: RUN.path + '/' + rel, fields: 'items(name,size),prefixes,nextPageToken' });
    Object.keys(extra || {}).forEach(function (k) { q.set(k, extra[k]); });
    if (token) q.set('pageToken', token);
    var r = await fetch(API + '?' + q);
    if (!r.ok) throw new Error('list ' + rel + ': HTTP ' + r.status);
    var d = await r.json();
    (d.items || []).forEach(function (i) { addFile(i.name.slice(cut), +i.size); });
    (d.prefixes || []).forEach(function (p) { dirs.add(p.slice(cut)); });
    token = d.nextPageToken || '';
  } while (token);
}
function listDir(rel) { return opt(list(rel, { delimiter: '/' })); }

// ---- Formatting. ----
// Prow's html lens puts this file in a srcdoc attribute escaping only '"', so
// the browser decodes any character reference here once. Keep the file free of
// them: build references at runtime and write other characters as \u escapes.
function esc(s) {
  return String(s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; });
}
function a(rel, label) {
  return has(rel) ? '<a href="' + esc(WEB + rel) + '" target="_blank">' + label + '</a>' : label;
}
function hms(t) { return new Date(t).toISOString().slice(11, 19); }
function dur(ms) {
  var s = Math.round(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60;
  return (h ? h + 'h' + m + 'm' : m ? m + 'm' : '') + (s % 60) + 's';
}
function span(t1, t2) { return hms(t1) + '\u2013<wbr>' + hms(t2); }
function plural(n, one, many) { return n + ' ' + (n === 1 ? one : (many || one + 's')); }
function words(s) { return esc(s).split(' ').map(function (w) { return '<span class="qp-nw">' + w + '</span>'; }).join(' '); }
function label(color, s) {
  return '<span class="pf-v6-c-label pf-m-' + color + '"><span class="pf-v6-c-label__content"><span class="pf-v6-c-label__text">' + esc(s) + '</span></span></span>';
}
function card(title, sub, body, footer) {
  return '<div class="pf-v6-c-card pf-m-compact"><div class="pf-v6-c-card__title"><h2 class="pf-v6-c-card__title-text">' + title +
    (sub ? ' <span class="qp-sub">' + sub + '</span>' : '') + '</h2></div><div class="pf-v6-c-card__body">' + body + '</div>' +
    (footer ? '<div class="pf-v6-c-card__footer qp-sub">' + footer + '</div>' : '') + '</div>';
}
function table(aria, rows, head) {
  var th = function (c) { return '<th class="pf-v6-c-table__th" scope="col">' + c + '</th>'; };
  var tr = function (r) { return '<tr class="pf-v6-c-table__tr">' + r.map(function (c, i) {
    return i === 0 && head && head.rowHeaders ? '<th class="pf-v6-c-table__th" scope="row">' + c + '</th>' : '<td class="pf-v6-c-table__td">' + c + '</td>';
  }).join('') + '</tr>'; };
  return '<table class="pf-v6-c-table pf-m-compact' + (head ? '' : ' pf-m-no-border-rows') + '" aria-label="' + aria + '">' +
    (head && head.cols ? '<thead class="pf-v6-c-table__thead"><tr class="pf-v6-c-table__tr">' + head.cols.map(th).join('') + '</tr></thead>' : '') +
    '<tbody class="pf-v6-c-table__tbody">' + rows.map(tr).join('') + '</tbody></table>';
}
function expandable(title, body) {
  return '<div class="pf-v6-c-expandable-section"><div class="pf-v6-c-expandable-section__toggle"><button class="pf-v6-c-button pf-m-link" type="button" aria-expanded="false">' +
    '<span class="pf-v6-c-button__icon pf-m-start"><span class="pf-v6-c-expandable-section__toggle-icon">' + CHEVRON + '</span></span>' +
    '<span class="pf-v6-c-button__text">' + title + '</span></button></div><div class="pf-v6-c-expandable-section__content" hidden>' + body + '</div></div>';
}
function accordionItem(title, body, open) {
  return '<div class="pf-v6-c-accordion__item' + (open ? ' pf-m-expanded' : '') + '"><h3><button class="pf-v6-c-accordion__toggle" type="button" aria-expanded="' + !!open + '">' +
    '<span class="pf-v6-c-accordion__toggle-text">' + title + '</span><span class="pf-v6-c-accordion__toggle-icon">' + CHEVRON + '</span></button></h3>' +
    '<div class="pf-v6-c-accordion__expandable-content"' + (open ? '' : ' hidden') + '><div class="pf-v6-c-accordion__expandable-content-body">' + body + '</div></div></div>';
}

// ---- Pipeline model. ----
var PHASE_RE = /Running multi-stage phase (\w+)/, STEP_RE = /^Running step (.+)\.$/;

// Maps "<test>-<step>" pod names to their phase from ci-operator.log.
function phases(log) {
  var out = {}, phase = '';
  (log || '').split('\n').forEach(function (line) {
    var m, msg;
    try { msg = JSON.parse(line).msg || ''; } catch (e) { return; }
    if ((m = PHASE_RE.exec(msg))) phase = m[1];
    else if ((m = STEP_RE.exec(msg))) out[m[1]] = phase;
  });
  return out;
}

// Consecutive steps of one phase that share a stage name become one node.
// Pre: configuration up to the last conf/provision step, then the install
// (with the ipi-install-* steps around it), then verification.
function stageName(step, phase, seen, pre, i) {
  if (phase === 'pre') {
    if (pre.install < 0) return 'Set up cluster';
    if (i < pre.split) return 'Configure cluster';
    if (i <= pre.installEnd) return 'Install OpenShift';
    return 'Verify cluster';
  }
  if (phase === 'post') {
    // quay-* post steps (incl. quay-deprovision) run before cluster teardown; keep them one node.
    if (/^quay-/.test(step.name)) return 'Quay gather';
    if (/^gather-/.test(step.name)) return 'Cluster gather';
    if (/deprovision/.test(step.name)) return 'Deprovision';
    return 'Post steps';
  }
  if (/^quay-test-/.test(step.name)) return step.name;
  return seen.test ? 'More test steps' : 'Deploy Quay';
}

function stages(test, phaseOf) {
  var steps = test.substeps.map(function (s) {
    var name = s.name.indexOf(test.name + '-') === 0 ? s.name.slice(test.name.length + 1) : s.name;
    return { name: name, phase: phaseOf[s.name] || 'test', start: s.started_at, end: s.finished_at, failed: !!s.failed };
  });
  var pre = steps.filter(function (s) { return s.phase === 'pre'; });
  var bounds = { install: pre.findIndex(function (s) { return /install-install$/.test(s.name); }), split: 0 };
  pre.forEach(function (s, i) { if (i < bounds.install && /conf|provision/.test(s.name)) bounds.split = i + 1; });
  for (bounds.installEnd = bounds.install; bounds.installEnd + 1 < pre.length && /^ipi-install-/.test(pre[bounds.installEnd + 1].name); bounds.installEnd++);
  var out = [], seen = { test: false }, preIdx = 0;
  steps.forEach(function (s) {
    var n = stageName(s, s.phase, seen, bounds, s.phase === 'pre' ? preIdx++ : 0);
    if (s.phase === 'test' && /^quay-test-/.test(s.name)) seen.test = true;
    var last = out[out.length - 1];
    if (last && last.name === n && last.phase === s.phase && n !== s.name) last.steps.push(s);
    else out.push({ name: n, phase: s.phase, steps: [s] });
  });
  out.forEach(function (g) {
    g.start = g.steps[0].start;
    g.end = g.steps[g.steps.length - 1].end;
    g.failedSteps = g.steps.filter(function (s) { return s.failed; });
    g.main = g.failedSteps[0] || g.steps.find(function (s) { return s.name === 'quay-gather'; }) || g.steps.reduce(function (m, s) { return Date.parse(s.end) - Date.parse(s.start) > Date.parse(m.end) - Date.parse(m.start) ? s : m; });
  });
  return { steps: steps, groups: out };
}

function node(o) {
  return '<a class="qp-node' + (o.failed ? ' qp-failed' : '') + '"' + (o.href ? ' href="' + esc(o.href) + '" target="_blank"' : '') + '><b>' +
    words(o.title).replace('<span class="qp-nw">', '<span class="qp-nw">' + (o.failed ? ICON_BAD : ICON_OK) + ' ') + '</b>' + (o.sub ? '<small>' + o.sub + '</small>' : '') +
    (o.start && o.end ? '<small>' + span(o.start, o.end) + '</small><small>' + dur(Date.parse(o.end) - Date.parse(o.start)) + '</small>' : '') + '</a>';
}
function stepHref(T, s) {
  var dir = 'artifacts/' + T + '/' + s.name + '/';
  if (s.failed && has(dir + 'artifacts/')) return WEB + dir + 'artifacts/';
  if (has(dir + 'build-log.txt')) return WEB + dir + 'build-log.txt';
  return has(dir) ? WEB + dir : null;
}

// ---- Quay health. ----
function registry(list) {
  var items = (list && list.items) || [];
  return items.find(function (i) { return i.metadata.name === 'quay'; }) || items[0] || null;
}
function cond(reg, type) {
  return ((reg && reg.status && reg.status.conditions) || []).find(function (c) { return c.type === type; });
}
function components(reg) {
  var n = { ready: 0, unmanaged: 0, bad: [] };
  ((reg && reg.status && reg.status.conditions) || []).forEach(function (c) {
    if (!/^Component.+Ready$/.test(c.type)) return;
    if (c.reason === 'ComponentNotManaged') n.unmanaged++;
    else if (c.status === 'True') n.ready++;
    else n.bad.push(c.type.replace(/^Component|Ready$/g, ''));
  });
  return n.ready + ' ready, ' + n.unmanaged + ' not managed' + (n.bad.length ? '; <span class="qp-bad">not ready: ' + esc(n.bad.join(', ')) + '</span>' : '');
}
// Summarizes `oc get pods` output: status counts and restarted pods.
function pods(txt) {
  if (!txt) return null;
  var rows = txt.trim().split('\n').slice(1).map(function (l) { return l.trim().split(/\s+/); }).filter(function (r) { return r.length >= 4; });
  var counts = {}, restarted = [];
  rows.forEach(function (r) {
    counts[r[2]] = (counts[r[2]] || 0) + 1;
    var n = parseInt(r[3], 10);
    if (n > 0) restarted.push(r[0].replace(/(-[a-z0-9]{8,10})?-[a-z0-9]{5}$/, '') + ' restarted ' + (n === 1 ? 'once' : n + ' times'));
  });
  return { n: rows.length, text: Object.keys(counts).map(function (k) { return counts[k] + ' ' + esc(k); }).join(', ') + (restarted.length ? '; ' + esc(restarted.join(', ')) : '') };
}
function condCell(c) {
  if (!c) return '<span class="qp-sub">not reported</span>';
  var good = (c.type === 'RolloutBlocked') ? c.status === 'False' : c.status === 'True';
  return '<span class="' + (good ? 'qp-ok' : 'qp-bad') + '">' + esc(c.status) + '</span> <span class="qp-sub">' + esc(c.reason || '') + '</span>';
}

// ---- Render. ----
// Write to the DOM only once the PatternFly stylesheet has loaded: Prow sizes
// the iframe on DOM mutations, not on a stylesheet load.
var css = document.querySelector('link[rel=stylesheet]');
var cssReady = css.sheet ? Promise.resolve() : new Promise(function (ok) { css.addEventListener('load', ok); css.addEventListener('error', ok); });

async function main() {
  var head = document.getElementById('qp-head'), out = document.getElementById('qp-main');
  var base = await Promise.all([
    opt(json('started.json')), opt(json('finished.json')), opt(json('prowjob.json')), opt(json('clone-records.json')),
    opt(json('artifacts/ci-operator-step-graph.json')), opt(text('artifacts/ci-operator.log')), opt(text('artifacts/junit_operator.xml')),
    listDir(''), listDir('artifacts/'), listDir('artifacts/build-logs/')
  ]);
  var started = base[0], finished = base[1], pj = base[2], clones = base[3], graph = base[4], log = base[5], junitOp = base[6];
  await cssReady;
  var build = RUN.path.split('/').pop();
  var type = (pj && pj.spec && pj.spec.type) || 'job';
  var result = finished ? finished.result || (finished.passed ? 'SUCCESS' : 'FAILURE') : 'PENDING';
  var badge = result === 'SUCCESS' ? label('success', 'Passed') : result === 'FAILURE' ? label('danger', 'Failed') : label(result === 'PENDING' ? 'blue' : 'orange', result.charAt(0) + result.slice(1).toLowerCase());
  head.innerHTML = badge + '\u00a0 <span class="qp-sub">' + esc(type.charAt(0).toUpperCase() + type.slice(1)) + ' job run \u00b7 build ' + esc(build) + '</span>';

  var test = graph && (graph.find(function (n) { return n.substeps && n.name === RUN.test; }) || graph.find(function (n) { return n.substeps; }));
  if (!finished || !test) {
    out.innerHTML = '<div class="pf-v6-c-alert pf-m-info pf-m-inline"><p class="pf-v6-c-alert__title">' +
      (finished ? 'This run has no multi-stage step graph to draw.' : 'This page renders once the job finishes and ci-operator uploads its step graph.') +
      '</p><div class="pf-v6-c-alert__description"><a href="' + esc(PROW) + '" target="_blank">Prow job page</a></div></div>';
    return;
  }
  var T = test.name, S = 'artifacts/' + T + '/';
  var model = stages(test, phases(log));
  var failedSteps = model.steps.filter(function (s) { return s.failed; });
  var names = model.steps.map(function (s) { return s.name; });
  var e2e = names.filter(function (n) { return /^quay-test-/.test(n); });
  var deploy = model.steps.filter(function (s) { return s.phase === 'test' && /^quay-deploy-/.test(s.name) && !/mailpit|jaeger/.test(s.name); }).pop();
  var gather = model.steps.find(function (s) { return s.name === 'quay-gather'; });

  var wanted = ['gather-extra', 'gather-must-gather', 'gather-audit-logs', 'ipi-install-install']
    .concat(e2e, failedSteps.map(function (s) { return s.name; }), deploy ? [deploy.name] : [])
    .filter(function (n, i, arr) { return names.indexOf(n) >= 0 && arr.indexOf(n) === i; });
  await Promise.all([
    opt(list(S, { matchGlob: RUN.path + '/' + S + '*/build-log.txt' })),
    gather ? opt(list(S + 'quay-gather/artifacts/')) : null
  ].concat(wanted.map(function (n) { return listDir(S + n + '/artifacts/'); })));

  var finalReg = registry(gather && await opt(json(S + 'quay-gather/artifacts/quayregistries.json')));
  var ns = finalReg ? finalReg.metadata.namespace : 'quay-enterprise';
  var startJson = deploy && S + deploy.name + '/artifacts/quayregistries.json';
  var extra = await Promise.all([
    startJson && has(startJson) ? opt(json(startJson)) : null,
    deploy && has(S + deploy.name + '/artifacts/pods_status.txt') ? opt(text(S + deploy.name + '/artifacts/pods_status.txt')) : null,
    gather && has(S + 'quay-gather/artifacts/' + ns + '/pods.txt') ? opt(text(S + 'quay-gather/artifacts/' + ns + '/pods.txt')) : null,
    e2e[0] && has(S + e2e[0] + '/artifacts/junit_playwright.xml') ? opt(text(S + e2e[0] + '/artifacts/junit_playwright.xml')) : null
  ]);
  var startReg = registry(extra[0]), startPods = pods(extra[1]), finalPods = pods(extra[2]);
  var pw = null;
  if (extra[3]) {
    var root = (/<testsuites\b[^>]*>/.exec(extra[3]) || [''])[0];
    var attr = function (k) { var m = new RegExp('\\b' + k + '="(\\d+)"').exec(root); return m ? +m[1] : 0; };
    pw = { tests: attr('tests'), failed: attr('failures') + attr('errors'), skipped: attr('skipped') };
  }
  var sections = [];

  // Summary card.
  var src = (clones || []).find(function (c) { return c.refs && c.refs.org; });
  var title = src ? esc(src.refs.org + '/' + src.refs.repo + ' ' + src.refs.base_ref) + ' \u00b7 ' + esc(T) : esc(T);
  var variant = pj && pj.metadata && pj.metadata.labels && pj.metadata.labels['ci-operator.openshift.io/variant'];
  var count = { pre: 0, test: 0, post: 0 };
  model.steps.forEach(function (s) { count[s.phase] = (count[s.phase] || 0) + 1; });
  var dl = function (k, v) {
    return '<div class="pf-v6-c-description-list__group"><dt class="pf-v6-c-description-list__term"><span class="pf-v6-c-description-list__text">' + k +
      '</span></dt><dd class="pf-v6-c-description-list__description"><div class="pf-v6-c-description-list__text">' + v + '</div></dd></div>';
  };
  var t0 = started ? started.timestamp * 1000 : Date.parse(graph.map(function (n) { return n.started_at; }).sort()[0]), t1 = finished.timestamp * 1000;
  sections.push('<div class="pf-v6-c-card pf-m-compact"><div class="pf-v6-c-card__title"><h1 class="pf-v6-c-card__title-text">' + title +
    (variant ? ' <span class="qp-sub">variant ' + esc(variant) + '</span>' : '') + '</h1></div><div class="pf-v6-c-card__body">' +
    '<dl class="pf-v6-c-description-list pf-m-compact pf-m-horizontal pf-m-2-col pf-m-3-col-on-lg">' +
    dl('Started', new Date(t0).toISOString().slice(0, 19).replace('T', ' ') + ' UTC') + dl('Finished', hms(t1) + ' UTC') + dl('Total', '<b>' + dur(t1 - t0) + '</b>') +
    dl('Commit', src && src.final_sha ? '<a href="https://github.com/' + esc(src.refs.org + '/' + src.refs.repo) + '/commit/' + esc(src.final_sha) + '" target="_blank"><code>' + esc(src.final_sha.slice(0, 7)) + '</code></a>' : '\u2014') +
    dl('Steps', model.steps.length + ': ' + count.pre + ' pre, ' + count.test + ' test, ' + count.post + ' post') +
    dl('Job', '<a href="' + esc(PROW) + '" target="_blank">Prow</a> \u00b7 ' + a('artifacts/', 'artifacts') + ' \u00b7 ' + a('artifacts/ci-operator.log', 'ci-operator.log')) +
    '</dl></div></div>');

  // Failure alert.
  var startAvail = cond(startReg, 'Available'), finalAvail = cond(finalReg, 'Available');
  var avail = startAvail && finalAvail ? (startAvail.status === 'True' && finalAvail.status === 'True' ? 'Quay stayed Available from START to FINAL.' :
    'Quay Available: ' + esc(startAvail.status) + ' at START, ' + esc(finalAvail.status) + ' at FINAL.') : '';
  if (result !== 'SUCCESS') {
    var f = failedSteps[0], body = [], actions = [];
    var titleText;
    if (f) {
      var tc = junitOp ? Array.from(new DOMParser().parseFromString(junitOp, 'text/xml').querySelectorAll('testcase'))
        .find(function (t) { return t.getAttribute('name') === 'Run multi-stage step ' + f.name; }) : null;
      var failure = tc && tc.querySelector('failure');
      var tail = failure ? failure.textContent : '';
      var exit = /exit status (\d+)/.exec(tail);
      titleText = esc(f.name) + ' failed' + (exit ? ': exit ' + exit[1] : '') + ' after ' + dur(Date.parse(f.end) - Date.parse(f.start)) + ' (' + hms(f.start) + '\u2013' + hms(f.end) + ')';
      if (pw && e2e.indexOf(f.name) >= 0) body.push('Playwright: <b>' + pw.failed + ' failed</b>, ' + pw.skipped + ' skipped, ' + pw.tests + ' total.');
      var bl = S + f.name + '/build-log.txt';
      if (files.get(bl) === REDACTED_SIZE) body.push('The step\'s build-log.txt was redacted by CI (a ' + files.get(bl) + '-byte placeholder); the tail of its output is in junit_operator.xml.');
      var after = model.steps.filter(function (s) { return s.phase === 'post' && Date.parse(s.start) >= Date.parse(f.end); });
      var afterBad = after.filter(function (s) { return s.failed; });
      var more = failedSteps.slice(1).map(function (s) { return esc(s.name); });
      body.push((more.length ? 'Also failed: ' + more.join(', ') + '. ' : '') +
        (after.length ? plural(after.length, 'post step') + ' ran after it' + (afterBad.length ? '; ' + afterBad.length + ' failed.' : ' and passed.') : 'No post steps ran after it.') +
        (avail ? ' ' + avail : ''));
      if (pw && e2e.indexOf(f.name) >= 0 && has(S + f.name + '/artifacts/index.html')) actions.push([S + f.name + '/artifacts/index.html', 'Playwright report']);
      if (pw && e2e.indexOf(f.name) >= 0) actions.push([S + f.name + '/artifacts/junit_playwright.xml', 'junit_playwright.xml']);
      actions.push([S + f.name + '/artifacts/', 'Step artifacts'], [bl, 'build-log.txt'], ['artifacts/junit_operator.xml', 'junit_operator.xml']);
      if (tail) body.push(expandable('Step output tail (junit_operator.xml)', '<pre class="qp-tail">' + esc(tail.trim().split('\n').slice(-40).join('\n')) + '</pre>'));
    } else {
      titleText = 'Job result ' + esc(result) + ' with no failed step in the step graph';
      actions.push(['build-log.txt', 'Job build-log.txt'], ['artifacts/ci-operator.log', 'ci-operator.log']);
    }
    sections.push('<div class="pf-v6-c-alert pf-m-danger pf-m-inline" aria-label="Failure"><div class="pf-v6-c-alert__icon">' + ICON_ALERT + '</div>' +
      '<p class="pf-v6-c-alert__title">' + titleText + '</p><div class="pf-v6-c-alert__description pf-v6-c-content">' +
      body.map(function (p) { return p.indexOf('<div') === 0 ? p : '<p>' + p + '</p>'; }).join('') + '</div><div class="pf-v6-c-alert__action-group">' +
      actions.filter(function (x) { return has(x[0]); }).map(function (x) {
        return '<a class="pf-v6-c-button pf-m-inline pf-m-link" href="' + esc(WEB + x[0]) + '" target="_blank"><span class="pf-v6-c-button__text">' + x[1] + '</span></a>';
      }).join('') + '</div></div>');
  }

  // Pipeline graph: setup lanes, then one node per stage.
  var lanes = [];
  var inputs = graph.filter(function (n) { return /^\[input:/.test(n.name); });
  if (inputs.length) {
    lanes.push([node({ title: plural(inputs.length, 'input image'), failed: inputs.some(function (n) { return n.failed; }), href: has('artifacts/ci-operator.log') ? WEB + 'artifacts/ci-operator.log' : null,
      start: inputs.map(function (n) { return n.started_at; }).sort()[0], end: inputs.map(function (n) { return n.finished_at; }).sort().pop() })]);
  }
  graph.filter(function (n) { return /^\[release:/.test(n.name); }).forEach(function (n) {
    lanes.push([node({ title: n.name.slice(1, -1), failed: n.failed, href: has('artifacts/release/') ? WEB + 'artifacts/release/' : null, start: n.started_at, end: n.finished_at })]);
  });
  var builds = graph.filter(function (n) { return !/^\[/.test(n.name) && !n.substeps && n.name !== 'lease-proxy-server' && n.finished_at && n.started_at !== n.finished_at; })
    .sort(function (x, y) { return Date.parse(x.started_at) - Date.parse(y.started_at); });
  if (builds.length) {
    lanes.push(builds.map(function (n) {
      var logRel = 'artifacts/build-logs/' + n.name + '-amd64.log';
      return node({ title: n.name, failed: n.failed, href: has(logRel) ? WEB + logRel : null, start: n.started_at, end: n.finished_at });
    }));
  }
  var g = [];
  if (lanes.length) g.push('<div class="qp-par">' + lanes.map(function (l) { return '<div class="qp-lane">' + l.join('<span class="qp-edge"></span>') + '</div>'; }).join('') + '</div>');
  var failedBefore = false;
  model.groups.forEach(function (grp) {
    if (g.length) g.push('<span class="qp-edge' + (failedBefore && grp.phase === 'post' ? ' qp-after-fail' : '') + '"></span>');
    if (grp.phase === 'post') failedBefore = false;
    var single = grp.steps.length === 1 && grp.name === grp.steps[0].name;
    var sub = grp.phase + ' \u00b7 ' + (single ? (grp.failedSteps.length ? 'failed' : 'step') : plural(grp.steps.length, 'step').replace(' ', '\u00a0')) +
      (grp.failedSteps.length && !single ? ' \u00b7 ' + esc(grp.failedSteps[0].name) + ' failed' : '');
    g.push(node({ title: grp.name, sub: sub, failed: grp.failedSteps.length > 0, href: stepHref(T, grp.main), start: grp.start, end: grp.end }));
    if (grp.failedSteps.length && grp.phase !== 'post') failedBefore = true;
  });
  var mains = model.groups.filter(function (x) { return x.steps.length > 1; }).map(function (x) { return esc(x.main.name); });
  sections.push(card('Pipeline', 'times UTC', '<div class="qp-graph">' + g.join('') + '</div>',
    (mains.length ? 'Stage nodes link to their longest or failed step: ' + mains.join(', ') + '. ' : '') +
    'Every step has its own directory under ' + a(S, esc(T) + '/') + '.' +
    (failedSteps.some(function (s) { return s.phase !== 'post'; }) ? ' The dashed edge is the post phase running after the failure.' : '')));

  // Quay health: START (after the deploy step) vs FINAL (quay-gather).
  if (startReg || finalReg || startPods || finalPods) {
    var col = function (reg, podsum) {
      return [reg && reg.status ? esc(reg.status.currentVersion || '') : '', reg ? condCell(cond(reg, 'Available')) : '', reg ? condCell(cond(reg, 'RolloutBlocked')) : '',
        reg ? components(reg) : '', podsum ? podsum.text : ''].map(function (v) { return v || '<span class="qp-sub">not captured</span>'; });
    };
    var sc = col(startReg, startPods), fc = col(finalReg, finalPods);
    var podN = (finalPods || startPods || { n: 0 }).n;
    var dstep = deploy ? S + deploy.name + '/artifacts/' : '', gstep = S + 'quay-gather/artifacts/';
    var rows = [['Version', sc[0], fc[0]], ['Available', sc[1], fc[1]], ['RolloutBlocked', sc[2], fc[2]], ['Components', sc[3], fc[3]], ['Pods (' + podN + ')', sc[4], fc[4]],
      ['Source', [a(dstep + 'quayregistries.json', 'quayregistries.json'), a(dstep + 'quayregistries.yaml', 'quayregistries.yaml'), a(dstep + 'pods_status.txt', 'pods_status.txt')]
        .filter(function (x) { return x.indexOf('<a') === 0; }).join(' \u00b7 ') || '\u2014',
       [a(gstep + 'quayregistries.json', 'quayregistries.json'), a(gstep + ns + '/pods.txt', 'pods.txt')].filter(function (x) { return x.indexOf('<a') === 0; }).join(' \u00b7 ') || '\u2014']];
    var body = table('Quay health START vs FINAL', rows, { rowHeaders: true, cols: ['',
      'START <span class="qp-sub">' + (deploy ? 'after ' + esc(deploy.name) + ', ' + hms(deploy.end) : 'no deploy step') + '</span>',
      'FINAL <span class="qp-sub">' + (gather ? 'quay-gather, ' + hms(gather.start) : 'no quay-gather step') + '</span>'] });
    var fconds = (finalReg && finalReg.status && finalReg.status.conditions) || [], sconds = (startReg && startReg.status && startReg.status.conditions) || [];
    var key = function (c) { return c.type + '|' + c.status + '|' + (c.reason || ''); };
    var same = startReg && fconds.length === sconds.length && fconds.every(function (c) { var s = cond(startReg, c.type); return s && key(s) === key(c); });
    var conds = fconds.length ? fconds : sconds;
    if (conds.length) {
      var ctab = same || !startReg || !finalReg ?
        table('QuayRegistry conditions', conds.map(function (c) { return [esc(c.type), esc(c.status), esc(c.reason || '')]; }), { cols: ['Type', 'Status', 'Reason'] }) :
        table('QuayRegistry conditions', conds.map(function (c) { return [esc(c.type), condCell(cond(startReg, c.type)), condCell(cond(finalReg, c.type))]; }), { cols: ['Type', 'START', 'FINAL'] });
      body += expandable('All ' + conds.length + ' QuayRegistry conditions' + (same ? ' (identical at START and FINAL)' : !startReg || !finalReg ? (finalReg ? ' (FINAL)' : ' (START)') : ' (START vs FINAL)'), ctab);
    }
    sections.push(card('Quay health', finalReg || startReg ? 'QuayRegistry ' + esc((finalReg || startReg).metadata.namespace + '/' + (finalReg || startReg).metadata.name) : '', body));
  }

  // Logs & artifacts. Rows whose target is missing from this run are dropped.
  var rowsOf = function (rows) { return rows.filter(function (r) { return has(r[0]); }).map(function (r) { return [a(r[0], r[1]), '<span class="qp-sub">' + r[2] + '</span>']; }); };
  var items = [];
  var logs = gather ? Array.from(files.keys()).filter(function (k) { return k.indexOf(gstep + ns + '/logs/') === 0; }) : [];
  // quay-gather names container logs <pod>-<container>.log.
  var pick = function (c) {
    return logs.filter(function (k) { return k.slice(-(c.length + 5)) === '-' + c + '.log'; }).map(function (k) { return [k, c, esc(k.split('/').pop().slice(0, -(c.length + 5)))]; });
  };
  var quayRows = rowsOf([].concat(pick('quay-operator'), pick('quay-app'), pick('quay-app-upgrade'), [
    [gstep + 'quayregistry-describe.txt', 'oc describe quayregistry', 'status, conditions, events'],
    [gstep + ns + '/events.txt', 'events', esc(ns) + ' namespace'],
    [gstep + 'olm-csvs.yaml', 'OLM CSVs', 'operator install state'],
    [gstep + ns + '/logs/', 'all ' + esc(ns) + ' logs', 'every pod in ' + esc(ns)]]));
  if (quayRows.length) items.push(accordionItem('Quay operator and app logs <span class="qp-sub">quay-gather, ' + hms(gather.start) + '</span>', table('Quay logs', quayRows), result !== 'SUCCESS'));

  var mg = S + 'gather-must-gather/artifacts/must-gather.tar', mgRedacted = files.get(mg) === REDACTED_SIZE;
  var clusterRows = rowsOf([
    [mg, 'must-gather.tar', mgRedacted ? 'Redacted by CI in this run: a ' + files.get(mg) + '-byte placeholder.' : 'full cluster must-gather'],
    [S + 'gather-extra/artifacts/', 'gather-extra', 'cluster resource dump, node and pod logs'],
    [S + 'gather-must-gather/artifacts/event-filter.html', 'event-filter.html', 'cluster events, filterable'],
    [S + 'gather-audit-logs/artifacts/', 'audit logs', 'API server audit logs'],
    [S + 'ipi-install-install/artifacts/', 'install artifacts', 'installer log and cluster metadata']]);
  if (clusterRows.length) items.push(accordionItem('Cluster state' + (mgRedacted ? ' <span class="pf-v6-c-label pf-m-compact pf-m-warning"><span class="pf-v6-c-label__content"><span class="pf-v6-c-label__text">must-gather redacted</span></span></span>' : ''), table('Cluster state', clusterRows)));

  var junits = Array.from(files.keys()).filter(function (k) { return k.indexOf(S) === 0 && /\/artifacts\/junit[^/]*\.xml$/.test(k); });
  var testRows = rowsOf([].concat(e2e.map(function (n) {
    return [S + n + '/artifacts/index.html', 'Playwright report', pw ? pw.tests + ' tests, ' + pw.failed + ' failed, ' + pw.skipped + ' skipped' : esc(n)];
  }), junits.map(function (k) { return [k, esc(k.split('/').pop()), esc(k.split('/')[2])]; }), [['artifacts/junit_operator.xml', 'junit_operator.xml', 'every ci-operator step, with output tails']]));
  if (testRows.length) items.push(accordionItem('Test results', table('Test results', testRows)));

  var buildRows = rowsOf([['artifacts/ci-operator.log', 'ci-operator.log', 'full ci-operator output']].concat(
    builds.map(function (n) { return ['artifacts/build-logs/' + n.name + '-amd64.log', esc(n.name) + ' build', dur(Date.parse(n.finished_at) - Date.parse(n.started_at))]; }),
    [['artifacts/release/', 'release import', 'release payload import logs'], [S, 'all step directories', plural(model.steps.length, 'step')]]));
  items.push(accordionItem('Job and image builds', table('Job and image builds', buildRows)));
  sections.push(card('Logs and artifacts', '', '<div class="pf-v6-c-accordion pf-m-bordered">' + items.join('') + '</div>'));

  out.innerHTML = sections.join('\n');
}

main().catch(function (e) {
  document.getElementById('qp-main').innerHTML = '<div class="pf-v6-c-alert pf-m-warning pf-m-inline"><p class="pf-v6-c-alert__title">Could not render this run: ' +
    esc(e.message) + '</p><div class="pf-v6-c-alert__description"><a href="' + esc(PROW) + '" target="_blank">Prow job page</a></div></div>';
});
})();
</script>
</body>
</html>
EOF
