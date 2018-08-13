# Contributing to ci-operator

## Contribution submissions

Contributions are accepted via standard GitHub pull request mechanism. Pull
requests will be automatically tested and all tests need to pass (follow the
instructions of the CI bot which will comment on your pull requests).
Additionally, the PR needs to be approved by one of the core project members
(see the [OWNERS](OWNERS) file).

## Build

To obtain sources and build the `ci-operator` binary, use `go get` and `go build`:

```
$ go get github.com/openshift/ci-operator
$ cd ${GOPATH}/src/github.com/openshift/ci-operator
$ go build ./cmd/ci-operator
```

## Test

At the moment, ci-operator only has unit tests. You can run them with `go test`:

```
$ go test ./...
?   	github.com/openshift/ci-operator	[no test files]
ok  	github.com/openshift/ci-operator/cmd/ci-operator	0.036s
ok  	github.com/openshift/ci-operator/pkg/api	0.029s
?   	github.com/openshift/ci-operator/pkg/interrupt	[no test files]
?   	github.com/openshift/ci-operator/pkg/junit	[no test files]
ok  	github.com/openshift/ci-operator/pkg/steps	0.044s
```
