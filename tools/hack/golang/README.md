# Standard Go tooling for Origin projects

This directory is a standard set of tooling for Origin. You can seed a new repository with

    $ tools/hack/golang/update REPO_DIR PACKAGE_NAME

which will update the hack/ dir, create a `Makefile`, and create a `PACKAGE_NAME.spec` file. You can rerun this script to update the contents of the hack dir.

Once updated, you'll need to do the following:

1. Update `PACKAGE_NAME.spec` and fill out the `TODO` sections. You'll also need to update the `%files` section.
2. Update `hack/lib/constants.sh` to contain the binaries you wish to compile.
3. Update `hack/lib/constants.sh` to change the `os::build::images` function to build your images. If you descend from `openshift/origin-base`, you should automatically get RPMs in your builds.

To test out your new scripts, run:

    $ make build-images

in the new repository. Also run

    $ make check

to verify your scripts work.

### Run a build 

Creates appropriate binaries in `_output/local/bin/<GOOS>/<GOARCH>`:

```
$ make
```

### Run tests

```
$ make check
```

### Build RPMs

```
$ make build-rpms
```

### Build images

```
$ make build-images
```