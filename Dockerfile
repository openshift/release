FROM registry.ci.openshift.org/ci/ocp-qe-perfscale-ci:latest
ENV HOME=/home/user
RUN mkdir -p /home/user && curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip" && unzip awscli-bundle.zip &&awscli-bundle/install -b $HOME/bin/aws
ENV PATH="$PATH:$HOME/bin"
RUN which aws

