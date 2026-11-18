{
  "https://example.invalid/releases": [
    {"tag_name": "v1.2.1", "draft": false, "prerelease": false},
    {"tag_name": "v1.3.0-rc.1", "draft": false, "prerelease": true},
    {"tag_name": "v1.4.0", "draft": true, "prerelease": false},
    {"tag_name": "v2.0.0", "draft": false, "prerelease": false}
  ],
  "https://example.invalid/lookup-error": {
    "__error__": "recorded upstream timeout"
  },
  "https://example.invalid/repo/main/.devcontainer/Dockerfile": "ARG TOOL_VERSION=1.2.0\n",
  "https://example.invalid/repo/main/.devcontainer/duplicate": "ARG TOOL_VERSION=1.2.0\nARG TOOL_VERSION=1.2.1\n",
  "https://example.invalid/repo/main/.devcontainer/no-change": "ARG TOOL_VERSION=1.2.2\n",
  "https://example.invalid/repo/main/.devcontainer/floating": "ARG TOOL_VERSION=latest\n"
}
