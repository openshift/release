NÂO USAR

install:

```sh
# yq
wget -O ~/bin/yq3 https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64 && \
chmod u+x ~/bin/yq3

wget -O ~/bin/yq4 https://github.com/mikefarah/yq/releases/download/v4.34.1/yq_linux_amd64 && \
chmod u+x ~/bin/yq4

# butane
wget -O ~/bin/butane "https://github.com/coreos/butane/releases/download/v0.18.0/butane-x86_64-unknown-linux-gnu" &&\
chmod u+x ~/bin/butane

```

Run Local:

```sh
INSTALLER=${HOME}/go/src/github.com/mtulio/installer-upi
sudo ln -svf ${INSTALLER} /var/lib/openshift-install

# workdir
export STEP_WORKDIR=/tmp/ci-op-$(cat /dev/random | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 6)
mkdir -v $STEP_WORKDIR

#export STEP_WORKDIR=/tmp/ci-op-9cd2a9

export STEP_WORKDIR=$STEP_WORKDIR
export SHARED_DIR=$STEP_WORKDIR/shared
export ARTIFACT_DIR=$STEP_WORKDIR/artifact

export JOB_NAME=opct-platform-external-install-aws
export BUILD_ID=000

mkdir -vp $STEP_WORKDIR $SHARED_DIR $ARTIFACT_DIR

export CLUSTER_PROFILE_DIR=$STEP_WORKDIR
ln -svf $HOME/.aws/credentials ${STEP_WORKDIR}/.awscred

export PROVIDER_NAME=aws
export AWS_REGION=us-east-1
export LEASED_RESOURCE=${AWS_REGION}

export BOOTSTRAP_INSTANCE_TYPE=m6i.xlarge
export MASTER_INSTANCE_TYPE=m6i.xlarge
export WORKER_INSTANCE_TYPE=m6i.xlarge
export OCP_ARCH=amd64

REPO=${HOME}/go/src/github.com/mtulio/release
bash -x $REPO/ci-operator/step-registry/platform-external/cluster/aws/install/platform-external-cluster-aws-install-commands.sh
```