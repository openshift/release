#!/bin/bash
set -xeuo pipefail
# First, fix coreutils
yum -y swap coreutils{-single,}
# See https://wiki.centos.org/FAQ/develrepo
sed -ie s,enabled=0,enabled=1, /etc/yum.repos.d/CentOS-Linux-PowerTools.repo
# Base buildroot, copied from /etc/mock/templates/centos-stream.tpl
yum -y install tar gcc-c++ redhat-rpm-config redhat-release which xz sed make bzip2 gzip gcc coreutils unzip shadow-utils diffutils cpio bash gawk rpm-build info patch util-linux findutils grep
# Plus createrepo_c is needed for building
yum -y install createrepo_c
# We use Go and Rust
yum -y install go-toolset rust-toolset dnf-utils
# And now our C/C++ dependencies.
yum -y builddep ostree
