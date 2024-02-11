#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

pwd
ls -l
ls -l /
CONFIG_FILE=yamllint.yaml
cat <<EOF > "$CONFIG_FILE"
---
yaml-files:
  - '*.yaml'
  - '*.yml'
rules:
  braces: enable
  brackets: enable
  colons: enable
  commas: enable
  comments:
    require-starting-space: true
    ignore-shebangs: true
    min-spaces-from-content: 1
  comments-indentation: enable
  document-end: disable
  document-start: enable
  empty-lines: enable
  empty-values: disable
  float-values: disable
  hyphens: enable
  indentation: enable
  key-duplicates: enable
  key-ordering: disable
  line-length: disable
  new-line-at-end-of-file: enable
  new-lines: enable
  octal-values: disable
  quoted-strings: disable
  trailing-spaces: enable
  truthy:
    check-keys: false
EOF

yamllint -c "$CONFIG_FILE"