<!--TODO(bentheelder): fill this in much more thoroughly-->
# `kind` - **K**ubernetes **IN** **D**ocker

## WARNING: `kind` is still a work in progress!

`kind` is a toolset for running local Kubernetes clusters using Docker container "nodes".

It consists of:
 - Go [packages](./pkg) implementing [cluster creation](./pkg/cluster), [image build](./pkg/build), etc.
 - A command line interface ([`kind`](./cmd/kind)) built on these packages.
 - Docker [image(s)](./images) written to run systemd, Kubernetes, etc.
 - [`kubetest`](https://github.com/kubernetes/test-infra/tree/master/kubetest) integration also built on these packages (WIP)

Kind bootstraps each "node" with [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm/).

For more details see [the design documentation](./docs/design.md).

## Building

You can build `kind` with `go install ./cmd/kind` or `bazel build //kind/cmd/kind`.

## Usage

`kind create` will create a cluster.

`kind delete` will delete a cluster.

For more usage, run `kind --help` or `kind [command] --help`.

## Advanced

`kind build image` will build the node image.
