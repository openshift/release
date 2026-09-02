# Restricted agent model policy

The `agent-model-policy` presubmit scans `ci-operator/step-registry` and
`ci-operator/jobs` for references to `claude-opus-5` (including versioned
variants) and the restricted `claude-fable-*` and `claude-mythos-*` model
families. Every file containing one of those references must be listed by its
exact repository-relative path in `authorized-paths.txt`.

This directory does not inherit parent OWNERS. Adding or changing an
authorization therefore requires approval from `jupierce` or `stbenjam`.

Run the same check locally from the repository root:

```console
$ ci-operator/model-policy/validate.sh
```
