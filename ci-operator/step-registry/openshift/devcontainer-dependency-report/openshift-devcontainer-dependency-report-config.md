{
  "schema_version": 1,
  "sources": {
    "apm-cli": {
      "kind": "pypi",
      "url": "https://pypi.org/pypi/apm-cli/json"
    },
    "delve": {
      "kind": "github_releases",
      "tag_prefix": "v",
      "url": "https://api.github.com/repos/go-delve/delve/releases?per_page=100"
    },
    "gh": {
      "kind": "github_releases",
      "tag_prefix": "v",
      "url": "https://api.github.com/repos/cli/cli/releases?per_page=100"
    },
    "golangci-lint": {
      "kind": "github_releases",
      "tag_prefix": "v",
      "url": "https://api.github.com/repos/golangci/golangci-lint/releases?per_page=100"
    },
    "gopls": {
      "kind": "github_tags",
      "tag_prefix": "gopls/v",
      "url": "https://api.github.com/repos/golang/tools/tags?per_page=100"
    },
    "gotestsum": {
      "kind": "github_releases",
      "tag_prefix": "v",
      "url": "https://api.github.com/repos/gotestyourself/gotestsum/releases?per_page=100"
    },
    "playwright": {
      "kind": "npm",
      "url": "https://registry.npmjs.org/playwright"
    },
    "prometheus": {
      "kind": "github_releases",
      "tag_prefix": "v",
      "url": "https://api.github.com/repos/prometheus/prometheus/releases?per_page=100"
    },
    "staticcheck": {
      "kind": "github_tags",
      "tag_prefix": "v",
      "url": "https://api.github.com/repos/dominikh/go-tools/tags?per_page=100"
    },
    "uv": {
      "kind": "pypi",
      "url": "https://pypi.org/pypi/uv/json"
    }
  },
  "repositories": [
    {
      "name": "openshift/sippy",
      "ref": "main",
      "dependencies": [
        {
          "name": "fedora-base",
          "classification": "manual",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^FROM registry\\.fedoraproject\\.org/fedora:(?P<version>[0-9]+)$"},
          "version_source": "https://registry.fedoraproject.org/repo/fedora/tags/list",
          "rationale": "Base-image changes also change the distribution toolchain and require target-repository compatibility validation; no automatic proposal is made."
        },
        {
          "name": "fedora-package-set",
          "classification": "repo-coupled",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "^    git \\\\$", "current": "unversioned Fedora package set"},
          "authority": "Fedora 44 repositories and the target repository maintainers",
          "rationale": "Package versions are coupled to the selected Fedora base and must not be independently latest-bumped."
        },
        {
          "name": "golangci-lint",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG GOLANGCI_LINT_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "golangci-lint",
          "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
          "rationale": "Report a stable 2.x candidate only; maintainers must validate the lint configuration and repository code."
        },
        {
          "name": "github-cli",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG GH_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "gh",
          "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
          "rationale": "Report a stable 2.x candidate only; this is not a compatibility claim."
        },
        {
          "name": "google-cloud-cli-rapid",
          "classification": "floating",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "google-cloud-cli-linux-\\$\\{GCLOUD_ARCH\\}\\.tar\\.gz", "current": "rapid channel (floating)"},
          "version_source": "https://dl.google.com/dl/cloudsdk/channels/rapid/",
          "rationale": "The rapid-channel URL has no pinned version, so the report records it without inventing a current or proposed release."
        },
        {
          "name": "uv-installer",
          "classification": "floating",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "https://astral\\.sh/uv/install\\.sh", "current": "installer default (floating)"},
          "version_source": "https://github.com/astral-sh/uv/releases",
          "rationale": "The installer URL is unpinned; changing to a pin is a target-repository policy decision."
        },
        {
          "name": "gotestsum",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "gotest\\.tools/gotestsum@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "gotestsum",
          "policy": {"min_inclusive": "1.0.0", "max_exclusive": "2.0.0"},
          "rationale": "Report a stable 1.x candidate only; maintainers must validate repository tests."
        },
        {
          "name": "gopls",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "golang\\.org/x/tools/gopls@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "gopls",
          "policy": {"min_inclusive": "0.21.0", "max_exclusive": "0.22.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.21 line."
        },
        {
          "name": "delve",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "github\\.com/go-delve/delve/cmd/dlv@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "delve",
          "policy": {"min_inclusive": "1.27.0", "max_exclusive": "2.0.0"},
          "rationale": "Report a stable 1.x candidate only; maintainers must validate debugger support."
        },
        {
          "name": "staticcheck",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "honnef\\.co/go/tools/cmd/staticcheck@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "staticcheck",
          "policy": {"min_inclusive": "0.7.0", "max_exclusive": "0.8.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.7 line."
        },
        {
          "name": "go-module-graph",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "^go mod download$", "current": "go.mod/go.sum"},
          "authority": "openshift/sippy go.mod and go.sum",
          "rationale": "The module graph is repository-owned and is not independently version-selected by this report."
        },
        {
          "name": "frontend-dependencies",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "^make npm$", "current": "repository lockfiles"},
          "authority": "openshift/sippy package manifests and lockfiles",
          "rationale": "Frontend versions are controlled by repository manifests and lockfiles."
        },
        {
          "name": "claude-code-installer",
          "classification": "unsupported",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "https://claude\\.ai/install\\.sh", "current": "opaque installer"},
          "version_source": "https://claude.ai/install.sh",
          "rationale": "The declaration exposes no deterministic version, so no version lookup or proposal is supported."
        },
        {
          "name": "opencode-cli",
          "classification": "floating",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "@opencode/cli@\\$\\{OPENCODE_VERSION:-(?P<version>latest)\\}"},
          "version_source": "https://registry.npmjs.org/@opencode%2fcli",
          "rationale": "The default is latest and can be overridden by users; the checker does not reinterpret that policy."
        },
        {
          "name": "mcp-python-lock",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "mcp/requirements\\.lock", "current": "mcp/requirements.lock"},
          "authority": "openshift/sippy mcp/requirements.lock",
          "rationale": "Python dependencies are hash-locked by the target repository."
        },
        {
          "name": "postgres-service-image",
          "classification": "repo-coupled",
          "file": ".devcontainer/init-services.sh",
          "extract": {"kind": "regex", "pattern": "^POSTGRES_IMAGE=(?P<version>[^ ]+)$"},
          "authority": "OpenShift CI image promotion configuration",
          "rationale": "The CI image tag is repository/promotion coupled and requires its owning authority; no independent bump is proposed."
        },
        {
          "name": "redis-service-image",
          "classification": "repo-coupled",
          "file": ".devcontainer/init-services.sh",
          "extract": {"kind": "regex", "pattern": "^REDIS_IMAGE=(?P<version>[^ ]+)$"},
          "authority": "OpenShift CI image promotion configuration",
          "rationale": "The CI image tag is repository/promotion coupled and requires its owning authority; no independent bump is proposed."
        }
      ]
    },
    {
      "name": "openshift/origin",
      "ref": "main",
      "dependencies": [
        {
          "name": "fedora-base",
          "classification": "manual",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^FROM registry\\.fedoraproject\\.org/fedora:(?P<version>[0-9]+)$"},
          "version_source": "https://registry.fedoraproject.org/repo/fedora/tags/list",
          "rationale": "Base-image changes also change the distribution toolchain and require target-repository compatibility validation; no automatic proposal is made."
        },
        {
          "name": "fedora-package-set",
          "classification": "repo-coupled",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "^    git \\\\$", "current": "unversioned Fedora package set"},
          "authority": "Fedora 44 repositories and the target repository maintainers",
          "rationale": "Package versions are coupled to the selected Fedora base and must not be independently latest-bumped."
        },
        {
          "name": "golangci-lint",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG GOLANGCI_LINT_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "golangci-lint",
          "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
          "rationale": "Report a stable 2.x candidate only; maintainers must validate the lint configuration and repository code."
        },
        {
          "name": "github-cli",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG GH_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "gh",
          "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
          "rationale": "Report a stable 2.x candidate only; this is not a compatibility claim."
        },
        {
          "name": "uv-installer",
          "classification": "floating",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "https://astral\\.sh/uv/install\\.sh", "current": "installer default (floating)"},
          "version_source": "https://github.com/astral-sh/uv/releases",
          "rationale": "The installer URL is unpinned; changing to a pin is a target-repository policy decision."
        },
        {
          "name": "gotestsum",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "gotest\\.tools/gotestsum@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "gotestsum",
          "policy": {"min_inclusive": "1.0.0", "max_exclusive": "2.0.0"},
          "rationale": "Report a stable 1.x candidate only; maintainers must validate repository tests."
        },
        {
          "name": "gopls",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "golang\\.org/x/tools/gopls@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "gopls",
          "policy": {"min_inclusive": "0.21.0", "max_exclusive": "0.22.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.21 line."
        },
        {
          "name": "delve",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "github\\.com/go-delve/delve/cmd/dlv@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "delve",
          "policy": {"min_inclusive": "1.27.0", "max_exclusive": "2.0.0"},
          "rationale": "Report a stable 1.x candidate only; maintainers must validate debugger support."
        },
        {
          "name": "staticcheck",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "honnef\\.co/go/tools/cmd/staticcheck@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "staticcheck",
          "policy": {"min_inclusive": "0.7.0", "max_exclusive": "0.8.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.7 line."
        },
        {
          "name": "go-module-graph",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "^go mod download$", "current": "go.mod/go.sum"},
          "authority": "openshift/origin go.mod and go.sum",
          "rationale": "The module graph is repository-owned and is not independently version-selected by this report."
        },
        {
          "name": "claude-code-installer",
          "classification": "unsupported",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "https://claude\\.ai/install\\.sh", "current": "opaque installer"},
          "version_source": "https://claude.ai/install.sh",
          "rationale": "The declaration exposes no deterministic version, so no version lookup or proposal is supported."
        },
        {
          "name": "opencode-cli",
          "classification": "floating",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "@opencode/cli@\\$\\{OPENCODE_VERSION:-(?P<version>latest)\\}"},
          "version_source": "https://registry.npmjs.org/@opencode%2fcli",
          "rationale": "The default is latest and can be overridden by users; the checker does not reinterpret that policy."
        },
        {
          "name": "openshift-tests-build",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "^make build$", "current": "repository build target"},
          "authority": "openshift/origin build configuration",
          "rationale": "The built binary and its dependencies are controlled by the target repository."
        }
      ]
    },
    {
      "name": "openshift-eng/ship-status-dash",
      "ref": "main",
      "dependencies": [
        {
          "name": "fedora-base",
          "classification": "manual",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^FROM registry\\.fedoraproject\\.org/fedora:(?P<version>[0-9]+)$"},
          "version_source": "https://registry.fedoraproject.org/repo/fedora/tags/list",
          "rationale": "Base-image changes also change the distribution toolchain and require target-repository compatibility validation; no automatic proposal is made."
        },
        {
          "name": "fedora-package-set",
          "classification": "repo-coupled",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "^    curl \\\\$", "current": "unversioned Fedora package set"},
          "authority": "Fedora 44 repositories and the target repository maintainers",
          "rationale": "Package versions are coupled to the selected Fedora base and must not be independently latest-bumped."
        },
        {
          "name": "playwright-system-packages",
          "classification": "repo-coupled",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "presence", "pattern": "^RUN dnf install -y \\\\\\n    alsa-lib", "current": "unversioned Fedora package set"},
          "authority": "Fedora 44 repositories and Playwright's runtime requirements",
          "rationale": "Browser system libraries must remain coupled to both Fedora and the selected Playwright release."
        },
        {
          "name": "golangci-lint",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG GOLANGCI_LINT_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "golangci-lint",
          "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
          "rationale": "Report a stable 2.x candidate only; maintainers must validate the lint configuration and repository code."
        },
        {
          "name": "github-cli",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG GH_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "gh",
          "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
          "rationale": "Report a stable 2.x candidate only; this is not a compatibility claim."
        },
        {
          "name": "uv",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG UV_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "uv",
          "policy": {"min_inclusive": "0.7.0", "max_exclusive": "0.8.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.7 line."
        },
        {
          "name": "playwright",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "npx playwright@(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+) install"},
          "source": "playwright",
          "policy": {"min_inclusive": "1.62.0", "max_exclusive": "1.63.0"},
          "rationale": "Report a stable candidate only within the approved 1.62 line; browser compatibility must be validated."
        },
        {
          "name": "gotestsum",
          "classification": "floating",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "gotest\\.tools/gotestsum@(?P<version>latest)"},
          "version_source": "https://github.com/gotestyourself/gotestsum/releases",
          "rationale": "The declaration explicitly tracks latest; the checker records the floating policy without claiming a deterministic current version."
        },
        {
          "name": "prometheus",
          "classification": "pinned",
          "file": ".devcontainer/Dockerfile",
          "extract": {"kind": "regex", "pattern": "^ARG PROMETHEUS_VERSION=(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"},
          "source": "prometheus",
          "policy": {"min_inclusive": "3.4.0", "max_exclusive": "4.0.0"},
          "rationale": "Report a stable 3.x candidate only; maintainers must validate Prometheus data and flags."
        },
        {
          "name": "gopls",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "golang\\.org/x/tools/gopls@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "gopls",
          "policy": {"min_inclusive": "0.21.0", "max_exclusive": "0.22.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.21 line."
        },
        {
          "name": "delve",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "github\\.com/go-delve/delve/cmd/dlv@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "delve",
          "policy": {"min_inclusive": "1.27.0", "max_exclusive": "2.0.0"},
          "rationale": "Report a stable 1.x candidate only; maintainers must validate debugger support."
        },
        {
          "name": "staticcheck",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "honnef\\.co/go/tools/cmd/staticcheck@v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "staticcheck",
          "policy": {"min_inclusive": "0.7.0", "max_exclusive": "0.8.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.7 line."
        },
        {
          "name": "go-module-graph",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "^go mod download$", "current": "go.mod/go.sum"},
          "authority": "openshift-eng/ship-status-dash go.mod and go.sum",
          "rationale": "The module graph is repository-owned and is not independently version-selected by this report."
        },
        {
          "name": "frontend-dependencies",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "^make npm$", "current": "repository lockfiles"},
          "authority": "openshift-eng/ship-status-dash package manifests and lockfiles",
          "rationale": "Frontend versions are controlled by repository manifests and lockfiles."
        },
        {
          "name": "claude-code-installer",
          "classification": "unsupported",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "https://claude\\.ai/install\\.sh", "current": "opaque installer"},
          "version_source": "https://claude.ai/install.sh",
          "rationale": "The declaration exposes no deterministic version, so no version lookup or proposal is supported."
        },
        {
          "name": "opencode-cli",
          "classification": "floating",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "@opencode/cli@\\$\\{OPENCODE_VERSION:-(?P<version>latest)\\}"},
          "version_source": "https://registry.npmjs.org/@opencode%2fcli",
          "rationale": "The default is latest and can be overridden by users; the checker does not reinterpret that policy."
        },
        {
          "name": "mcp-python-requirements",
          "classification": "repo-coupled",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "presence", "pattern": "requirements-dev\\.txt", "current": "mcp requirements-dev.txt files"},
          "authority": "openshift-eng/ship-status-dash MCP requirement files",
          "rationale": "Python dependencies are selected by the target repository."
        },
        {
          "name": "apm-cli",
          "classification": "pinned",
          "file": ".devcontainer/post-create.sh",
          "extract": {"kind": "regex", "pattern": "apm-cli==(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)"},
          "source": "apm-cli",
          "policy": {"min_inclusive": "0.11.0", "max_exclusive": "0.12.0"},
          "rationale": "Report a stable candidate only within the explicitly approved 0.11 line."
        }
      ]
    }
  ]
}
