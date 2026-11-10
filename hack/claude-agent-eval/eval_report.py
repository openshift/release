#!/usr/bin/env python3
"""Render evals-summary.json as self-contained HTML without model calls.

Usage: python3 eval_report.py evals-summary.json evals-summary.html
"""

import argparse
from html import escape
import json
from pathlib import Path, PurePosixPath
from string import Template
from urllib.parse import quote


HERE = Path(__file__).resolve().parent
# Spyglass embeds HTML in srcdoc, which otherwise resolves relative links against
# /spyglass/static/html/. Its lens request and document index identify the actual
# artifact, including the bucket and step directory. Outside that lens, retain
# relative links so downloaded artifact bundles still work.
PROW_ARTIFACT_LINKS = r'''<script>
(() => {
  try {
    if (!window.frameElement) return;
    const lens = new URL(window.parent.location.href);
    if (lens.pathname !== "/spyglass/lens/html/iframe") return;
    const request = JSON.parse(lens.searchParams.get("req"));
    const index = window.frameElement.id.match(/-(\d+)$/);
    if (!index || !request || !Array.isArray(request.artifacts)) return;
    const artifact = request.artifacts[Number(index[1])];
    if (typeof artifact !== "string" || !artifact.endsWith("/evals-summary.html")
        || typeof request.src !== "string" || !request.src.startsWith("gs/")) return;
    const path = request.src.slice(3) + "/" + artifact;
    const report = new URL("https://gcs.ci.openshift.org/gcs/"
      + path.split("/").map(encodeURIComponent).join("/"));
    for (const link of document.querySelectorAll("a[href]")) {
      link.href = new URL(link.getAttribute("href"), report).href;
      // Open outside the sandboxed report iframe; the artifact browser handles
      // both individual files and directory listings.
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    }
  } catch (error) {
    console.warn("Cannot resolve Prow artifact links", error);
  }
})();
</script>'''


LABELS = {"passed": ("pass", "Passed"), "failed": ("fail", "Failed"),
          "not_run": ("skip", "Not run"), "no_evals": ("skip", "No evals selected")}


def badge(status):
    """Use a fixed status vocabulary for both labels and CSS classes."""
    style, label = LABELS[status]
    return f'<span class="{style}">{label}</span>'


def artifact_link(path, label):
    """Escape display text and encode relative artifact paths as URLs."""
    if not path or path.startswith("/") or "\\" in path or ".." in PurePosixPath(path).parts:
        raise ValueError("artifact links must be relative paths inside the artifact directory")
    return f'<a href="{quote(path)}">{escape(label)}</a>'


def eval_card(entry):
    """Present a verdict and available files without interpreting harness results."""
    links = [artifact_link(path, name) for name, path in entry["artifacts"].items()]
    if entry["artifact_dir"]:
        links.append(artifact_link(entry["artifact_dir"], "All artifacts"))
    failure = (f'<p class="failure">{escape(entry["failure"])}</p>' if entry["failure"] else "")
    run = escape(entry["run_id"] or "Not started")
    return ('<section class="section"><div class="eval-heading">'
            f'<h2>{escape(entry["config"])}</h2>{badge(entry["status"])}</div>'
            f'<p class="run-id">RUN <code>{run}</code></p>{failure}'
            + ('<nav class="artifact-links" aria-label="Eval artifacts">' + "".join(links) + '</nav>'
               if links else '<p class="report-note">No artifacts available.</p>') + '</section>')


def render_report(summary, *, link_json=True):
    """Only format schema v1 data; no filesystem scanning or model evaluation."""
    if summary.get("schema_version") != 1:
        raise ValueError("unsupported eval summary schema_version")
    counts = summary["counts"]
    chips = ''.join('<span class="meta-chip"><span class="meta-label">'
                    f'{label}</span>{escape(str(counts[key]))}</span>'
                    for key, label in (("selected", "Evaluations"), ("passed", "Passed"),
                                       ("failed", "Failed"), ("not_run", "Not run")))
    links = [artifact_link("evals-summary.json", "JSON summary")] if link_json else []
    if log := summary["artifacts"].get("harness_install_log"):
        links.append(artifact_link(log, "Harness installation log"))
    body = ('<header class="report-header"><h1>Eval results</h1>'
            f'<div class="header-meta">{badge(summary["status"])}{chips}</div>'
            '<nav class="summary-links" aria-label="Summary artifacts">' + ' '.join(links)
            + '</nav></header>')
    if summary["errors"]:
        body += ('<section class="section runner-errors"><h2>Runner errors</h2><ul>'
                 + ''.join(f'<li>{escape(error)}</li>' for error in summary["errors"])
                 + '</ul></section>')
    body += ''.join(eval_card(entry) for entry in summary["evals"])
    if not summary["evals"]:
        body += '<section class="section"><p>No evaluations selected.</p></section>'
    body += '<p class="report-note">Summary of selected evals. Open each report for case-level results.</p>'
    return Template((HERE / "eval-report.html").read_text(encoding="utf-8")).substitute(
        styles=(HERE / "eval-report.css").read_text(encoding="utf-8"), body=body,
        artifact_links=PROW_ARTIFACT_LINKS)


def main():
    """Re-render a saved summary without running evaluations."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    summary = json.loads(args.summary.read_text(encoding="utf-8"))
    args.output.write_text(render_report(summary), encoding="utf-8")


if __name__ == "__main__":
    main()
