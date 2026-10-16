# Remove redundant Tide queries

Install the dependency and preview the evidence:

```sh
python3 -m pip install ruamel.yaml
python3 hack/tide/remove-redundant-queries.py --dry-run > /tmp/tide-evidence.md
```

Open the Markdown report to see each proposed removal, the retained covering
query's file and line, and a side-by-side criteria table. Apply the cleanup:

```sh
python3 hack/tide/remove-redundant-queries.py > /tmp/tide-evidence.md
git diff -- core-services/prow/02_config
```

Use `--config-dir PATH` to process a different directory. Queries are compared
across all YAML files, not just within each file. Query numbers and lines refer
to the input before editing.

A query is redundant when **every PR it matches also matches a retained query**.
The covering query may have fewer required or forbidden labels, broader repo
or branch scope, or fewer author, milestone, or review restrictions. This is
set containment; it does not depend on query order or assume which query Tide
processes first. Equivalent queries keep the first in sorted file/query order.
Partial overlap alone never causes a deletion. Coverage by the union of several
queries is not considered.

The comparison handles org-wide scope, excluded repositories, literal branch
names, and comma-separated OR alternatives within required label clauses, as
defined in [Prow's Tide implementation](https://github.com/kubernetes-sigs/prow/blob/main/pkg/config/tide.go).
Unsupported fields or malformed values stop processing before files are written.
Contradictory label clauses are left for separate investigation.

The script uses ruamel's YAML parser and source marks to remove complete query
blocks directly from the original text. Surviving text keeps its original
formatting, quotes, and comments; trailing comment lines are preserved. A file
losing every query retains `queries: []`. Every proposed file is parsed again
and compared against the original document with only the selected queries
removed, before any file is written. Unsupported layouts fail this check rather
than rewriting other configuration. Writes are not a transaction across files.
