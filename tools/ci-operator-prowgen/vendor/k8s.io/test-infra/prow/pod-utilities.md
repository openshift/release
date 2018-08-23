# Pod Utilities

Pod utilities are small, focused Go programs used by `plank` to decorate user-provided `PodSpec`s
in order to increase the ease of integration for new jobs into the entire CI infrastructure. The
utilities today wrap the execution of the test code to ensure that the tests run against correct
versions of the source code, that test commands run in the appropriate environment and that output
from the test (in the form of status, logs and artifacts) is correctly uploaded to the cloud.

These utilities are integrated into a test run by adding `InitContainer`s and sidecar `Container`s
to the user-provided `PodSpec`, as well as by overwriting the `Container` entrypoint for the test
`Container` provided by the user. The following utilities exist today:

 - [`clonerefs`](./cmd/clonerefs/README.md): clones source code under test
 - [`initupload`](./cmd/initupload/README.md): records the beginning of a test in cloud storage
   and reports the status of the clone operations
 - [`entrypoint`](./cmd/entrypoint/README.md): is injected into the test `Container`, wraps the
   test code to capture logs and exit status
 - [`sidecar`](./cmd/sidecar/README.md): runs alongside the test `Container`, uploads status, logs
   and test artifacts to cloud storage once the test is finished

## Writing a ProwJob that uses Pod Utilities

### What the test container can expect

Example test container script:
```bash
pwd # my repo root
ls path/to/file/in/my/repo.txt # access repo file
ls ../other-repo # access repo file in another repo
echo results.txt > $ARTIFACTS # result info that will be uploaded to GCS.
# logs, and job metadata are automatically uploaded.
```

More specifically, a ProwJob using the Pod Utilities can expect the following:
- **Source Code** - Jobs can expect to begin execution with their working
directory set as the root of the checked out repo. The commit that is checked
out depends on the type of job:
	- `presubmit` jobs will have the relevant PR checked out and merged with the base branch.
	- `postsubmit` jobs will have the upstream commit that triggered the job checked out.
	- `periodic` jobs will have the working directory set to the root of the repo specified by the first ref in `extra_refs` (if specified).
See the `extra_refs` field if you need to clone more than one repo.
- **Metadata and Logs** - Jobs can expect metadata about the job to be uploaded
before the job starts, and additional metadata and logs to be uploaded when the
job completes.
- **Artifact Directory** - Jobs can expect an `$ARTIFACTS` environment variable
to be specified. It indicates an existent directory where job artifacts can be
dumped for automatic upload to GCS upon job completion.

### How to configure

ProwJobs may request Pod Utility decoration by setting `decorate: true` in their config.
Example ProwJob configuration:
```yaml

  - name: pull-job
    agent: kubernetes
    context: pull-job
    always_run: true
    rerun_command: "/test pull-job"
    trigger: "(?m)^/test (all|pull-job)\\s*"
    decorate: true
    spec:
      containers:
      - image: alpine
        command:
        - "echo"
        args:
        - "The artifacts dir is $(ARTIFACTS)"
```

In addition to normal ProwJob configuration, ProwJobs using the Pod Utilities
must specify the `command` field in the container specification instead of using
the Dockerfile's ENTRYPOINT directive. Note that the `command` field is a string
array not just a string. It should point to the test binary location in the container.

Additional fields may be required for some use cases:
- Private repos need to do two things:
	- Add an ssh secret that gives the bot access to the repo to the build cluster
	and specify the secret name in the `ssh_key_secrets` field of the job spec.
	- Set the `clone_uri` field of the job spec to `git@github.com:{{.Org}}/{{.Repo}}.git`.
- Repos requiring a non-standard clone path can use the `path_alias` field
to clone the repo to a path different than the default of `/go/src/github.com/org/repo/` (e.g. `/go/src/k8s.io/kubernetes/kubernetes`).
- Jobs that require additional repos to be checked out can arrange for that with
the `exta_refs` field.

```yaml
- name: post-job
  agent: kubernetes
  decorate: true
  ssh_key_secrets:
  - ssh-secret
  clone_uri: "git@github.com:{{.Org}}/{{.Repo}}.git"
  extra_refs:
  - org: kubernetes
    repo: other-repo
    base_ref: master
  spec:
    containers:
    - image: alpine
      command:
      - "echo"
      args:
      - "The artifacts dir is $(ARTIFACTS)"

```

### Why use Pod Utilities?

Writing a ProwJob that uses the Pod Utilities is much easier than writing one
that doesn't because the Pod Utilities will transparently handle many of the
tasks the job would otherwise need to do in order to prepare its environment
and output more than pass/fail. Historically, this was achieved by wrapping
every job with a [bootstrap.py](jenkins/bootstrap.py) script that handled cloning
source code, preparing the test environment, and uploading job metadata, logs,
and artifacts. This was cumbersome to configure and required every job to be
wrapped with the script in the job image. The pod utilities achieve the same goals
with less configuration and much simpler job images that are easier to develop
and less coupled to Prow.
