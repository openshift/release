# Keep the venv and every cache outside this directory: a local .venv here
# would hold site-packages YAML that a developer's `make update` would walk.
TMPDIR ?= /tmp
VENV ?= $(TMPDIR)/quay-ci-generator-venv
UV_VERSION := 0.9.24

export UV_PROJECT_ENVIRONMENT := $(VENV)
export UV_CACHE_DIR := $(TMPDIR)/quay-ci-generator-uv-cache
export XDG_CACHE_HOME := $(TMPDIR)/quay-ci-generator-xdg-cache

UV := $(VENV)/bin/uv

.PHONY: deps check generate

deps:
	@if [ ! -x "$(UV)" ]; then \
		python3 -m venv "$(VENV)"; \
		"$(VENV)/bin/pip" install --quiet "uv==$(UV_VERSION)"; \
	fi
	"$(UV)" sync --locked --extra test

check: deps
	"$(UV)" run --frozen pytest
	"$(UV)" run --frozen python3 generate.py --check

generate: deps
	"$(UV)" run --frozen python3 generate.py
