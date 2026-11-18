{
  "https://api.github.com/repos/example/tool/releases?per_page=100": [
    {"tag_name": "v1.2.1", "draft": false, "prerelease": false},
    {"tag_name": "v1.3.0-rc.1", "draft": false, "prerelease": true},
    {"tag_name": "v1.4.0", "draft": true, "prerelease": false},
    {"tag_name": "v2.0.0", "draft": false, "prerelease": false}
  ],
  "https://api.github.com/repos/example/semver/releases?per_page=100": [
    {"tag_name": "v1.10.0", "draft": false, "prerelease": false},
    {"tag_name": "v1.11.0-rc.1", "draft": false, "prerelease": false},
    {"tag_name": "1.12.0", "draft": false, "prerelease": false},
    {"tag_name": "v2.0.0", "draft": false, "prerelease": false},
    {"tag_name": "v0.9.9", "draft": false, "prerelease": false}
  ],
  "https://api.github.com/repos/example/no-stable/releases?per_page=100": [
    {"tag_name": "v1.3.0-rc.1", "draft": false, "prerelease": false},
    {"tag_name": "v2.0.0", "draft": false, "prerelease": false}
  ],
  "https://api.github.com/repos/example/multipage/releases?per_page=2": [
    {"tag_name": "v1.1.0", "draft": false, "prerelease": false},
    {"tag_name": "v1.2.0", "draft": false, "prerelease": false}
  ],
  "https://api.github.com/repos/example/multipage/releases?per_page=2&page=2": [
    {"tag_name": "v1.3.0", "draft": false, "prerelease": false}
  ],
  "https://api.github.com/repos/golang/tools/tags?per_page=2": [
    {"name": "go1.26.0"},
    {"name": "gopls/v0.20.0"}
  ],
  "https://api.github.com/repos/golang/tools/tags?per_page=2&page=2": [
    {"name": "gopls/v0.21.2"}
  ],
  "https://api.github.com/repos/example/page-error/tags?per_page=2": [
    {"name": "v1.0.0"},
    {"name": "v1.0.1"}
  ],
  "https://api.github.com/repos/example/page-error/tags?per_page=2&page=2": {
    "__error__": "recorded page-2 timeout"
  },
  "https://example.invalid/npm": {
    "versions": {
      "1.2.1": {},
      "1.2.2": {"deprecated": "do not use"}
    }
  },
  "https://example.invalid/pypi": {
    "releases": {
      "1.2.1": [{"yanked": false}],
      "1.2.2": [{"yanked": true}],
      "1.2.3": []
    }
  },
  "https://api.github.com/repos/example/lookup-error/releases?per_page=100": {
    "__error__": "recorded upstream timeout"
  },
  "https://example.invalid/repo/main/.devcontainer/Dockerfile": "ARG TOOL_VERSION=1.2.0\n",
  "https://example.invalid/repo/main/.devcontainer/duplicate": "ARG TOOL_VERSION=1.2.0\nARG TOOL_VERSION=1.2.1\n",
  "https://example.invalid/repo/main/.devcontainer/missing": "ARG OTHER_VERSION=1.2.0\n",
  "https://example.invalid/repo/main/.devcontainer/no-change": "ARG TOOL_VERSION=1.2.2\n",
  "https://example.invalid/repo/main/.devcontainer/numeric": "ARG TOOL_VERSION=1.9.9\n",
  "https://example.invalid/repo/main/.devcontainer/prerelease": "ARG TOOL_VERSION=1.2.0-rc.1\n",
  "https://example.invalid/repo/main/.devcontainer/outside": "ARG TOOL_VERSION=2.0.0\n",
  "https://example.invalid/repo/main/.devcontainer/floating": "ARG TOOL_VERSION=latest\n",
  "https://example.invalid/repo/main/.devcontainer/coupled": "ARG TOOL_VERSION=repository-lock\n",
  "https://example.invalid/repo/main/.devcontainer/raw-error": {"__error__": "recorded raw-file 404"}
}
