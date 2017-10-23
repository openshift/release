#
# This image adds the repository link for Origin
# RPMs to allow downstream images to install the
# components using `yum'.
#
# The standard name for this image is openshift/origin-source
#
# Modified for CI: Allows the RPM repository URL to be passed as
# an argument
# 
FROM centos:7

ARG RPM_REPO_URL

COPY origin-local-release.repo /etc/yum.repos.d/
COPY centos-paas-sig-openshift-origin36.repo /etc/yum.repos.d/

RUN sed -i.bak "s%RPM_REPO_URL%$RPM_REPO_URL%" /etc/yum.repos.d/origin-local-release.repo 
