#!/bin/bash
set -xeuo pipefail
# The rpm-ostree (libdnf) build deps are not shipped (intentionally, because
# they're API unstable).  So we just build them from source here.
repodir=/root/rpms
mkdir $repodir
regen_rpmmd_repo() {
    (cd $repodir && createrepo_c .)
}
regen_rpmmd_repo
cat >/etc/yum.repos.d/local.repo << EOF
[local]
baseurl=$repodir
gpgcheck=0
skip_if_unavailable=False
EOF

cd /root
git clone https://git.centos.org/centos-git-common.git  
buildpkg() {
    p=$1; shift
    cd /root
    git clone -b c8 https://git.centos.org/rpms/$p.git  
    cd $p
    /root/centos-git-common/get_sources.sh
    yum -y builddep ./SPECS/*.spec
    rpmbuild --nodeps --define "%_topdir `pwd`" -bb SPECS/*.spec
    mv RPMS/*/*.rpm $repodir
    ls -al $repodir
    regen_rpmmd_repo
    # Some sort of local caching issue
    yum --disablerepo='*' --enablerepo=local clean expire-cache
}

buildpkg libsolv
yum -y install libsolv-devel
buildpkg librepo
buildpkg libmodulemd

yum -y builddep rpm-ostree
yum clean all
rm -rf /etc/yum.repos.d/local.repo /root/*
echo OK
